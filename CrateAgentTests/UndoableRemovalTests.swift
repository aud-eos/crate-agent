@testable import CrateAgent
import Foundation
import GRDB
import XCTest

@MainActor
final class UndoableRemovalTests: XCTestCase {
    func testCleanupRecordsEveryRemovedRecordAndTheTrashDestination() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let engine = try temporaryTrashEngine(fixture)
        let cleaned = try await cleanDuplicate(fixture, engine: engine)
        let trashPath = Self.trashDirectory(fixture).appendingPathComponent("target.wav").path
        let originalBytes = cleaned.originalBytes.reduce(into: [String: Data]()) { bytes, entry in bytes[Self.resolved(entry.key)] = entry.value }

        let recorded = try await fixture.database.writer.read { database in
            func eventID(_ type: EventType) throws -> Int64 {
                try XCTUnwrap(EventRecord.filter(Column("event_type") == type.rawValue).fetchOne(database)?.eventId, type.rawValue)
            }
            let captures = try [EventType.trackRemovedFromSerato, .fileRemovedFromCrates].flatMap { type in
                try SeratoRemovalCaptureStore.captures(eventID: eventID(type), in: database)
            }
            let destination = try SeratoRemovalCaptureStore.trashDestination(eventID: eventID(.fileTrashed), in: database)
            let row = try FileRecord.fetchOne(database, key: cleaned.target.id)
            return (captures: captures, destination: destination, row: row)
        }

        XCTAssertEqual(Set(recorded.captures.map { capture in Self.resolved(capture.storePath) }), Set(originalBytes.keys))
        XCTAssertEqual(recorded.captures.count, 3)
        for capture in recorded.captures {
            _ = try restoreRemovedRecords(filePath: capture.storePath, trackPath: capture.trackPath, records: capture.records)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: capture.storePath)), originalBytes[Self.resolved(capture.storePath)], capture.storePath)
        }
        XCTAssertNil(recorded.row, "The destination outlives the deleted file row")
        let destination = try XCTUnwrap(recorded.destination)
        XCTAssertEqual(destination.originalPath, cleaned.target.path)
        XCTAssertEqual(destination.identity.path, trashPath)
        XCTAssertEqual(destination.identity.inode, cleaned.target.inode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.identity.path))
    }

    func testUndoRestoresTheFileAndExactSeratoBytes() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let engine = try temporaryTrashEngine(fixture)
        let cleaned = try await cleanDuplicate(fixture, engine: engine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleaned.target.path))

        try await engine.undoBatch(cleaned.batchID)

        try await assertFileRestored(cleaned, in: fixture)
        for (path, bytes) in cleaned.originalBytes {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, path)
        }
    }

    func testUndoQueuesSeratoRestoresWhileSeratoRuns() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let engine = try temporaryTrashEngine(fixture)
        let cleaned = try await cleanDuplicate(fixture, engine: engine)
        let removedBytes = try cleaned.originalBytes.keys.reduce(into: [String: Data]()) { bytes, path in
            bytes[path] = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()

        try await engine.undoBatch(cleaned.batchID)

        try await assertFileRestored(cleaned, in: fixture)
        for (path, bytes) in removedBytes {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, "\(path) changed while Serato ran")
        }
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await engine.drainPendingSeratoUpdates()
        for (path, bytes) in cleaned.originalBytes {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, path)
        }
    }

    func testUndoReportsADeletedCrateAndRestoresTheOtherStores() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let engine = try temporaryTrashEngine(fixture)
        let cleaned = try await cleanDuplicate(fixture, engine: engine)
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        try await engine.undoBatch(cleaned.batchID)
        let deletedCrate = fixture.locator.subcratesDirectoryUrl.appendingPathComponent("owned.crate").path
        try FileManager.default.removeItem(atPath: deletedCrate)

        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await engine.drainPendingSeratoUpdates()

        for (path, bytes) in cleaned.originalBytes where path != deletedCrate {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, path)
        }
        let dispositions = try await fixture.database.writer.read { database in
            try Row.fetchAll(database, sql: "SELECT disposition, detail FROM serato_write_dispositions").map { row in
                [row["disposition"] as String, row["detail"] as String]
            }
        }
        XCTAssertEqual(dispositions, [[SeratoWriteDisposition.storeMissing.rawValue, RemovalUndoMessages.storesMissing([deletedCrate], unrecorded: [])]])
    }

    func testAStuckRestoreThatNeverReachedItsWriteCanBeDiscarded() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let engine = try temporaryTrashEngine(fixture)
        let cleaned = try await cleanDuplicate(fixture, engine: engine)
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        let undoBatchID = try await engine.undoBatch(cleaned.batchID)
        let smartCrate = fixture.locator.smartCratesDirectoryUrl.appendingPathComponent("owned.scrate")
        try Data("not a crate".utf8).write(to: smartCrate)
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        do {
            try await engine.drainPendingSeratoUpdates()
            XCTFail("The unreadable SmartCrate must stop the restore before its write")
        } catch {}
        let restoredID = try await fixture.database.writer.read { database in
            try XCTUnwrap(FileRecord.filter(Column("path") == cleaned.target.path).fetchOne(database)?.id)
        }

        try await engine.discardQueuedChange(batchID: undoBatchID, fileID: restoredID)

        let queued = try await fixture.database.writer.read { database in try SeratoWriteQueue.fetch(fileID: restoredID, in: database) }
        XCTAssertTrue(queued.isEmpty)
        try await engine.drainPendingSeratoUpdates()
        try await assertFileRestored(cleaned, in: fixture)
    }

    func testUndoAfterARetriedSweepIgnoresCratesThatNeverHeldTheTrack() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let engine = try temporaryTrashEngine(fixture)
        let cleaned = try await cleanDuplicate(fixture, engine: engine, otherCrates: ["broken.crate": Data("not a crate".utf8), "other.crate": Self.crateBytes(paths: [])],
                                               completes: false)
        try Self.crateBytes(paths: []).write(to: fixture.locator.subcratesDirectoryUrl.appendingPathComponent("broken.crate"))
        try await engine.drainPendingSeratoUpdates(retryingFailedCleanup: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleaned.target.path), "The retried cleanup finishes")

        try await engine.undoBatch(cleaned.batchID)

        try await assertFileRestored(cleaned, in: fixture)
        for (path, bytes) in cleaned.originalBytes {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, path)
        }
    }

    func testUndoRefusesAV2RemovalWhoseCaptureWasLostAfterItsWriteLanded() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let engine = try temporaryTrashEngine(fixture)
        let unverifiable = SeratoTestEncoding.record("otrk", SeratoTestEncoding.record("tsng", "No path".data(using: .utf16BigEndian)!))
        let cleaned = try await cleanDuplicate(fixture, engine: engine, extraDatabaseRecords: unverifiable, completes: false)
        let databaseV2 = fixture.locator.databaseV2Url
        let landed = try Data(contentsOf: databaseV2)
        try landed.prefix(landed.count - unverifiable.count).write(to: databaseV2)
        try await engine.drainPendingSeratoUpdates(retryingFailedCleanup: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleaned.target.path), "The retried cleanup finishes")

        do {
            try await engine.undoBatch(cleaned.batchID)
            XCTFail("Undo must not report success without the V2 records")
        } catch let OperationEngineError.restoreBlocked(_, reason) {
            guard case let .recordsNotRecorded(store) = reason else { return XCTFail("Unexpected reason \(reason)") }
            XCTAssertEqual(Self.resolved(store), Self.resolved(databaseV2.path))
        }
    }

    func testUndoRefusesWhenTheTrashItemIsGoneAndChangesNothing() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let engine = try temporaryTrashEngine(fixture)
        let cleaned = try await cleanDuplicate(fixture, engine: engine)
        try FileManager.default.removeItem(at: Self.trashDirectory(fixture).appendingPathComponent("target.wav"))
        let before = try await libraryState(cleaned, in: fixture)

        await assertUndoBlocked(cleaned, engine: engine, reason: .trashItemMissing)

        let after = try await libraryState(cleaned, in: fixture)
        XCTAssertEqual(after, before)
        XCTAssertFalse(after.hasRowAtOriginalPath)
    }

    func testUndoRefusesWhenTheOriginalPathIsOccupied() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let engine = try temporaryTrashEngine(fixture)
        let cleaned = try await cleanDuplicate(fixture, engine: engine)
        let occupant = Data("a different file".utf8)
        try occupant.write(to: URL(fileURLWithPath: cleaned.target.path))
        let before = try await libraryState(cleaned, in: fixture)

        await assertUndoBlocked(cleaned, engine: engine, reason: .originalPathOccupied)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cleaned.target.path)), occupant)
        let after = try await libraryState(cleaned, in: fixture)
        XCTAssertEqual(after, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.trashDirectory(fixture).appendingPathComponent("target.wav").path))
    }

    func testUndoOfAQueuedCleanupDropsItsPendingRows() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let engine = try temporaryTrashEngine(fixture)
        let cleaned = try await cleanDuplicate(fixture, engine: engine, whileSeratoRuns: true)

        try await engine.undoBatch(cleaned.batchID)

        let queued = try await fixture.database.writer.read { database in try SeratoWriteQueue.fetch(fileID: XCTUnwrap(cleaned.target.id), in: database) }
        XCTAssertTrue(queued.isEmpty)
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await engine.drainPendingSeratoUpdates()
        try await assertFileRestored(cleaned, in: fixture)
        for (path, bytes) in cleaned.originalBytes {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, path)
        }
    }

    func testRemovingAFileWithoutAKeeperIsUndoable() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let engine = try temporaryTrashEngine(fixture)
        let target = try await fixture.add("target.wav", bytes: FinalRemovalIntegrationTests.wav())
        let removed = try RemovedFile(target: target, batchID: UUID().uuidString, originalBytes: saveStores(fixture, paths: [target.path]))
        let seratoPath = SeratoLibraryLocator.seratoRelativePath(fromAbsolute: target.path).data(using: .utf16BigEndian)!

        let result = try await engine.removeFile(target: target, batchID: removed.batchID)

        XCTAssertEqual(result, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.trashDirectory(fixture).appendingPathComponent("target.wav").path))
        for path in removed.originalBytes.keys {
            XCTAssertNil(try Data(contentsOf: URL(fileURLWithPath: path)).range(of: seratoPath), "\(path) still holds the file")
        }
        let history = try await EventHistoryQuery.loadRecentBatches(database: fixture.database)
        XCTAssertEqual(history.first { batch in batch.batchId == removed.batchID }?.canUndo, true)
        try await engine.undoBatch(removed.batchID)
        try await assertFileRestored(removed, in: fixture)
        for (path, bytes) in removed.originalBytes {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, path)
        }
    }

    func testRemovingTheKeeperOfAPendingCleanupIsRefused() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let engine = try temporaryTrashEngine(fixture)
        let cleaned = try await cleanDuplicate(fixture, engine: engine, whileSeratoRuns: true)
        let keeperPath = fixture.directory.appendingPathComponent("keeper.wav").path
        let keeper = try await fixture.database.writer.read { database in
            try XCTUnwrap(FileRecord.filter(Column("path") == keeperPath).fetchOne(database))
        }

        do {
            _ = try await engine.removeFile(target: keeper, batchID: UUID().uuidString)
            XCTFail("Removing the copy a pending cleanup keeps must be refused")
        } catch OperationEngineError.removalTargetIsKept(keeperPath) {}

        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await engine.drainPendingSeratoUpdates()
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeperPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleaned.target.path))
    }

    private struct LibraryState: Equatable {
        let storeBytes: [String: Data]
        let eventCount: Int
        let hasRowAtOriginalPath: Bool
    }

    private func libraryState(_ cleaned: RemovedFile, in fixture: SeratoRemovalFixture) async throws -> LibraryState {
        let storeBytes = try cleaned.originalBytes.keys.reduce(into: [String: Data]()) { bytes, path in
            bytes[path] = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        return try await fixture.database.writer.read { database in
            try LibraryState(storeBytes: storeBytes, eventCount: EventRecord.fetchCount(database),
                             hasRowAtOriginalPath: FileRecord.filter(Column("path") == cleaned.target.path).fetchCount(database) > 0)
        }
    }

    private func assertUndoBlocked(_ cleaned: RemovedFile, engine: OperationEngine, reason expected: RestoreBlockReason) async {
        do {
            try await engine.undoBatch(cleaned.batchID)
            XCTFail("Undo must refuse with \(expected)")
        } catch let OperationEngineError.restoreBlocked(path, reason) {
            XCTAssertEqual(path, cleaned.target.path)
            XCTAssertEqual(reason, expected)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    private struct RemovedFile {
        let target: FileRecord
        let batchID: String
        /// Database V2, `owned.crate` and `owned.scrate` before the cleanup.
        let originalBytes: [String: Data]
    }

    /// Cleans `target.wav`, a duplicate of `keeper.wav` held in database V2 and both crate kinds.
    /// `otherCrates`, by name, are saved as well, `extraDatabaseRecords` are appended to V2, and `completes: false` lets a cleanup step fail.
    /// `whileSeratoRuns` starts Serato before the cleanup, so its steps stay queued.
    private func cleanDuplicate(_ fixture: SeratoRemovalFixture, engine: OperationEngine, otherCrates: [String: Data] = [:],
                                extraDatabaseRecords: Data = Data(), completes: Bool = true, whileSeratoRuns: Bool = false) async throws -> RemovedFile
    {
        let keeper = try await fixture.add("keeper.wav", bytes: FinalRemovalIntegrationTests.wav())
        let target = try await fixture.add("target.wav", bytes: FinalRemovalIntegrationTests.wav())
        let originalBytes = try saveStores(fixture, paths: [keeper.path, target.path], extraDatabaseRecords: extraDatabaseRecords)
        for (name, bytes) in otherCrates {
            try bytes.write(to: fixture.locator.subcratesDirectoryUrl.appendingPathComponent(name))
        }
        let group = try await DuplicateFinder.DuplicateGroup.confirmedByteLevel("undoable", files: [keeper, target], in: fixture.database)
        if whileSeratoRuns {
            fixture.lifecycle.running = true
            fixture.watchdog.refresh()
        }
        let outcome = try await DuplicateResolver(operationEngine: engine, database: fixture.database).resolve(group: group, keeperId: XCTUnwrap(keeper.id))
        XCTAssertEqual(outcome.trashedCount, completes && !whileSeratoRuns ? 1 : 0)
        return RemovedFile(target: target, batchID: outcome.batchId, originalBytes: originalBytes)
    }

    private static func trashDirectory(_ fixture: SeratoRemovalFixture) -> URL {
        fixture.directory.appendingPathComponent("Trash")
    }

    /// Trashes into the fixture's own Trash directory, never the user's.
    private func temporaryTrashEngine(_ fixture: SeratoRemovalFixture) throws -> OperationEngine {
        let trash = Self.trashDirectory(fixture)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                               fileTrasher: { path in
                                   let destination = trash.appendingPathComponent((path as NSString).lastPathComponent).path
                                   try FileManager.default.moveItem(atPath: path, toPath: destination)
                                   return destination
                               },
                               availabilityResolver: FileAvailabilityResolver(trashDirectory: { _ in trash }))
    }

    private func assertFileRestored(_ cleaned: RemovedFile, in fixture: SeratoRemovalFixture) async throws {
        XCTAssertEqual(FileMetadataCollector.collect(at: cleaned.target.path, includeLightweightHash: true), cleaned.target.identity)
        let row = try await fixture.database.writer.read { database in
            try FileRecord.filter(Column("path") == cleaned.target.path).fetchOne(database)
        }
        let restored = try XCTUnwrap(row)
        XCTAssertEqual(restored.identity, cleaned.target.identity)
        XCTAssertEqual(restored.libraryMembership, .active)
        XCTAssertEqual(restored.fileAvailability, .available)
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func crateBytes(paths: [String]) -> Data {
        paths.reduce(SeratoTestEncoding.record("vrsn", "1.0/Serato ScratchLive Crate".data(using: .utf16BigEndian)!)) { bytes, path in
            bytes + SeratoTestEncoding.record("otrk", SeratoTestEncoding.record("ptrk", SeratoLibraryLocator.seratoRelativePath(fromAbsolute: path).data(using: .utf16BigEndian)!))
        }
    }

    /// Saves `paths` into database V2, `owned.crate` and `owned.scrate`, and returns each store's bytes.
    private func saveStores(_ fixture: SeratoRemovalFixture, paths: [String], extraDatabaseRecords: Data = Data()) throws -> [String: Data] {
        try fixture.save(paths: paths.map(SeratoLibraryLocator.seratoRelativePath))
        if !extraDatabaseRecords.isEmpty {
            try (Data(contentsOf: fixture.locator.databaseV2Url) + extraDatabaseRecords).write(to: fixture.locator.databaseV2Url)
        }
        let crateBytes = Self.crateBytes(paths: paths)
        let crates = [fixture.locator.subcratesDirectoryUrl.appendingPathComponent("owned.crate"),
                      fixture.locator.smartCratesDirectoryUrl.appendingPathComponent("owned.scrate")]
        for crate in crates {
            try crateBytes.write(to: crate)
        }
        return try ([fixture.locator.databaseV2Url] + crates).reduce(into: [String: Data]()) { bytes, url in
            bytes[url.path] = try Data(contentsOf: url)
        }
    }
}
