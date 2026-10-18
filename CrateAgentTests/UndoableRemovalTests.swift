@testable import CrateAgent
import Foundation
import GRDB
import XCTest

@MainActor
final class UndoableRemovalTests: XCTestCase {
    func testCleanupRecordsEveryRemovedRecordAndTheTrashDestination() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let trashPath = fixture.directory.appendingPathComponent("trashed-target.wav").path
        let engine = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator, fileTrasher: { path in
            try FileManager.default.moveItem(atPath: path, toPath: trashPath)
            return trashPath
        })
        let cleaned = try await cleanDuplicate(fixture, engine: engine)
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
        let cleaned = try await cleanDuplicate(fixture, engine: fixture.engine)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleaned.target.path))

        try await fixture.engine.undoBatch(cleaned.batchID)

        try await assertFileRestored(cleaned, in: fixture)
        for (path, bytes) in cleaned.originalBytes {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, path)
        }
    }

    func testUndoQueuesSeratoRestoresWhileSeratoRuns() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let cleaned = try await cleanDuplicate(fixture, engine: fixture.engine)
        let removedBytes = try cleaned.originalBytes.keys.reduce(into: [String: Data]()) { bytes, path in
            bytes[path] = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()

        try await fixture.engine.undoBatch(cleaned.batchID)

        try await assertFileRestored(cleaned, in: fixture)
        for (path, bytes) in removedBytes {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, "\(path) changed while Serato ran")
        }
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await fixture.engine.drainPendingSeratoUpdates()
        for (path, bytes) in cleaned.originalBytes {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes, path)
        }
    }

    private struct CleanedDuplicate {
        let target: FileRecord
        let batchID: String
        /// Database V2, `owned.crate` and `owned.scrate` before the cleanup.
        let originalBytes: [String: Data]
    }

    /// Cleans `target.wav`, a duplicate of `keeper.wav` held in database V2 and both crate kinds.
    private func cleanDuplicate(_ fixture: SeratoRemovalFixture, engine: OperationEngine) async throws -> CleanedDuplicate {
        let keeper = try await fixture.add("keeper.wav", bytes: FinalRemovalIntegrationTests.wav())
        let target = try await fixture.add("target.wav", bytes: FinalRemovalIntegrationTests.wav())
        try fixture.save(paths: [keeper.path, target.path].map(SeratoLibraryLocator.seratoRelativePath))
        let crates = try saveCrates(fixture, paths: [keeper.path, target.path])
        let originalBytes = try ([fixture.locator.databaseV2Url.path] + crates.map(\.path)).reduce(into: [String: Data]()) { bytes, path in
            bytes[path] = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        let group = try await DuplicateFinder.DuplicateGroup.confirmedByteLevel("undoable", files: [keeper, target], in: fixture.database)
        let outcome = try await DuplicateResolver(operationEngine: engine, database: fixture.database).resolve(group: group, keeperId: XCTUnwrap(keeper.id))
        XCTAssertEqual(outcome.trashedCount, 1)
        return CleanedDuplicate(target: target, batchID: outcome.batchId, originalBytes: originalBytes)
    }

    private func assertFileRestored(_ cleaned: CleanedDuplicate, in fixture: SeratoRemovalFixture) async throws {
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

    private func saveCrates(_ fixture: SeratoRemovalFixture, paths: [String]) throws -> [URL] {
        let bytes = paths.reduce(SeratoTestEncoding.record("vrsn", "1.0/Serato ScratchLive Crate".data(using: .utf16BigEndian)!)) { bytes, path in
            bytes + SeratoTestEncoding.record("otrk", SeratoTestEncoding.record("ptrk", SeratoLibraryLocator.seratoRelativePath(fromAbsolute: path).data(using: .utf16BigEndian)!))
        }
        return try [fixture.locator.subcratesDirectoryUrl.appendingPathComponent("owned.crate"),
                    fixture.locator.smartCratesDirectoryUrl.appendingPathComponent("owned.scrate")].map { url in
            try bytes.write(to: url)
            return url
        }
    }
}
