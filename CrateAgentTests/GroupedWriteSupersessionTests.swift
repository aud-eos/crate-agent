@testable import CrateAgent
import Foundation
import GRDB
import XCTest

@MainActor
final class GroupedWriteSupersessionTests: XCTestCase {
    func testImmediateMetadataBatchAppliesValidCoalescedSiblings() async throws {
        try await verifyMetadataGroup(history: false, restart: false)
    }

    func testHistoryMetadataGroupAppliesValidCoalescedSiblings() async throws {
        try await verifyMetadataGroup(history: true, restart: false)
    }

    func testInterruptedGroupRetainsValidSiblingsForGuardedDrain() async throws {
        try await verifyMetadataGroup(history: false, restart: true)
    }

    private func verifyMetadataGroup(history: Bool, restart: Bool) async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let replaced = try await fixture.add("replaced.wav")
        let first = try await fixture.add("first.wav")
        let second = try await fixture.add("second.wav")
        let files = [replaced, first, second]
        let paths = files.map(\.path)
        try fixture.save(paths: paths.map(SeratoLibraryLocator.seratoRelativePath))
        let log = ActivityLog()
        let batches = MetadataBatches()
        let engine = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog,
                                     seratoLocator: fixture.locator, seratoMetadataBatchWriter: { path, updates in
                                         batches.record(updates.map(\.trackPath))
                                         return try batchUpdateDatabaseRecords(databasePath: path, updates: updates)
                                     }, activityLog: log)
        let mutations = try files.enumerated().map { index, file in
            try TrackMutation.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Desired \(index)")))
        }
        if history {
            try await engine.applyBatch(mutations, batchId: "grouped-metadata")
            XCTAssertEqual(batches.values, [paths.map(SeratoLibraryLocator.seratoRelativePath)])
            batches.clear()
            log.clear()
            try fixture.save(paths: paths.map(SeratoLibraryLocator.seratoRelativePath))
        }
        let boundary = BoundaryIntervention()
        let replacement = Data(repeating: 99, count: 512)
        try await installReplacement(fixture, path: replaced.path, replacement: replacement, boundary: boundary,
                                     restartAtFileID: restart ? first.id : nil)
        let outcome: ResyncOutcome?
        if history {
            outcome = try await engine.resyncSeratoForBatch("grouped-metadata")
        } else {
            let events = try await engine.applyBatch(mutations, batchId: "grouped-metadata")
            XCTAssertEqual(events.count, 3)
            outcome = nil
        }
        try await fixture.database.writer.write { $0.trace(nil) }
        XCTAssertTrue(boundary.didReplace, "Replacement must occur after the physical preflight at the real writer boundary")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: replaced.path)), replacement)
        if restart {
            XCTAssertTrue(boundary.didRestart)
            let queued = try await engine.pendingSeratoWriteCount
            XCTAssertEqual(queued, 2)
            XCTAssertTrue(batches.values.isEmpty)
            XCTAssertTrue(log.recent.contains { $0.message.contains("wrote 0, queued 2, superseded 1") })
            fixture.lifecycle.running = false
            fixture.watchdog.refresh()
            let drained = try await engine.drainPendingSeratoUpdates()
            XCTAssertEqual(drained, ResyncOutcome(appliedCount: 2, queuedCount: 0))
        } else {
            XCTAssertEqual(batches.values, [[first.path, second.path].map(SeratoLibraryLocator.seratoRelativePath)], "Valid siblings must retain one coalesced V2 write")
            XCTAssertTrue(log.recent.contains { $0.message.contains("wrote 2, queued 0, superseded 1") })
            if let outcome {
                XCTAssertEqual(outcome, ResyncOutcome(appliedCount: 2, queuedCount: 0, supersededCount: 1))
            }
        }
        let records = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path)
        XCTAssertEqual(records.map(\.title), [nil, "Desired 1", "Desired 2"])
        let queued = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(queued, 0)
        let journal = try await fixture.database.writer.read { database in
            try EventRecord.filter(Column("batch_id") == "grouped-metadata").fetchAll(database)
        }
        XCTAssertEqual(journal.count, 3, "External subset retry must not re-journal local mutations")
        XCTAssertTrue(journal.allSatisfy { !$0.inversePayloadJson.isEmpty })
    }

    func testGroupedRenamesKeepValidTransitionsAcrossAnInterveningAdd() async throws {
        for afterV2 in [false, true] {
            try await verifyRenameGroup(replaceAfterV2: afterV2)
        }
    }

    private func verifyRenameGroup(replaceAfterV2: Bool) async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let replaced = try await fixture.add("replaced.wav")
        let first = try await fixture.add("first.wav")
        let second = try await fixture.add("second.wav")
        let added = try await fixture.add("added.wav", membership: .pendingImport)
        let originals = [replaced.path, first.path, second.path]
        try fixture.save(paths: originals.map(SeratoLibraryLocator.seratoRelativePath))
        let crateBytes = OperationEngineTests.synthesizeCrateBytesForTest(withTrackPaths: originals.map(SeratoLibraryLocator.seratoRelativePath))
        let crates = [fixture.locator.subcratesDirectoryUrl.appendingPathComponent("owned.crate"), fixture.locator.smartCratesDirectoryUrl.appendingPathComponent("owned.scrate")]
        for crate in crates {
            try crateBytes.write(to: crate)
        }
        let replacedDestination = fixture.directory.appendingPathComponent("replaced-new.wav").path
        let firstIntermediate = fixture.directory.appendingPathComponent("first-middle.wav").path
        let secondIntermediate = fixture.directory.appendingPathComponent("second-middle.wav").path
        let firstFinal = fixture.directory.appendingPathComponent("first-final.wav").path
        let secondFinal = fixture.directory.appendingPathComponent("second-final.wav").path
        let log = ActivityLog()
        let engine = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator, activityLog: log)
        let boundary = BoundaryIntervention()
        let replacement = Data(repeating: 87, count: 512)
        try await installReplacement(fixture, path: replacedDestination, replacement: replacement, boundary: boundary,
                                     afterV2Path: replaceAfterV2 ? replacedDestination : nil)
        let events = try await engine.applyBatch([
            .renameFile(.init(fileId: XCTUnwrap(replaced.id), newPath: replacedDestination, previousPath: replaced.path, physicalMove: true)),
            .renameFile(.init(fileId: XCTUnwrap(first.id), newPath: firstIntermediate, previousPath: first.path, physicalMove: true)),
            .renameFile(.init(fileId: XCTUnwrap(second.id), newPath: secondIntermediate, previousPath: second.path, physicalMove: true)),
            .addTrackToSerato(.init(fileId: XCTUnwrap(added.id), metadata: .init(title: "Added between rename groups"))),
            .renameFile(.init(fileId: XCTUnwrap(first.id), newPath: firstFinal, previousPath: firstIntermediate, physicalMove: true)),
            .renameFile(.init(fileId: XCTUnwrap(second.id), newPath: secondFinal, previousPath: secondIntermediate, physicalMove: true)),
        ], batchId: "grouped-renames")
        try await fixture.database.writer.write { $0.trace(nil) }
        XCTAssertTrue(boundary.didReplace)
        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: replacedDestination)), replacement)
        XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).map { SeratoPath.normalized($0.path) }, [replaceAfterV2 ? replacedDestination : replaced.path, firstFinal, secondFinal, added.path])
        for crate in crates {
            XCTAssertEqual(try readCratePaths(cratePath: crate.path).map(SeratoPath.normalized), [replaced.path, firstFinal, secondFinal])
        }
        XCTAssertTrue(log.recent.contains { $0.message.contains("wrote 5, queued 0, superseded 1") })
        let queueDepth = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(queueDepth, 0)
        let eventCount = try await fixture.database.writer.read { database in
            try EventRecord.filter(Column("batch_id") == "grouped-renames").fetchCount(database)
        }
        XCTAssertEqual(eventCount, 6)
    }

    private func installReplacement(_ fixture: SeratoRemovalFixture, path: String, replacement: Data,
                                    boundary: BoundaryIntervention, restartAtFileID: Int64? = nil, afterV2Path: String? = nil) async throws
    {
        let databaseV2Path = fixture.locator.databaseV2Url.path
        try await fixture.database.writer.write { database in
            database.trace { event in
                let sql = event.expandedDescription
                guard sql.contains("file_identity_observed"), sql.contains("\"event_id\" >") else { return }
                if let afterV2Path {
                    do {
                        guard try readDatabaseRecordsStrict(databasePath: databaseV2Path).contains(where: { SeratoPath.normalized($0.path) == afterV2Path }) else { return }
                    } catch { return XCTFail("Owned V2 boundary observation failed: \(error)") }
                }
                if boundary.replaceOnce() {
                    do {
                        try FileManager.default.moveItem(atPath: path, toPath: path + ".original")
                        try replacement.write(to: URL(fileURLWithPath: path))
                    } catch { XCTFail("Owned boundary replacement failed: \(error)") }
                } else if let restartAtFileID, sql.contains("\"file_id\" = \(restartAtFileID)"), boundary.restartOnce() {
                    DispatchQueue.main.sync {
                        fixture.lifecycle.running = true
                        fixture.watchdog.refresh()
                    }
                }
            }
        }
    }

    private final class BoundaryIntervention: @unchecked Sendable {
        private let lock = NSLock()
        private var replaced = false
        private var restarted = false
        var didReplace: Bool {
            lock.withLock { replaced }
        }

        var didRestart: Bool {
            lock.withLock { restarted }
        }

        func replaceOnce() -> Bool {
            lock.withLock {
                if replaced {
                    return false
                }; replaced = true; return true
            }
        }

        func restartOnce() -> Bool {
            lock.withLock {
                if restarted {
                    return false
                }; restarted = true; return true
            }
        }
    }

    private final class MetadataBatches: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        var values: [[String]] {
            lock.withLock { recorded }
        }

        func record(_ paths: [String]) {
            lock.withLock { recorded.append(paths) }
        }

        func clear() {
            lock.withLock { recorded.removeAll() }
        }
    }
}
