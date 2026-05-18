import GRDB
import XCTest
@testable import CrateAgent

@MainActor
final class SeratoWatchdogTests: XCTestCase {

    func testReportsNotRunningWhenNoSeratoAppPresent() {
        let watchdog = SeratoWatchdog(
            runningBundleIdentifiersProvider: {
                ["com.apple.Finder", "com.apple.dock", "com.spotify.client"]
            }
        )
        XCTAssertFalse(watchdog.isSeratoRunning)
    }

    func testReportsRunningWhenSeratoDjProIsPresent() {
        let watchdog = SeratoWatchdog(
            runningBundleIdentifiersProvider: {
                ["com.apple.Finder", "com.serato.djpro"]
            }
        )
        XCTAssertTrue(watchdog.isSeratoRunning)
    }

    func testRecognizesAnyComSeratoPrefixedApp() {
        // Forward-compatible: future Serato apps under the same
        // bundle prefix must trigger the guard without code changes.
        let watchdog = SeratoWatchdog(
            runningBundleIdentifiersProvider: {
                ["com.serato.future-unreleased-app"]
            }
        )
        XCTAssertTrue(watchdog.isSeratoRunning)
    }

    func testRefreshPicksUpStateChange() {
        var simulatedRunningApps: [String] = []
        let watchdog = SeratoWatchdog(
            runningBundleIdentifiersProvider: { simulatedRunningApps }
        )
        XCTAssertFalse(watchdog.isSeratoRunning)

        simulatedRunningApps = ["com.serato.djpro"]
        watchdog.refresh()
        XCTAssertTrue(watchdog.isSeratoRunning)

        simulatedRunningApps = []
        watchdog.refresh()
        XCTAssertFalse(watchdog.isSeratoRunning)
    }
}

final class OperationEngineTests: XCTestCase {

    @MainActor
    private func makeEngine() throws -> (OperationEngine, LibraryDatabase) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        let engine = OperationEngine(database: database, seratoWatchdog: watchdog)
        return (engine, database)
    }

    func testIndexNewFileInsertsFileRowAndLogsEvent() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        let mutation = TrackMutation.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/Test.mp3",
            volumeUuid: "v1",
            inode: 42,
            fileSize: 1024,
            mtime: 1_700_000_000
        ))

        let eventId = try await engine.apply(mutation)
        XCTAssertGreaterThan(eventId, 0)

        try await database.writer.read { db in
            let files = try FileRecord.fetchAll(db)
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(files.first?.path, "/Music/A/Test.mp3")
            XCTAssertEqual(files.first?.fingerprintStatus, .pending)

            let events = try EventRecord.fetchAll(db)
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?.eventType, .trackImported)
            XCTAssertEqual(events.first?.fileId, files.first?.id)
            XCTAssertFalse(events.first?.inversePayloadJson.isEmpty ?? true,
                           "inverse payload must be populated for undo")
        }
    }

    func testRenameFileUpdatesPathAndRecordsInversePayload() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }

        let indexEventId = try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/old.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        XCTAssertGreaterThan(indexEventId, 0)

        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/old.mp3"])
        }!

        let renameEventId = try await engine.apply(.renameFile(RenameFilePayload(
            fileId: fileId,
            newPath: "/Music/A/new.mp3"
        )))
        XCTAssertGreaterThan(renameEventId, indexEventId)

        try await database.writer.read { db in
            // Path was updated.
            let file = try FileRecord.fetchOne(db, key: fileId)!
            XCTAssertEqual(file.path, "/Music/A/new.mp3")

            // Rename event was logged with the original path captured.
            let renameEvent = try EventRecord
                .filter(Column("event_type") == EventType.fileRenamed.rawValue)
                .fetchOne(db)!
            XCTAssertEqual(renameEvent.fileId, fileId)

            // Decode forward + inverse payloads and verify the path swap.
            let decoder = JSONDecoder()
            let forward = try decoder.decode(
                RenameFilePayload.self,
                from: renameEvent.payloadJson.data(using: .utf8)!
            )
            let inverse = try decoder.decode(
                RenameFilePayload.self,
                from: renameEvent.inversePayloadJson.data(using: .utf8)!
            )
            XCTAssertEqual(forward.previousPath, "/Music/A/old.mp3")
            XCTAssertEqual(forward.newPath, "/Music/A/new.mp3")
            XCTAssertEqual(inverse.previousPath, "/Music/A/new.mp3")
            XCTAssertEqual(inverse.newPath, "/Music/A/old.mp3")
        }
    }

    func testRenameFileThrowsForUnknownFileId() async throws {
        let (engine, _) = try await MainActor.run { try makeEngine() }
        do {
            _ = try await engine.apply(.renameFile(RenameFilePayload(
                fileId: 9_999, newPath: "/Music/A/nothing.mp3"
            )))
            XCTFail("expected fileNotFound to throw")
        } catch let error as OperationEngineError {
            XCTAssertEqual(error, .fileNotFound(fileId: 9_999))
        }
    }

    func testBatchIdGroupsRelatedMutations() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        let batchId = "import-batch-1"
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/a.mp3", volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )), batchId: batchId)
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/b.mp3", volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1
        )), batchId: batchId)

        try await database.writer.read { db in
            let count = try EventRecord
                .filter(Column("batch_id") == batchId)
                .fetchCount(db)
            XCTAssertEqual(count, 2, "both mutations should share the batch id")
        }
    }
}

final class RustFFIBridgeTests: XCTestCase {

    func testCoreVersionReturnsCargoVersionString() throws {
        let version = coreVersion()
        // The Rust crate's CARGO_PKG_VERSION is "0.1.0" at SP-1; the
        // assertion is intentionally loose to avoid coupling tests to
        // the exact version string. What we're proving here is that
        // the Swift → Rust call returns a real String, which means
        // the FFI bridge, static library link, and Swift bindings are
        // wired correctly end-to-end at runtime.
        XCTAssertFalse(version.isEmpty)
        XCTAssertTrue(
            version.split(separator: ".").count >= 2,
            "expected semver-style version, got '\(version)'"
        )
    }
}

final class DatabaseSchemaTests: XCTestCase {

    func testInMemoryDatabaseMigratesCleanly() async throws {
        let database = try LibraryDatabase.openInMemory()
        let tables = try await database.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
        }
        XCTAssertTrue(tables.contains("works"))
        XCTAssertTrue(tables.contains("tracks"))
        XCTAssertTrue(tables.contains("files"))
        XCTAssertTrue(tables.contains("events"))
    }

    func testFileRecordRoundTrip() async throws {
        let database = try LibraryDatabase.openInMemory()
        var file = FileRecord(
            path: "/Music/A/Test - Track.mp3",
            volumeUuid: "00000000-1111-2222-3333-444444444444",
            inode: 123_456,
            fileSize: 5_242_880,
            mtime: 1_700_000_000,
            lightweightHash: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            chromaprintFingerprint: nil,
            fingerprintStatus: .pending
        )
        try await database.writer.write { db in
            try file.insert(db)
        }
        XCTAssertNotNil(file.id, "insertion should set the row id")

        let fetched = try await database.writer.read { db in
            try FileRecord.fetchOne(db, key: file.id!)
        }
        XCTAssertEqual(fetched?.path, file.path)
        XCTAssertEqual(fetched?.volumeUuid, file.volumeUuid)
        XCTAssertEqual(fetched?.inode, file.inode)
        XCTAssertEqual(fetched?.fileSize, file.fileSize)
        XCTAssertEqual(fetched?.lightweightHash, file.lightweightHash)
        XCTAssertEqual(fetched?.fingerprintStatus, .pending)
        XCTAssertNil(fetched?.trackId)
    }

    func testFingerprintStatusFiltering() async throws {
        let database = try LibraryDatabase.openInMemory()
        let pendingFile = FileRecord(
            path: "/Music/A/pending.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            fingerprintStatus: .pending
        )
        let doneFile = FileRecord(
            path: "/Music/A/done.mp3",
            volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1,
            fingerprintStatus: .done
        )

        try await database.writer.write { db in
            var pending = pendingFile
            var done = doneFile
            try pending.insert(db)
            try done.insert(db)
        }

        let pendingCount = try await database.writer.read { db in
            try FileRecord
                .filter(Column("fingerprint_status") == FingerprintStatus.pending.rawValue)
                .fetchCount(db)
        }
        XCTAssertEqual(pendingCount, 1)
    }

    func testEventLogRoundTrip() async throws {
        let database = try LibraryDatabase.openInMemory()

        var event = EventRecord(
            batchId: "test-batch-1",
            timestamp: 1_700_000_000_000,
            fileId: nil,
            trackId: nil,
            eventType: .fileRenamed,
            payloadJson: #"{"old":"a.mp3","new":"b.mp3"}"#,
            inversePayloadJson: #"{"old":"b.mp3","new":"a.mp3"}"#
        )
        try await database.writer.write { db in
            try event.insert(db)
        }
        XCTAssertNotNil(event.eventId)

        let events = try await database.writer.read { db in
            try EventRecord
                .filter(Column("batch_id") == "test-batch-1")
                .fetchAll(db)
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventType, .fileRenamed)
    }
}
