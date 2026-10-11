@testable import CrateAgent
import GRDB
import XCTest

@MainActor
final class FailedImportRecoveryTests: XCTestCase {
    func testRetrySyncRecoversFailedImportsWithoutRepeatingIntentAndRejectsStaleTargets() async throws {
        let readiness = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: readiness)
        defer { fixture.cleanup() }
        let session = SeratoLibrarySyncSession(
            reader: fixture.reader, reconciler: fixture.reconciler,
            scanner: LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator),
            operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: readiness
        )
        let importer = ImportCoordinator(operationEngine: fixture.engine, database: fixture.database)

        for scenario in ["unchanged", "changed", "retired", "removed"] {
            try fixture.save(paths: [])
            try await session.synchronize()
            let audio = fixture.directory.appendingPathComponent("\(scenario).wav")
            try FinalRemovalIntegrationTests.wav().write(to: audio)
            try Data("invalid V2".utf8).write(to: fixture.locator.databaseV2Url)
            let result = await importer.importDroppedItems([audio])
            XCTAssertEqual(result.filesImported, 0)
            XCTAssertEqual(result.filesPendingSync, 1)
            XCTAssertEqual(result.filesSkipped, 0)
            let queued = await fixture.engine.pendingSeratoWriteCount
            XCTAssertEqual(queued, 1, scenario)
            let pending = try await fixture.database.writer.read { database in
                try XCTUnwrap(FileRecord.filter(Column("path") == audio.path).fetchOne(database))
            }
            XCTAssertEqual(pending.libraryMembership, .pendingImport)
            let fileID = try XCTUnwrap(pending.id)
            let originalEvents = try await fixture.database.writer.read { database in
                try EventRecord.filter(Column("file_id") == fileID).order(Column("event_id")).fetchAll(database)
            }
            XCTAssertEqual(originalEvents.filter { $0.eventType == .fileImportRequested }.count, 1)
            XCTAssertEqual(originalEvents.filter { $0.eventType == .trackAddedToSerato }.count, 1)

            if scenario == "unchanged" {
                do {
                    try await fixture.engine.drainPendingSeratoUpdates()
                    XCTFail("The retained add must still fail against corrupt V2")
                } catch {}
                let retained = await fixture.engine.pendingSeratoWriteCount
                XCTAssertEqual(retained, 1, "A second external-write failure must not lose or duplicate the add")
            }

            switch scenario {
            case "changed":
                let handle = try FileHandle(forWritingTo: audio)
                try handle.seek(toOffset: 44)
                try handle.write(contentsOf: Data([4, 3, 2, 1]))
                try handle.close()
            case "retired":
                try await fixture.engine.apply(.setFileLibraryState(.init(
                    fileId: fileID, expectedRevision: pending.membershipRevision,
                    state: .init(membership: .retired, availability: .available, libraryID: pending.seratoLibraryId, retiredAt: 1)
                )))
            case "removed":
                try FileManager.default.removeItem(at: audio)
            default: break
            }

            try session.reportFailure(XCTUnwrap(result.syncFailures.first))
            await session.waitUntilIdle()
            do {
                try await session.synchronize(retryingFailedCleanup: true)
                XCTFail("Corrupt V2 must keep Retry Sync failed")
            } catch {}
            guard case .failed = session.state else { return XCTFail("Retry failure must stay visible") }
            let stillQueued = await fixture.engine.pendingSeratoWriteCount
            XCTAssertEqual(stillQueued, 1)
            try fixture.save(paths: [])

            if scenario == "unchanged" {
                fixture.lifecycle.running = true
                fixture.watchdog.refresh()
                do { try await session.synchronize(retryingFailedCleanup: true); XCTFail("Serato must block retry") } catch {}
                XCTAssertEqual(session.state, .waitingForSerato)
                XCTAssertTrue(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).isEmpty)
                fixture.lifecycle.running = false
                fixture.watchdog.refresh()
            }
            try await session.synchronize(retryingFailedCleanup: true)
            guard case .ready = session.state else { return XCTFail("Retry must finish") }
            let after = try await fixture.row(pending)
            let paths = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).map { SeratoPath.normalized($0.path) }
            if scenario == "unchanged" {
                XCTAssertEqual(after.libraryMembership, .active)
                XCTAssertEqual(paths, [audio.path])
            } else {
                XCTAssertNotEqual(after.libraryMembership, .active)
                XCTAssertTrue(paths.isEmpty, scenario)
            }
            let drained = await fixture.engine.pendingSeratoWriteCount
            XCTAssertEqual(drained, 0)
            let eventsAfterRetry = try await fixture.database.writer.read { database in
                try EventRecord.filter(Column("file_id") == fileID).order(Column("event_id")).fetchAll(database)
            }
            let originalIDs = Set(originalEvents.compactMap(\.eventId))
            XCTAssertEqual(eventsAfterRetry.filter { originalIDs.contains($0.eventId!) }, originalEvents)
            XCTAssertEqual(eventsAfterRetry.filter { $0.eventType == .fileImportRequested }.count, 1)
            XCTAssertEqual(eventsAfterRetry.filter { $0.eventType == .trackAddedToSerato }.count, 1)
            let bytesAfterRetry = try Data(contentsOf: fixture.locator.databaseV2Url)
            try await session.synchronize(retryingFailedCleanup: true)
            XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), bytesAfterRetry)
            let repeatedEvents = try await fixture.database.writer.read { database in
                try EventRecord.filter(Column("file_id") == fileID).order(Column("event_id")).fetchAll(database)
            }
            XCTAssertEqual(repeatedEvents, eventsAfterRetry)
        }
    }
}
