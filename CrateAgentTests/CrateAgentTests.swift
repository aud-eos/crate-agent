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

    func testInMemoryDatabaseMigratesCleanly() throws {
        let database = try Database.openInMemory()
        let tables = try database.writer.read { db in
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

    func testFileRecordRoundTrip() throws {
        let database = try Database.openInMemory()
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
        try database.writer.write { db in
            try file.insert(db)
        }
        XCTAssertNotNil(file.id, "insertion should set the row id")

        let fetched = try database.writer.read { db in
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

    func testFingerprintStatusFiltering() throws {
        let database = try Database.openInMemory()
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

        try database.writer.write { db in
            var pending = pendingFile
            var done = doneFile
            try pending.insert(db)
            try done.insert(db)
        }

        let pendingCount = try database.writer.read { db in
            try FileRecord
                .filter(Column("fingerprint_status") == FingerprintStatus.pending.rawValue)
                .fetchCount(db)
        }
        XCTAssertEqual(pendingCount, 1)
    }

    func testEventLogRoundTrip() throws {
        let database = try Database.openInMemory()

        var event = EventRecord(
            batchId: "test-batch-1",
            timestamp: 1_700_000_000_000,
            fileId: nil,
            trackId: nil,
            eventType: .fileRenamed,
            payloadJson: #"{"old":"a.mp3","new":"b.mp3"}"#,
            inversePayloadJson: #"{"old":"b.mp3","new":"a.mp3"}"#
        )
        try database.writer.write { db in
            try event.insert(db)
        }
        XCTAssertNotNil(event.eventId)

        let events = try database.writer.read { db in
            try EventRecord
                .filter(Column("batch_id") == "test-batch-1")
                .fetchAll(db)
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventType, .fileRenamed)
    }
}
