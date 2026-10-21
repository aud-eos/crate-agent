@testable import CrateAgent
import GRDB
import XCTest

@MainActor
final class LibraryBatchRemovalTests: XCTestCase {
    func testASelectionIsRemovedAsOneUndoableBatchAndAChangedFileRefusesThePlan() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let trash = fixture.directory.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let engine = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                                     fileTrasher: { path in
                                         let destination = trash.appendingPathComponent((path as NSString).lastPathComponent).path
                                         try FileManager.default.moveItem(atPath: path, toPath: destination)
                                         return destination
                                     },
                                     availabilityResolver: FileAvailabilityResolver(trashDirectory: { _ in trash }))
        let first = try await fixture.add("first.wav", bytes: FinalRemovalIntegrationTests.wav(sample: 1))
        let second = try await fixture.add("second.wav", bytes: FinalRemovalIntegrationTests.wav(sample: 2, durationSeconds: 2))
        try fixture.save(paths: [first.path, second.path].map(SeratoLibraryLocator.seratoRelativePath))
        let removal = LibraryBatchRemoval(database: fixture.database, engine: engine)
        let identities = [first, second].map { file in PagedIdentity(id: file.id!, revision: file.membershipRevision) }

        do {
            _ = try await removal.plan([PagedIdentity(id: first.id!, revision: first.membershipRevision + 1)])
            XCTFail("A file that changed since it was selected must refuse the plan")
        } catch let LibrarySelectionError.changedSinceSelected(files) {
            XCTAssertEqual(files, [first.displayName])
        }

        let missing = try await fixture.add("missing.wav", bytes: FinalRemovalIntegrationTests.wav(sample: 3))
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET file_availability = 'missing' WHERE id = ?", arguments: [missing.id!])
        }
        do {
            _ = try await removal.plan([PagedIdentity(id: missing.id!, revision: missing.membershipRevision)])
            XCTFail("A file that is not on disk must refuse the plan")
        } catch let LibraryBatchRemovalError.notRemovable(files) {
            XCTAssertEqual(files, [missing.displayName])
        }

        let plan = try await removal.plan(identities)
        XCTAssertEqual(plan.files.map(\.path), [first.path, second.path])
        XCTAssertEqual(plan.totalBytes, first.fileSize + second.fileSize)

        let outcome = await removal.remove(plan)
        XCTAssertEqual(outcome.completed, 2, "\(outcome.failures)")
        XCTAssertTrue(outcome.failures.isEmpty)
        let rows = try await fixture.database.writer.read { connection in
            try FileRecord.filter(keys: [first.id!, second.id!]).fetchAll(connection)
        }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("second.wav").path))

        _ = try await engine.undoBatch(outcome.batchID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        let restored = try await fixture.database.writer.read { connection in
            try FileRecord.filter(Column("path") == first.path || Column("path") == second.path).fetchCount(connection)
        }
        XCTAssertEqual(restored, 2)
    }
}
