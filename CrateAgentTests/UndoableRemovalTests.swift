@testable import CrateAgent
import Foundation
import GRDB
import XCTest

@MainActor
final class UndoableRemovalTests: XCTestCase {
    func testCleanupRecordsEveryRemovedRecordAndTheTrashDestination() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let keeper = try await fixture.add("keeper.wav", bytes: FinalRemovalIntegrationTests.wav())
        let target = try await fixture.add("target.wav", bytes: FinalRemovalIntegrationTests.wav())
        let targetID = try XCTUnwrap(target.id)
        try fixture.save(paths: [keeper.path, target.path].map(SeratoLibraryLocator.seratoRelativePath))
        let crates = try saveCrates(fixture, paths: [keeper.path, target.path])
        let databasePath = fixture.locator.databaseV2Url.path
        let originalBytes = try ([databasePath] + crates.map(\.path)).reduce(into: [String: Data]()) { bytes, path in
            bytes[Self.resolved(path)] = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        let trashPath = fixture.directory.appendingPathComponent("trashed-target.wav").path
        let engine = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator, fileTrasher: { path in
            try FileManager.default.moveItem(atPath: path, toPath: trashPath)
            return trashPath
        })
        let group = try await DuplicateFinder.DuplicateGroup.confirmedByteLevel("undoable", files: [keeper, target], in: fixture.database)
        let outcome = try await DuplicateResolver(operationEngine: engine, database: fixture.database).resolve(group: group, keeperId: XCTUnwrap(keeper.id))
        XCTAssertEqual(outcome.trashedCount, 1)

        let recorded = try await fixture.database.writer.read { database in
            func eventID(_ type: EventType) throws -> Int64 {
                try XCTUnwrap(EventRecord.filter(Column("event_type") == type.rawValue).fetchOne(database)?.eventId, type.rawValue)
            }
            let captures = try [EventType.trackRemovedFromSerato, .fileRemovedFromCrates].flatMap { type in
                try SeratoRemovalCaptureStore.captures(eventID: eventID(type), in: database)
            }
            let destination = try SeratoRemovalCaptureStore.trashDestination(eventID: eventID(.fileTrashed), in: database)
            let row = try FileRecord.fetchOne(database, key: targetID)
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
        XCTAssertEqual(destination.originalPath, target.path)
        XCTAssertEqual(destination.identity.path, trashPath)
        XCTAssertEqual(destination.identity.inode, target.inode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.identity.path))
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
