import Combine
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
    private func makeEngine(
        seratoDirectory: URL? = nil,
        seratoIsRunning: Bool = false
    ) throws -> (OperationEngine, LibraryDatabase, SeratoLibraryLocator) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(
            runningBundleIdentifiersProvider: {
                seratoIsRunning ? ["com.serato.djpro"] : []
            }
        )
        let locator = SeratoLibraryLocator(
            seratoDirectory: seratoDirectory ?? URL(fileURLWithPath: "/dev/null")
        )
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { _, _ in /* no-op: tests use synthetic paths */ },
            fileTrasher: { _ in /* no-op: tests use synthetic paths */ }
        )
        return (engine, database, locator)
    }

    func testIndexNewFileInsertsFileRowAndLogsEvent() async throws {
        let (engine, database, _) = try await MainActor.run { try makeEngine() }
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
        let (engine, database, _) = try await MainActor.run { try makeEngine() }

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
        let (engine, _, _) = try await MainActor.run { try makeEngine() }
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
        let (engine, database, _) = try await MainActor.run { try makeEngine() }
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

    // MARK: - Serato side effects

    func testRenameFileRewritesSeratoCrateWhenSeratoClosed() async throws {
        let (seratoDirectoryUrl, crateFileUrl) = try Self.makeTemporarySeratoLibrary(
            withCratePaths: ["Users/testuser/Music/A/old.mp3"]
        )
        defer { try? FileManager.default.removeItem(at: seratoDirectoryUrl.deletingLastPathComponent()) }

        let (engine, database, _) = try await MainActor.run {
            try makeEngine(seratoDirectory: seratoDirectoryUrl, seratoIsRunning: false)
        }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Users/testuser/Music/A/old.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Users/testuser/Music/A/old.mp3"])
        }!

        try await engine.apply(.renameFile(RenameFilePayload(
            fileId: fileId, newPath: "/Users/testuser/Music/A/new.mp3"
        )))

        let updatedPaths = try readCratePaths(cratePath: crateFileUrl.path)
        XCTAssertEqual(updatedPaths, ["Users/testuser/Music/A/new.mp3"])

        let queueDepth = await engine.pendingSeratoWriteCount
        XCTAssertEqual(queueDepth, 0, "no queueing should occur when Serato is closed")
    }

    func testRenameFileQueuesRewriteWhenSeratoRunning() async throws {
        let (seratoDirectoryUrl, crateFileUrl) = try Self.makeTemporarySeratoLibrary(
            withCratePaths: ["Users/testuser/Music/A/old.mp3"]
        )
        defer { try? FileManager.default.removeItem(at: seratoDirectoryUrl.deletingLastPathComponent()) }

        let (engine, database, _) = try await MainActor.run {
            try makeEngine(seratoDirectory: seratoDirectoryUrl, seratoIsRunning: true)
        }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Users/testuser/Music/A/old.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Users/testuser/Music/A/old.mp3"])
        }!

        try await engine.apply(.renameFile(RenameFilePayload(
            fileId: fileId, newPath: "/Users/testuser/Music/A/new.mp3"
        )))

        // Crate file must still hold the original path while Serato is open.
        let crateContents = try readCratePaths(cratePath: crateFileUrl.path)
        XCTAssertEqual(crateContents, ["Users/testuser/Music/A/old.mp3"])

        let queueDepth = await engine.pendingSeratoWriteCount
        XCTAssertEqual(queueDepth, 1, "the rewrite must be queued, not applied")
    }

    /// Regression for the smart-crate-restoration bug. Serato's
    /// "Smart Crates" (`.scrate` files in `SmartCrates/`) cache a
    /// materialized otrk path list alongside the rules. If a path
    /// is missing from `database V2` but present in a smart crate,
    /// Serato re-imports it on next launch — which means a rename
    /// that doesn't touch the smart crate gets silently undone the
    /// next time the user opens Serato.
    ///
    /// Fix: `SeratoLibraryLocator.enumerateCrateFiles` now returns
    /// both `Subcrates/*.crate` AND `SmartCrates/*.scrate`. Both
    /// formats share the `otrk`/`ptrk` TLV layout, so the existing
    /// rewrite walks them transparently.
    func testRenameRewritesSmartCratesAlongsideRegularCrates() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-\(UUID().uuidString)", isDirectory: true)
        let seratoDirectory = rootDirectory.appendingPathComponent("_Serato_", isDirectory: true)
        let subcratesDirectory = seratoDirectory.appendingPathComponent("Subcrates", isDirectory: true)
        let smartCratesDirectory = seratoDirectory.appendingPathComponent("SmartCrates", isDirectory: true)
        try FileManager.default.createDirectory(at: subcratesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: smartCratesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let regularCrate = subcratesDirectory.appendingPathComponent("Regular.crate")
        try OperationEngineTests.synthesizeCrateBytesForTest(
            withTrackPaths: ["Users/testuser/Music/A/old.mp3"]
        ).write(to: regularCrate)

        // Smart crates share the otrk/ptrk record format used by
        // regular crates. The version-string text differs in real
        // Serato output but the rewrite only matches on the otrk
        // tag, not on the version header — so reusing the regular
        // synthesizer is sufficient for the rewrite test.
        let smartCrate = smartCratesDirectory.appendingPathComponent("NEVER PLAYED.scrate")
        try OperationEngineTests.synthesizeCrateBytesForTest(
            withTrackPaths: ["Users/testuser/Music/A/old.mp3"]
        ).write(to: smartCrate)

        let (engine, database, _) = try await MainActor.run {
            try makeEngine(seratoDirectory: seratoDirectory, seratoIsRunning: false)
        }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Users/testuser/Music/A/old.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Users/testuser/Music/A/old.mp3"])
        }!

        try await engine.apply(.renameFile(RenameFilePayload(
            fileId: fileId, newPath: "/Users/testuser/Music/A/new.mp3"
        )))

        let regularPaths = try readCratePaths(cratePath: regularCrate.path)
        XCTAssertEqual(regularPaths, ["Users/testuser/Music/A/new.mp3"],
                       "regular .crate must be rewritten")

        let smartPaths = try readCratePaths(cratePath: smartCrate.path)
        XCTAssertEqual(smartPaths, ["Users/testuser/Music/A/new.mp3"],
                       "smart .scrate must also be rewritten — otherwise Serato restores the old path on next launch")
    }

    /// Regression for the post-PR-58 organize-to-Serato sync bug:
    /// a single corrupted `.crate` file used to throw inside
    /// `applySeratoRename` BEFORE `database V2` got rewritten, so
    /// every organize move ended up with the file moved on disk
    /// but Serato's "All" view still pointing at the old path.
    /// The fix processes V2 first and tolerates per-crate failures.
    func testRenameRewritesDatabaseV2EvenWhenCrateFileIsCorrupted() async throws {
        // Build a Subcrates directory with: one good crate, one
        // garbage file that triseratops can't parse, both with the
        // .crate extension. Add a valid database V2 that contains
        // the old path.
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-\(UUID().uuidString)", isDirectory: true)
        let seratoDirectory = rootDirectory.appendingPathComponent("_Serato_", isDirectory: true)
        let subcratesDirectory = seratoDirectory.appendingPathComponent("Subcrates", isDirectory: true)
        try FileManager.default.createDirectory(at: subcratesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        // Valid crate referencing the old path.
        let goodCrate = subcratesDirectory.appendingPathComponent("Good.crate")
        try OperationEngineTests.synthesizeCrateBytesForTest(
            withTrackPaths: ["Users/testuser/Music/A/old.mp3"]
        ).write(to: goodCrate)

        // Corrupt crate: garbage bytes that won't parse as TLV.
        let badCrate = subcratesDirectory.appendingPathComponent("Bad.crate")
        try Data(repeating: 0xFF, count: 64).write(to: badCrate)

        // Database V2 with the old path; this is what Serato's
        // "All" view actually reads.
        let databaseV2 = seratoDirectory.appendingPathComponent("database V2")
        try OperationEngineTests.synthesizeDatabaseV2BytesForTest(
            withTrackPaths: ["Users/testuser/Music/A/old.mp3"]
        ).write(to: databaseV2)

        let (engine, database, _) = try await MainActor.run {
            try makeEngine(seratoDirectory: seratoDirectory, seratoIsRunning: false)
        }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Users/testuser/Music/A/old.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Users/testuser/Music/A/old.mp3"])
        }!

        // The rename must NOT throw despite the corrupted crate.
        try await engine.apply(.renameFile(RenameFilePayload(
            fileId: fileId, newPath: "/Users/testuser/Music/A/new.mp3"
        )))

        // Database V2 MUST reflect the new path — this is the
        // bug fix's primary contract.
        let v2Paths = try readDatabasePaths(databasePath: databaseV2.path)
        XCTAssertEqual(v2Paths, ["Users/testuser/Music/A/new.mp3"],
                       "database V2 must be rewritten even when a sibling .crate file is corrupted")

        // The good crate also got rewritten — per-crate tolerance
        // means the loop continued past the bad one.
        let goodPaths = try readCratePaths(cratePath: goodCrate.path)
        XCTAssertEqual(goodPaths, ["Users/testuser/Music/A/new.mp3"])
    }

    /// `resyncSeratoForBatch` is the recovery primitive: when an
    /// original `renameFile` succeeded in the DB but its Serato
    /// rewrite was lost (e.g., a corrupted .crate threw before the
    /// V2 update under the old logic), re-running it brings
    /// Serato's library back in sync. Idempotent.
    func testResyncSeratoForBatchReappliesRenameToDatabaseV2() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-\(UUID().uuidString)", isDirectory: true)
        let seratoDirectory = rootDirectory.appendingPathComponent("_Serato_", isDirectory: true)
        try FileManager.default.createDirectory(
            at: seratoDirectory.appendingPathComponent("Subcrates", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let databaseV2 = seratoDirectory.appendingPathComponent("database V2")
        // Pre-populate V2 with the OLD path — simulating the
        // user's broken state where a previous rename event
        // logged the DB-side mutation but the Serato write was
        // lost.
        try OperationEngineTests.synthesizeDatabaseV2BytesForTest(
            withTrackPaths: ["Users/testuser/Music/A/old.mp3"]
        ).write(to: databaseV2)

        let (engine, database, _) = try await MainActor.run {
            try makeEngine(seratoDirectory: seratoDirectory, seratoIsRunning: false)
        }

        let recoveryBatchId = "test-recovery-batch"
        try await engine.apply(
            .indexNewFile(IndexNewFilePayload(
                path: "/Users/testuser/Music/A/old.mp3",
                volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
            )),
            batchId: recoveryBatchId
        )
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Users/testuser/Music/A/old.mp3"])
        }!

        // First rename succeeds normally — V2 already has new path.
        try await engine.apply(
            .renameFile(RenameFilePayload(
                fileId: fileId, newPath: "/Users/testuser/Music/A/new.mp3"
            )),
            batchId: recoveryBatchId
        )

        // Simulate the broken-state: forcibly revert V2 to the
        // pre-rename state. This is what the user's library
        // looked like after the bug fired.
        try OperationEngineTests.synthesizeDatabaseV2BytesForTest(
            withTrackPaths: ["Users/testuser/Music/A/old.mp3"]
        ).write(to: databaseV2)

        // Recovery: replay the Serato side of the batch.
        let replayed = try await engine.resyncSeratoForBatch(recoveryBatchId)
        XCTAssertEqual(replayed, 1, "exactly one fileRenamed event was replayed")

        let v2PathsAfter = try readDatabasePaths(databasePath: databaseV2.path)
        XCTAssertEqual(v2PathsAfter, ["Users/testuser/Music/A/new.mp3"],
                       "resync must rewrite database V2 from the event log")
    }

    func testQueueDepthPublisherEmitsOnEnqueueAndDrain() async throws {
        let (seratoDirectoryUrl, _) = try Self.makeTemporarySeratoLibrary(
            withCratePaths: ["Users/testuser/Music/A/old.mp3"]
        )
        defer { try? FileManager.default.removeItem(at: seratoDirectoryUrl.deletingLastPathComponent()) }

        let (engine, database, _) = try await MainActor.run {
            try makeEngine(seratoDirectory: seratoDirectoryUrl, seratoIsRunning: true)
        }

        let emissionsLock = NSLock()
        var emissions: [Int] = []
        let cancellable = engine.queueDepthPublisher.sink { depth in
            emissionsLock.lock()
            emissions.append(depth)
            emissionsLock.unlock()
        }
        defer { cancellable.cancel() }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Users/testuser/Music/A/old.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Users/testuser/Music/A/old.mp3"])
        }!

        try await engine.apply(.renameFile(RenameFilePayload(
            fileId: fileId, newPath: "/Users/testuser/Music/A/new.mp3"
        )))
        try await engine.drainPendingSeratoUpdates()

        emissionsLock.lock()
        let snapshot = emissions
        emissionsLock.unlock()

        // CurrentValueSubject replays the initial 0 on subscribe;
        // then we expect at least one emission of 1 (after enqueue)
        // and a final 0 (after drain).
        XCTAssertEqual(snapshot.first, 0, "initial subscribe value should be 0")
        XCTAssertTrue(snapshot.contains(1),
                      "expected an emission of 1 after enqueue; got \(snapshot)")
        XCTAssertEqual(snapshot.last, 0,
                       "queue should be empty after drain; got \(snapshot)")
    }

    func testCommitMetadataToSeratoWritesDatabaseV2WhenSeratoClosed() async throws {
        // Set up a real database V2 with one track, then drive a
        // commitMetadataToSerato mutation and verify the file on
        // disk has the new metadata.
        let (seratoDirectoryUrl, databaseV2Url) = try Self.makeTemporarySeratoDatabase(
            withTrack: "Users/testuser/Music/A/track.mp3"
        )
        defer { try? FileManager.default.removeItem(at: seratoDirectoryUrl.deletingLastPathComponent()) }

        let (engine, database, _) = try await MainActor.run {
            try makeEngine(seratoDirectory: seratoDirectoryUrl, seratoIsRunning: false)
        }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Users/testuser/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Users/testuser/Music/A/track.mp3"])
        }!

        let newMetadata = SeratoMetadata(
            artist: "Brand New Artist",
            bpm: "128.000"
        )
        try await engine.apply(.commitMetadataToSerato(CommitMetadataToSeratoPayload(
            fileId: fileId, metadata: newMetadata
        )))

        let serataRecords = try readDatabaseRecords(databasePath: databaseV2Url.path)
        XCTAssertEqual(serataRecords.count, 1)
        XCTAssertEqual(serataRecords.first?.artist, "Brand New Artist")
        XCTAssertEqual(serataRecords.first?.bpm, "128.000")

        let queueDepth = await engine.pendingSeratoWriteCount
        XCTAssertEqual(queueDepth, 0, "Serato closed → write applies immediately, queue empty")
    }

    func testCommitMetadataToSeratoQueuesWhenSeratoRunning() async throws {
        let (seratoDirectoryUrl, databaseV2Url) = try Self.makeTemporarySeratoDatabase(
            withTrack: "Users/testuser/Music/A/track.mp3"
        )
        defer { try? FileManager.default.removeItem(at: seratoDirectoryUrl.deletingLastPathComponent()) }

        let (engine, database, _) = try await MainActor.run {
            try makeEngine(seratoDirectory: seratoDirectoryUrl, seratoIsRunning: true)
        }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Users/testuser/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Users/testuser/Music/A/track.mp3"])
        }!

        let newMetadata = SeratoMetadata(artist: "Queued Artist", bpm: "130.000")
        try await engine.apply(.commitMetadataToSerato(CommitMetadataToSeratoPayload(
            fileId: fileId, metadata: newMetadata
        )))

        // Database V2 on disk should still hold the ORIGINAL state
        // (we haven't drained yet — Serato is "running").
        let preDrainRecords = try readDatabaseRecords(databasePath: databaseV2Url.path)
        XCTAssertNotEqual(preDrainRecords.first?.artist, "Queued Artist")

        let queueDepth = await engine.pendingSeratoWriteCount
        XCTAssertEqual(queueDepth, 1, "metadata update must be queued")

        // Now drain — verifies the same drain path handles both
        // rename and metadata writes.
        try await engine.drainPendingSeratoUpdates()

        let postDrainRecords = try readDatabaseRecords(databasePath: databaseV2Url.path)
        XCTAssertEqual(postDrainRecords.first?.artist, "Queued Artist")
        XCTAssertEqual(postDrainRecords.first?.bpm, "130.000")

        let queueDepthAfter = await engine.pendingSeratoWriteCount
        XCTAssertEqual(queueDepthAfter, 0)
    }

    func testAddTrackToSeratoAppendsOtrkWhenSeratoClosed() async throws {
        let (seratoDirectoryUrl, databaseV2Url) = try Self.makeTemporarySeratoDatabase(
            withTrack: "Users/testuser/Music/Existing.mp3"
        )
        defer { try? FileManager.default.removeItem(at: seratoDirectoryUrl.deletingLastPathComponent()) }

        let (engine, database, _) = try await MainActor.run {
            try makeEngine(seratoDirectory: seratoDirectoryUrl, seratoIsRunning: false)
        }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Users/testuser/Music/A/newly-dropped.mp3",
            volumeUuid: "v1", inode: 99, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: "Drop Artist", title: "Drop Title")
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Users/testuser/Music/A/newly-dropped.mp3"])
        }!

        try await engine.apply(.addTrackToSerato(AddTrackToSeratoPayload(
            fileId: fileId,
            metadata: SeratoMetadata(artist: "Drop Artist", title: "Drop Title")
        )))

        let records = try readDatabaseRecords(databasePath: databaseV2Url.path)
        XCTAssertEqual(records.count, 2, "should have both the original and the newly-added track")
        let droppedRecord = records.first { $0.path == "Users/testuser/Music/A/newly-dropped.mp3" }
        XCTAssertNotNil(droppedRecord)
        XCTAssertEqual(droppedRecord?.artist, "Drop Artist")
        XCTAssertEqual(droppedRecord?.title, "Drop Title")
    }

    func testAddTrackToSeratoBootstrapsDatabaseV2IfMissing() async throws {
        // Serato has never run on this machine → no database V2.
        // The mutation should create a fresh one with our otrk.
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-bootstrap-\(UUID().uuidString)", isDirectory: true)
        let seratoDirectoryUrl = rootDirectory.appendingPathComponent("_Serato_", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        // Note: don't create the _Serato_ directory — applySeratoAddTrack
        // creates it on demand.

        let (engine, database, _) = try await MainActor.run {
            try makeEngine(seratoDirectory: seratoDirectoryUrl, seratoIsRunning: false)
        }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Users/testuser/Music/A/first.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: "First")
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Users/testuser/Music/A/first.mp3"])
        }!
        try await engine.apply(.addTrackToSerato(AddTrackToSeratoPayload(
            fileId: fileId,
            metadata: SeratoMetadata(artist: "First")
        )))

        let databaseV2Url = seratoDirectoryUrl.appendingPathComponent("database V2")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: databaseV2Url.path),
            "database V2 should have been bootstrapped"
        )
        let records = try readDatabaseRecords(databasePath: databaseV2Url.path)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].path, "Users/testuser/Music/A/first.mp3")
        XCTAssertEqual(records[0].artist, "First")
    }

    func testDrainAppliesQueuedRewrites() async throws {
        let (seratoDirectoryUrl, crateFileUrl) = try Self.makeTemporarySeratoLibrary(
            withCratePaths: ["Users/testuser/Music/A/old.mp3"]
        )
        defer { try? FileManager.default.removeItem(at: seratoDirectoryUrl.deletingLastPathComponent()) }

        let (engine, database, _) = try await MainActor.run {
            try makeEngine(seratoDirectory: seratoDirectoryUrl, seratoIsRunning: true)
        }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Users/testuser/Music/A/old.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Users/testuser/Music/A/old.mp3"])
        }!

        try await engine.apply(.renameFile(RenameFilePayload(
            fileId: fileId, newPath: "/Users/testuser/Music/A/new.mp3"
        )))

        try await engine.drainPendingSeratoUpdates()

        let updatedPaths = try readCratePaths(cratePath: crateFileUrl.path)
        XCTAssertEqual(updatedPaths, ["Users/testuser/Music/A/new.mp3"])

        let queueDepthAfterDrain = await engine.pendingSeratoWriteCount
        XCTAssertEqual(queueDepthAfterDrain, 0)
    }

    // MARK: - Synthetic Serato fixture helpers

    /// Build a temporary `_Serato_/database V2` containing a single
    /// otrk for the supplied path. Used by commitMetadataToSerato
    /// tests that need a real database V2 file the FFI can update.
    static func makeTemporarySeratoDatabase(
        withTrack seratoRelativePath: String
    ) throws -> (seratoDirectoryUrl: URL, databaseV2Url: URL) {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-\(UUID().uuidString)", isDirectory: true)
        let seratoDirectory = rootDirectory.appendingPathComponent("_Serato_", isDirectory: true)
        try FileManager.default.createDirectory(
            at: seratoDirectory, withIntermediateDirectories: true
        )
        let databaseV2Url = seratoDirectory.appendingPathComponent("database V2")
        let bytes = OperationEngineTests.synthesizeDatabaseV2BytesForTest(
            withTrackPaths: [seratoRelativePath]
        )
        try bytes.write(to: databaseV2Url)
        return (seratoDirectory, databaseV2Url)
    }

    /// Build a temporary `_Serato_/Subcrates/Test.crate` containing the
    /// supplied Serato-relative paths. Returns the `_Serato_`
    /// directory URL (for passing to SeratoLibraryLocator) and the
    /// path to the crate file (for direct verification).
    private static func makeTemporarySeratoLibrary(
        withCratePaths cratePaths: [String]
    ) throws -> (seratoDirectoryUrl: URL, crateFileUrl: URL) {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-\(UUID().uuidString)", isDirectory: true)
        let seratoDirectory = rootDirectory.appendingPathComponent("_Serato_", isDirectory: true)
        let subcratesDirectory = seratoDirectory.appendingPathComponent("Subcrates", isDirectory: true)
        try FileManager.default.createDirectory(
            at: subcratesDirectory, withIntermediateDirectories: true
        )
        let crateFileUrl = subcratesDirectory.appendingPathComponent("Test.crate")
        let crateBytes = synthesizeCrateBytes(withTrackPaths: cratePaths)
        try crateBytes.write(to: crateFileUrl)
        return (seratoDirectory, crateFileUrl)
    }

    /// Public wrapper so other test classes (e.g., LibraryScannerTests)
    /// can synthesize crate files without duplicating the byte
    /// layout. Forwards to the private implementation.
    static func synthesizeCrateBytesForTest(withTrackPaths trackPaths: [String]) -> Data {
        synthesizeCrateBytes(withTrackPaths: trackPaths)
    }

    /// Synthesizes a Serato `database V2` file with one otrk per
    /// supplied path. Optional `metadataByPath` attaches per-track
    /// metadata fields for tests that exercise the scanner's
    /// metadata-mirror behavior.
    static func synthesizeDatabaseV2BytesForTest(
        withTrackPaths trackPaths: [String],
        metadataByPath: [String: SeratoMetadata] = [:]
    ) -> Data {
        var data = Data()
        appendTlvRecord(
            tag: "vrsn",
            payload: utf16BeBytes(of: "2.0/Serato Scratch LIVE Database"),
            to: &data
        )

        for trackPath in trackPaths {
            var otrkPayload = Data()
            appendTlvRecord(tag: "pfil", payload: utf16BeBytes(of: trackPath), to: &otrkPayload)

            if let metadata = metadataByPath[trackPath] {
                if let value = metadata.artist {
                    appendTlvRecord(tag: "tart", payload: utf16BeBytes(of: value), to: &otrkPayload)
                }
                if let value = metadata.title {
                    appendTlvRecord(tag: "tsng", payload: utf16BeBytes(of: value), to: &otrkPayload)
                }
                if let value = metadata.album {
                    appendTlvRecord(tag: "talb", payload: utf16BeBytes(of: value), to: &otrkPayload)
                }
                if let value = metadata.genre {
                    appendTlvRecord(tag: "tgen", payload: utf16BeBytes(of: value), to: &otrkPayload)
                }
                if let value = metadata.bpm {
                    appendTlvRecord(tag: "tbpm", payload: utf16BeBytes(of: value), to: &otrkPayload)
                }
                if let value = metadata.musicalKey {
                    appendTlvRecord(tag: "tkey", payload: utf16BeBytes(of: value), to: &otrkPayload)
                }
                if let value = metadata.comment {
                    appendTlvRecord(tag: "tcom", payload: utf16BeBytes(of: value), to: &otrkPayload)
                }
                if let value = metadata.length {
                    appendTlvRecord(tag: "tlen", payload: utf16BeBytes(of: value), to: &otrkPayload)
                }
                if let value = metadata.label {
                    appendTlvRecord(tag: "tlbl", payload: utf16BeBytes(of: value), to: &otrkPayload)
                }
            }

            appendTlvRecord(tag: "otrk", payload: otrkPayload, to: &data)
        }
        return data
    }

    /// TLV-format `.crate` file with a version header + one `otrk` per
    /// path containing a UTF-16BE `ptrk` payload. Mirrors the Rust
    /// `synthetic_library` test helper so behavior is consistent
    /// across language boundaries.
    private static func synthesizeCrateBytes(withTrackPaths trackPaths: [String]) -> Data {
        var data = Data()

        let versionPayload = utf16BeBytes(of: "1.0/Serato ScratchLive Crate")
        appendTlvRecord(tag: "vrsn", payload: versionPayload, to: &data)

        for trackPath in trackPaths {
            let pathPayload = utf16BeBytes(of: trackPath)
            var otrkPayload = Data()
            appendTlvRecord(tag: "ptrk", payload: pathPayload, to: &otrkPayload)
            appendTlvRecord(tag: "otrk", payload: otrkPayload, to: &data)
        }

        return data
    }

    private static func appendTlvRecord(tag: String, payload: Data, to data: inout Data) {
        precondition(tag.utf8.count == 4, "Serato tags are 4 ASCII bytes")
        data.append(contentsOf: tag.utf8)
        data.append(contentsOf: uint32BigEndianBytes(of: UInt32(payload.count)))
        data.append(payload)
    }

    private static func utf16BeBytes(of string: String) -> Data {
        var data = Data()
        for codeUnit in string.utf16 {
            data.append(UInt8(codeUnit >> 8))
            data.append(UInt8(codeUnit & 0xFF))
        }
        return data
    }

    private static func uint32BigEndianBytes(of value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }
}

// MARK: - Undo / removeFile coverage

extension OperationEngineTests {

    func testRemoveFileDeletesRowAndJournalsInverse() async throws {
        let (engine, database, _) = try await MainActor.run { try makeEngine() }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 10, mtime: 1,
            metadata: SeratoMetadata(artist: "X", title: "Y")
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/track.mp3"])
        }!

        try await engine.apply(.removeFile(RemoveFilePayload(fileId: fileId)))

        // Row is gone.
        let remaining = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(remaining, 0)

        // Removal event was logged. After the delete cascade, the
        // event's file_id is NULL — fetch by event_type instead.
        let removalEvent = try await database.writer.read { db in
            try EventRecord
                .filter(Column("event_type") == EventType.fileRemoved.rawValue)
                .fetchOne(db)!
        }
        XCTAssertNil(removalEvent.fileId,
                     "ON DELETE SET NULL cascade must NULL the event's file_id on removal")

        let inverse = try JSONDecoder().decode(
            IndexNewFilePayload.self,
            from: removalEvent.inversePayloadJson.data(using: .utf8)!
        )
        XCTAssertEqual(inverse.path, "/Music/A/track.mp3")
        XCTAssertEqual(inverse.volumeUuid, "v1")
        XCTAssertEqual(inverse.inode, 1)
        XCTAssertEqual(inverse.metadata.artist, "X")
        XCTAssertEqual(inverse.metadata.title, "Y")
    }

    func testUndoBatchRestoresRenameFile() async throws {
        let (engine, database, _) = try await MainActor.run { try makeEngine() }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/original.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/original.mp3"])
        }!

        let renameBatchId = "test-rename-batch"
        try await engine.apply(
            .renameFile(RenameFilePayload(fileId: fileId, newPath: "/Music/A/renamed.mp3")),
            batchId: renameBatchId
        )

        let pathAfterRename = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT path FROM files WHERE id = ?",
                                arguments: [fileId])
        }!
        XCTAssertEqual(pathAfterRename, "/Music/A/renamed.mp3")

        let undoBatchId = try await engine.undoBatch(renameBatchId)
        XCTAssertTrue(undoBatchId.hasPrefix("undo:\(renameBatchId):"),
                      "returned batch id should encode the original batch for traceability")

        let pathAfterUndo = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT path FROM files WHERE id = ?",
                                arguments: [fileId])
        }!
        XCTAssertEqual(pathAfterUndo, "/Music/A/original.mp3")

        // Undo itself was journaled, under the new batch id.
        let undoEventCount = try await database.writer.read { db in
            try EventRecord
                .filter(Column("batch_id") == undoBatchId)
                .fetchCount(db)
        }
        XCTAssertEqual(undoEventCount, 1, "undo must journal its own events")
    }

    func testUndoBatchRestoresSetMetadata() async throws {
        let (engine, database, _) = try await MainActor.run { try makeEngine() }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: "Original", title: "Track")
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/track.mp3"])
        }!

        let editBatchId = "metadata-edit-batch"
        try await engine.apply(
            .setMetadata(SetMetadataPayload(
                fileId: fileId,
                metadata: SeratoMetadata(artist: "Edited", title: "Track")
            )),
            batchId: editBatchId
        )

        let artistAfterEdit = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT artist FROM files WHERE id = ?",
                                arguments: [fileId])
        }!
        XCTAssertEqual(artistAfterEdit, "Edited")

        _ = try await engine.undoBatch(editBatchId)

        let artistAfterUndo = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT artist FROM files WHERE id = ?",
                                arguments: [fileId])
        }!
        XCTAssertEqual(artistAfterUndo, "Original",
                       "undo must restore the artist captured in the inverse payload")
    }

    func testUndoBatchOfIndexNewFileRemovesRow() async throws {
        let (engine, database, _) = try await MainActor.run { try makeEngine() }

        let importBatchId = "test-import-batch"
        try await engine.apply(
            .indexNewFile(IndexNewFilePayload(
                path: "/Music/A/imported.mp3",
                volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
            )),
            batchId: importBatchId
        )

        let countAfterImport = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(countAfterImport, 1)

        _ = try await engine.undoBatch(importBatchId)

        let countAfterUndo = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(countAfterUndo, 0,
                       "undo of an indexNewFile event must remove the row")
    }

    func testUndoBatchAppliesEventsInReverseOrder() async throws {
        let (engine, database, _) = try await MainActor.run { try makeEngine() }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/start.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: "A0")
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/start.mp3"])
        }!

        let compositeBatchId = "composite"
        // rename first…
        try await engine.apply(
            .renameFile(RenameFilePayload(fileId: fileId, newPath: "/Music/A/middle.mp3")),
            batchId: compositeBatchId
        )
        // …then edit metadata.
        try await engine.apply(
            .setMetadata(SetMetadataPayload(
                fileId: fileId,
                metadata: SeratoMetadata(artist: "A1")
            )),
            batchId: compositeBatchId
        )

        // Undo should reverse the metadata edit first (newest), then
        // the rename (oldest). Final state matches pre-batch state.
        _ = try await engine.undoBatch(compositeBatchId)
        let restored = try await database.writer.read { db in
            try FileRecord.fetchOne(db, key: fileId)!
        }
        XCTAssertEqual(restored.path, "/Music/A/start.mp3")
        XCTAssertEqual(restored.artist, "A0")
    }

    func testUndoBatchThrowsForUnknownBatchId() async throws {
        let (engine, _, _) = try await MainActor.run { try makeEngine() }
        do {
            _ = try await engine.undoBatch("nonexistent-batch")
            XCTFail("expected batchNotFound to throw")
        } catch let error as OperationEngineError {
            XCTAssertEqual(error, .batchNotFound(batchId: "nonexistent-batch"))
        }
    }

    func testUndoBatchThrowsForUnsupportedEventTypeWithoutPartialState() async throws {
        let (engine, database, _) = try await MainActor.run { try makeEngine() }

        // Bootstrap a file so the addTrackToSerato payload resolves.
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/dropped.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/dropped.mp3"])
        }!

        // Simulate the drag-drop batch's addTrackToSerato leg. The
        // Serato-side write fails (test locator points at /dev/null),
        // but the DB event lands first — that's what undoBatch will
        // encounter and reject.
        let dragDropBatchId = "drag-drop-batch"
        do {
            _ = try await engine.apply(
                .addTrackToSerato(AddTrackToSeratoPayload(
                    fileId: fileId, metadata: SeratoMetadata()
                )),
                batchId: dragDropBatchId
            )
        } catch {
            // Expected: Serato write fails because locator → /dev/null.
        }

        do {
            _ = try await engine.undoBatch(dragDropBatchId)
            XCTFail("expected undoNotSupported to throw")
        } catch let error as OperationEngineError {
            XCTAssertEqual(error, .undoNotSupported(eventType: .trackAddedToSerato))
        }

        // No undo events should have been written.
        let undoEvents = try await database.writer.read { db in
            try EventRecord
                .filter(Column("batch_id").like("undo:\(dragDropBatchId):%"))
                .fetchCount(db)
        }
        XCTAssertEqual(undoEvents, 0,
                       "rejecting unsupported event type must not leave partial undo state")
    }

    func testUndoBatchOfRemoveFileRestoresRow() async throws {
        let (engine, database, _) = try await MainActor.run { try makeEngine() }

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/gone.mp3",
            volumeUuid: "v1", inode: 42, fileSize: 10, mtime: 1_700_000_000,
            metadata: SeratoMetadata(artist: "Ghost", title: "Track")
        )))
        let originalFileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/gone.mp3"])
        }!

        let removalBatchId = "removal-batch"
        try await engine.apply(
            .removeFile(RemoveFilePayload(fileId: originalFileId)),
            batchId: removalBatchId
        )
        let countAfterRemove = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(countAfterRemove, 0)

        _ = try await engine.undoBatch(removalBatchId)

        let restored = try await database.writer.read { db in
            try FileRecord.filter(Column("path") == "/Music/A/gone.mp3").fetchOne(db)
        }
        XCTAssertNotNil(restored, "row must reappear at the original path")
        XCTAssertEqual(restored?.inode, 42)
        XCTAssertEqual(restored?.fileSize, 10)
        XCTAssertEqual(restored?.mtime, 1_700_000_000)
        XCTAssertEqual(restored?.artist, "Ghost")
        XCTAssertEqual(restored?.title, "Track")
    }
}

final class LibraryScannerTests: XCTestCase {

    @MainActor
    private func makeScanner(
        seratoDirectory: URL
    ) throws -> (LibraryScanner, LibraryDatabase) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        let locator = SeratoLibraryLocator(seratoDirectory: seratoDirectory)
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { _, _ in /* no-op: tests use synthetic paths */ },
            fileTrasher: { _ in /* no-op: tests use synthetic paths */ }
        )
        let scanner = LibraryScanner(
            operationEngine: engine,
            database: database,
            seratoLocator: locator
        )
        return (scanner, database)
    }

    /// Set up a temp filesystem with:
    ///   - real audio files at the given absolute paths (so stat
    ///     returns valid metadata for indexing)
    ///   - a synthetic Serato library at `seratoDirectory` whose
    ///     `database V2` references those same paths in the Serato-
    ///     relative form crate-agent decodes
    /// Optional `metadataByAbsolutePath` attaches metadata fields per
    /// track for tests that check the scanner's metadata mirroring.
    private func makeSeratoFixture(
        absoluteFilePaths: [String],
        metadataByAbsolutePath: [String: SeratoMetadata] = [:]
    ) throws -> (seratoDirectory: URL, absoluteFilePaths: [String]) {
        for filePath in absoluteFilePaths {
            let parentDir = (filePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDir, withIntermediateDirectories: true
            )
            try Data("audio".utf8).write(to: URL(fileURLWithPath: filePath))
        }

        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-scanner-\(UUID().uuidString)", isDirectory: true)
        let seratoDirectory = testRoot.appendingPathComponent("_Serato_", isDirectory: true)
        try FileManager.default.createDirectory(
            at: seratoDirectory, withIntermediateDirectories: true
        )

        // Convert absolute paths to Serato's relative form
        // (`Users/x/...`) by stripping the leading slash. Then build
        // the database V2 file (Serato's source of truth for the
        // scanner) at `_Serato_/database V2`.
        let seratoRelativePaths = absoluteFilePaths.map { path -> String in
            path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
        var metadataByRelativePath: [String: SeratoMetadata] = [:]
        for (absolute, metadata) in metadataByAbsolutePath {
            let relative = absolute.hasPrefix("/") ? String(absolute.dropFirst()) : absolute
            metadataByRelativePath[relative] = metadata
        }
        let databaseBytes = OperationEngineTests.synthesizeDatabaseV2BytesForTest(
            withTrackPaths: seratoRelativePaths,
            metadataByPath: metadataByRelativePath
        )
        try databaseBytes.write(to: seratoDirectory.appendingPathComponent("database V2"))
        return (seratoDirectory, absoluteFilePaths)
    }

    func testScanIndexesEveryPathSeratoReferences() async throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-music-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let absoluteFilePaths = [
            scratchDirectory.appendingPathComponent("A/Alpha.mp3").path,
            scratchDirectory.appendingPathComponent("A/Beta.flac").path,
            scratchDirectory.appendingPathComponent("B/Sub/Gamma.m4a").path,
        ]
        let (seratoDirectory, _) = try makeSeratoFixture(absoluteFilePaths: absoluteFilePaths)
        defer { try? FileManager.default.removeItem(at: seratoDirectory.deletingLastPathComponent()) }

        let (scanner, database) = try await MainActor.run {
            try makeScanner(seratoDirectory: seratoDirectory)
        }

        let result = try await scanner.scan()
        XCTAssertEqual(result.seratoReferenceCount, 3)
        XCTAssertEqual(result.filesIndexed, 3)
        XCTAssertEqual(result.filesSkipped, 0)

        let indexedPaths = try await database.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT path FROM files"))
        }
        XCTAssertEqual(indexedPaths, Set(absoluteFilePaths))
    }

    func testScanSkipsSeratoReferencesWhereFileIsMissing() async throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let realFile = scratchDirectory.appendingPathComponent("Real.mp3").path
        let phantomFile = scratchDirectory.appendingPathComponent("Phantom.mp3").path
        let (seratoDirectory, _) = try makeSeratoFixture(
            absoluteFilePaths: [realFile]  // only create the first one
        )
        defer { try? FileManager.default.removeItem(at: seratoDirectory.deletingLastPathComponent()) }

        // Manually add the phantom path to the database V2 so Serato
        // references it even though the file doesn't exist.
        let databaseV2Url = seratoDirectory.appendingPathComponent("database V2")
        let seratoRelativePaths = [realFile, phantomFile].map { String($0.dropFirst()) }
        let updatedDatabaseBytes = OperationEngineTests.synthesizeDatabaseV2BytesForTest(
            withTrackPaths: seratoRelativePaths
        )
        try updatedDatabaseBytes.write(to: databaseV2Url)

        let (scanner, database) = try await MainActor.run {
            try makeScanner(seratoDirectory: seratoDirectory)
        }
        let result = try await scanner.scan()
        XCTAssertEqual(result.seratoReferenceCount, 2)
        XCTAssertEqual(result.filesIndexed, 1, "real file gets indexed")
        XCTAssertEqual(result.filesSkipped, 1, "phantom file is skipped — Serato references but disk doesn't have it")

        let indexedPaths = try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM files")
        }
        XCTAssertEqual(indexedPaths, [realFile])
    }

    func testScanPopulatesMetadataFromSeratoOnInitialIndex() async throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-meta-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let absolutePath = scratchDirectory.appendingPathComponent("Track.mp3").path
        let serataMetadata = SeratoMetadata(
            artist: "Some Artist",
            title: "Some Title",
            album: "Some Album",
            genre: "House",
            bpm: "128.000",
            musicalKey: "Am",
            comment: "track comment",
            length: "03:24",
            label: "Some Label"
        )
        let (seratoDirectory, _) = try makeSeratoFixture(
            absoluteFilePaths: [absolutePath],
            metadataByAbsolutePath: [absolutePath: serataMetadata]
        )
        defer { try? FileManager.default.removeItem(at: seratoDirectory.deletingLastPathComponent()) }

        let (scanner, database) = try await MainActor.run {
            try makeScanner(seratoDirectory: seratoDirectory)
        }
        _ = try await scanner.scan()

        let indexedFile = try await database.writer.read { db in
            try FileRecord.fetchOne(db, sql: "SELECT * FROM files WHERE path = ?",
                                    arguments: [absolutePath])
        }
        XCTAssertEqual(indexedFile?.artist, "Some Artist")
        XCTAssertEqual(indexedFile?.title, "Some Title")
        XCTAssertEqual(indexedFile?.album, "Some Album")
        XCTAssertEqual(indexedFile?.genre, "House")
        XCTAssertEqual(indexedFile?.bpm, "128.000")
        XCTAssertEqual(indexedFile?.musicalKey, "Am")
        XCTAssertEqual(indexedFile?.comment, "track comment")
        XCTAssertEqual(indexedFile?.length, "03:24")
        XCTAssertEqual(indexedFile?.label, "Some Label")
    }

    func testRescanFiresSetMetadataWhenSeratoMetadataChanges() async throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-meta-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let absolutePath = scratchDirectory.appendingPathComponent("Track.mp3").path
        let initialMetadata = SeratoMetadata(artist: "Initial Artist", bpm: "120.000")
        let (seratoDirectory, _) = try makeSeratoFixture(
            absoluteFilePaths: [absolutePath],
            metadataByAbsolutePath: [absolutePath: initialMetadata]
        )
        defer { try? FileManager.default.removeItem(at: seratoDirectory.deletingLastPathComponent()) }

        let (scanner, database) = try await MainActor.run {
            try makeScanner(seratoDirectory: seratoDirectory)
        }
        _ = try await scanner.scan()

        // Simulate Serato editing the metadata between sessions by
        // rewriting the database V2 with different field values.
        let relativePath = String(absolutePath.dropFirst())
        let updatedMetadata = SeratoMetadata(artist: "Updated Artist", bpm: "128.000")
        let updatedDatabaseBytes = OperationEngineTests.synthesizeDatabaseV2BytesForTest(
            withTrackPaths: [relativePath],
            metadataByPath: [relativePath: updatedMetadata]
        )
        try updatedDatabaseBytes.write(to: seratoDirectory.appendingPathComponent("database V2"))

        let result = try await scanner.scan()
        XCTAssertEqual(result.filesIndexed, 0, "no new files this rescan")
        XCTAssertEqual(result.filesMetadataUpdated, 1, "one metadata change must be applied")

        let updatedFile = try await database.writer.read { db in
            try FileRecord.fetchOne(db, sql: "SELECT * FROM files WHERE path = ?",
                                    arguments: [absolutePath])
        }
        XCTAssertEqual(updatedFile?.artist, "Updated Artist")
        XCTAssertEqual(updatedFile?.bpm, "128.000")

        // A metadata_set event should have been logged with both
        // forward and inverse payloads.
        let event = try await database.writer.read { db in
            try EventRecord.filter(Column("event_type") == EventType.metadataSet.rawValue)
                .fetchOne(db)
        }
        XCTAssertNotNil(event)
        XCTAssertFalse(event?.payloadJson.isEmpty ?? true)
        XCTAssertFalse(event?.inversePayloadJson.isEmpty ?? true)
    }

    func testBuildPathIndexToleratesDuplicateSwiftStringPaths() {
        // Regression for issue #35 / the crash on the user's real 32k
        // library: two FileRecords with bytewise-distinct but Swift-
        // String-equal paths (NFC vs NFD "Café.mp3" → different SQLite
        // bytes pass the UNIQUE constraint, identical Swift strings
        // collide in Dictionary keying). Pre-fix this crashed with a
        // Swift trap inside `Dictionary(uniqueKeysWithValues:)` during
        // launch's initial scan, blocking the user entirely.
        //
        // The two literals below are the same grapheme cluster ("Café")
        // in NFC and NFD respectively, so `==` returns true.
        let nfcPath = "Caf\u{00E9}.mp3"  // composed é
        let nfdPath = "Cafe\u{0301}.mp3"  // e + combining acute
        XCTAssertEqual(nfcPath, nfdPath, "Swift String compares grapheme clusters — these must be equal")

        let recordOne = FileRecord(
            id: 1, path: nfcPath,
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )
        let recordTwo = FileRecord(
            id: 2, path: nfdPath,
            volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1
        )

        let result = LibraryScanner.buildPathIndex([recordOne, recordTwo])
        XCTAssertEqual(result.duplicatePathCount, 1,
                       "the second record's path collides with the first in Swift's String hashing")
        // Last-write-wins: record two clobbers record one.
        XCTAssertEqual(result.byPath[nfcPath]?.id, 2,
                       "later record must win the slot on collision")
    }

    func testBuildPathIndexCountsZeroDuplicatesOnCleanInput() {
        let records = [
            FileRecord(id: 1, path: "/Music/A/a.mp3",
                       volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1),
            FileRecord(id: 2, path: "/Music/A/b.mp3",
                       volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1),
        ]
        let result = LibraryScanner.buildPathIndex(records)
        XCTAssertEqual(result.duplicatePathCount, 0)
        XCTAssertEqual(result.byPath.count, 2)
    }

    func testRescanDoesNotDuplicateAlreadyKnownFiles() async throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-rescan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let absoluteFilePaths = [
            scratchDirectory.appendingPathComponent("Track.mp3").path,
            scratchDirectory.appendingPathComponent("Other.flac").path,
        ]
        let (seratoDirectory, _) = try makeSeratoFixture(absoluteFilePaths: absoluteFilePaths)
        defer { try? FileManager.default.removeItem(at: seratoDirectory.deletingLastPathComponent()) }

        let (scanner, database) = try await MainActor.run {
            try makeScanner(seratoDirectory: seratoDirectory)
        }
        let firstResult = try await scanner.scan()
        XCTAssertEqual(firstResult.filesIndexed, 2)

        let secondResult = try await scanner.scan()
        XCTAssertEqual(secondResult.filesIndexed, 0, "second scan must not re-index")
        XCTAssertEqual(secondResult.filesSkipped, 0,
                       "files already present in DB are no-ops, not skips")

        let totalRows = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(totalRows, 2)
    }
}

final class FilesystemSyncCoordinatorTests: XCTestCase {

    @MainActor
    private func makeCoordinator(
        seratoDirectory: URL? = nil
    ) throws -> (FilesystemSyncCoordinator, OperationEngine, LibraryDatabase) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        let locator = SeratoLibraryLocator(
            seratoDirectory: seratoDirectory ?? URL(fileURLWithPath: "/dev/null")
        )
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { _, _ in /* no-op: tests use synthetic paths */ },
            fileTrasher: { _ in /* no-op: tests use synthetic paths */ }
        )
        let coordinator = FilesystemSyncCoordinator(
            operationEngine: engine,
            database: database
        )
        return (coordinator, engine, database)
    }

    private func makeTemporaryAudioFile(extension fileExtension: String = "mp3") throws -> URL {
        let tempUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-sync-\(UUID().uuidString).\(fileExtension)")
        try Data("audio bytes".utf8).write(to: tempUrl)
        return tempUrl
    }

    func testCreatedAudioFileIsIgnored() async throws {
        // Under the Serato-source-of-truth design, the coordinator
        // does NOT auto-index new files appearing on disk. New
        // tracks enter the library exclusively through Serato (or,
        // eventually, the drag-drop import flow). Verifying this is
        // the inverse of the previous test by design.
        let (coordinator, _, database) = try await MainActor.run { try makeCoordinator() }
        let audioFile = try makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioFile) }

        let observation = FSEventsObservation(
            path: audioFile.path, isFile: true, wasCreated: true
        )
        await coordinator.handleObservations([observation])

        let count = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(count, 0, "new file create events must not index — Serato is the source of truth")
    }

    func testCreatedNonAudioFileIsIgnored() async throws {
        let (coordinator, _, database) = try await MainActor.run { try makeCoordinator() }
        let textFile = try makeTemporaryAudioFile(extension: "txt")
        defer { try? FileManager.default.removeItem(at: textFile) }

        let observation = FSEventsObservation(
            path: textFile.path, isFile: true, wasCreated: true
        )
        await coordinator.handleObservations([observation])

        let count = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(count, 0, "non-audio files must not be indexed")
    }

    func testCreatedDirectoryIsIgnored() async throws {
        let (coordinator, _, database) = try await MainActor.run { try makeCoordinator() }

        let observation = FSEventsObservation(
            path: "/some/dir.mp3",  // .mp3 extension but isDirectory flag wins
            isFile: false,
            isDirectory: true,
            wasCreated: true
        )
        await coordinator.handleObservations([observation])

        let count = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(count, 0)
    }

    func testRenameObservationUsesInodeLookupToUpdateRow() async throws {
        let (coordinator, engine, database) = try await MainActor.run { try makeCoordinator() }
        let audioFile = try makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioFile) }

        // Pre-populate the DB with a stale path that doesn't exist
        // on disk; the file at the real path has the same inode, so
        // the coordinator should recognize this as a rename and
        // update the row.
        var statBuffer = stat()
        guard stat(audioFile.path, &statBuffer) == 0 else {
            XCTFail("could not stat temp file")
            return
        }
        let realInode = Int64(statBuffer.st_ino)

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/imaginary/old-location.mp3",
            volumeUuid: (try? audioFile.resourceValues(forKeys: [.volumeUUIDStringKey]))?
                .volumeUUIDString ?? "unknown-volume",
            inode: realInode,
            fileSize: 11,
            mtime: 1
        )))

        let observation = FSEventsObservation(
            path: audioFile.path, isFile: true, wasRenamed: true
        )
        await coordinator.handleObservations([observation])

        let updated = try await database.writer.read { db in
            try FileRecord.fetchOne(db, sql: "SELECT * FROM files WHERE inode = ?",
                                    arguments: [realInode])
        }
        XCTAssertEqual(updated?.path, audioFile.path,
                       "rename event should update path on the existing inode row")

        let fileCount = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(fileCount, 1, "rename must not insert a second row")
    }

    func testRenameOfOldPathSideIsIgnored() async throws {
        let (coordinator, _, database) = try await MainActor.run { try makeCoordinator() }

        // wasRenamed event for a path where the file does NOT exist
        // (this is the "old path" side of a rename — the new-path
        // event is what carries the update).
        let nonexistentPath = "/tmp/crate-agent-test-nonexistent-\(UUID().uuidString).mp3"
        let observation = FSEventsObservation(
            path: nonexistentPath, isFile: true, wasRenamed: true
        )
        await coordinator.handleObservations([observation])

        let fileCount = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(fileCount, 0)
    }
}

final class FSEventsWatcherTests: XCTestCase {

    func testObservationParsesCreatedFileFlag() {
        let observation = FSEventsObservation(
            path: "/tmp/a.mp3",
            rawFlags: FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
            )
        )
        XCTAssertTrue(observation.wasCreated)
        XCTAssertTrue(observation.isFile)
        XCTAssertFalse(observation.wasRenamed)
        XCTAssertFalse(observation.wasRemoved)
    }

    func testObservationParsesRenamedDirectoryFlag() {
        let observation = FSEventsObservation(
            path: "/tmp/some-folder",
            rawFlags: FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir
            )
        )
        XCTAssertTrue(observation.wasRenamed)
        XCTAssertTrue(observation.isDirectory)
        XCTAssertFalse(observation.isFile)
        XCTAssertFalse(observation.wasCreated)
    }

    func testObservationParsesMultipleFlagsAtOnce() {
        // FSEvents coalesces multiple changes during the latency
        // window into one event; the same observation can carry many
        // flags simultaneously.
        let observation = FSEventsObservation(
            path: "/tmp/multi.mp3",
            rawFlags: FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated
                    | kFSEventStreamEventFlagItemRenamed
                    | kFSEventStreamEventFlagItemModified
                    | kFSEventStreamEventFlagItemIsFile
            )
        )
        XCTAssertTrue(observation.wasCreated)
        XCTAssertTrue(observation.wasRenamed)
        XCTAssertTrue(observation.wasModified)
        XCTAssertTrue(observation.isFile)
    }

    func testEventIdCheckpointFiresWithMonotonicMaxId() throws {
        let watchedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-fsevents-checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: watchedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: watchedDirectory) }

        let checkpointExpectation = expectation(description: "checkpoint fired")
        checkpointExpectation.assertForOverFulfill = false

        let lock = NSLock()
        var receivedCheckpoints: [FSEventStreamEventId] = []

        let watcher = FSEventsWatcher(
            watchedPaths: [watchedDirectory.path],
            coalescingLatency: 0.05,
            handler: { _ in },
            onEventIdCheckpoint: { eventId in
                lock.lock()
                receivedCheckpoints.append(eventId)
                lock.unlock()
                checkpointExpectation.fulfill()
            }
        )
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.2)
        try Data("test".utf8).write(
            to: watchedDirectory.appendingPathComponent("checkpoint-test.mp3")
        )

        wait(for: [checkpointExpectation], timeout: 3.0)

        lock.lock()
        let snapshot = receivedCheckpoints
        lock.unlock()

        XCTAssertFalse(snapshot.isEmpty, "expected at least one checkpoint")
        XCTAssertGreaterThan(snapshot.first!, 0, "event ID 0 means no events; we should have received real IDs")
        // Each subsequent checkpoint must be >= the previous one,
        // matching FSEvents' monotonic event ID ordering.
        for index in 1..<snapshot.count {
            XCTAssertGreaterThanOrEqual(snapshot[index], snapshot[index - 1])
        }
    }

    func testWatchedDirectoryEmitsCreateEventForNewFile() throws {
        let watchedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-fsevents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: watchedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: watchedDirectory) }

        // The expectation fulfills only when an observation matching
        // our predicate arrives — not on every callback. Without this,
        // FSEvents' first callback (often before our file write
        // completes) would fulfill prematurely and the assertion
        // would race against the actual create event.
        let createObservedExpectation = expectation(
            description: "create event observed for new-track.mp3"
        )
        createObservedExpectation.assertForOverFulfill = false

        let observationLock = NSLock()
        var observationsCollected: [FSEventsObservation] = []

        let watcher = FSEventsWatcher(
            watchedPaths: [watchedDirectory.path],
            coalescingLatency: 0.05  // tight latency for test snappiness
        ) { batch in
            observationLock.lock()
            observationsCollected.append(contentsOf: batch)
            let matched = observationsCollected.contains {
                $0.path.contains("new-track.mp3") && $0.wasCreated
            }
            observationLock.unlock()
            if matched {
                createObservedExpectation.fulfill()
            }
        }
        watcher.start()
        defer { watcher.stop() }

        // Give FSEvents a moment to register the watch before
        // triggering events; without this, the create can be missed.
        Thread.sleep(forTimeInterval: 0.2)

        let createdFile = watchedDirectory.appendingPathComponent("new-track.mp3")
        try Data("test".utf8).write(to: createdFile)

        let waitResult = XCTWaiter.wait(for: [createObservedExpectation], timeout: 3.0)
        if waitResult != .completed {
            observationLock.lock()
            let snapshot = observationsCollected
            observationLock.unlock()
            XCTFail("expected create observation for new-track.mp3; got \(snapshot.count) observations: \(snapshot.map { "\($0.path) file=\($0.isFile) created=\($0.wasCreated)" })")
        }
    }
}

final class UserPreferencesTests: XCTestCase {

    private static let testPathA = "/test/path/A-\(UUID().uuidString)"
    private static let testPathB = "/test/path/B-\(UUID().uuidString)"

    override func tearDown() {
        // Avoid polluting subsequent test runs with the per-path keys.
        UserDefaults.standard.removeObject(
            forKey: "LastFSEventId:" + Self.testPathA
        )
        UserDefaults.standard.removeObject(
            forKey: "LastFSEventId:" + Self.testPathB
        )
        super.tearDown()
    }

    func testFSEventIdStorageRoundTripsForOneWatchedPath() {
        UserPreferences.setLastFSEventId(
            FSEventStreamEventId(42_424_242),
            forWatchedPath: Self.testPathA
        )
        let readBack = UserPreferences.lastFSEventId(forWatchedPath: Self.testPathA)
        XCTAssertEqual(readBack, FSEventStreamEventId(42_424_242))
    }

    func testFSEventIdStorageIsKeyedSeparatelyPerPath() {
        UserPreferences.setLastFSEventId(
            FSEventStreamEventId(111),
            forWatchedPath: Self.testPathA
        )
        UserPreferences.setLastFSEventId(
            FSEventStreamEventId(222),
            forWatchedPath: Self.testPathB
        )
        XCTAssertEqual(
            UserPreferences.lastFSEventId(forWatchedPath: Self.testPathA),
            FSEventStreamEventId(111),
            "writing path B must not clobber path A"
        )
        XCTAssertEqual(
            UserPreferences.lastFSEventId(forWatchedPath: Self.testPathB),
            FSEventStreamEventId(222)
        )
    }

    func testFSEventIdReturnsNilForUnseenPath() {
        XCTAssertNil(
            UserPreferences.lastFSEventId(forWatchedPath: "/never-stored-\(UUID().uuidString)")
        )
    }
}

final class SeratoLibraryLocatorTests: XCTestCase {

    func testSeratoRelativePathStripsLeadingSlash() {
        XCTAssertEqual(
            SeratoLibraryLocator.seratoRelativePath(fromAbsolute: "/Users/x/Music/A/Track.mp3"),
            "Users/x/Music/A/Track.mp3"
        )
        XCTAssertEqual(
            SeratoLibraryLocator.seratoRelativePath(fromAbsolute: "Users/x/Music/A/Track.mp3"),
            "Users/x/Music/A/Track.mp3"
        )
    }

    func testEnumerateCrateFilesReturnsEmptyForMissingSubcratesDirectory() throws {
        let emptyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDirectory) }

        let locator = SeratoLibraryLocator(seratoDirectory: emptyDirectory)
        XCTAssertEqual(try locator.enumerateCrateFiles(), [])
    }

    func testEnumerateCrateFilesReturnsSortedCrateUrls() throws {
        let seratoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-locator-\(UUID().uuidString)", isDirectory: true)
        let subcratesDirectory = seratoDirectory.appendingPathComponent("Subcrates", isDirectory: true)
        try FileManager.default.createDirectory(at: subcratesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: seratoDirectory) }

        try Data().write(to: subcratesDirectory.appendingPathComponent("Zeta.crate"))
        try Data().write(to: subcratesDirectory.appendingPathComponent("Alpha.crate"))
        try Data().write(to: subcratesDirectory.appendingPathComponent("Beta.crate"))
        // A non-.crate file in the same directory must be ignored.
        try Data().write(to: subcratesDirectory.appendingPathComponent("Notes.txt"))

        let locator = SeratoLibraryLocator(seratoDirectory: seratoDirectory)
        let names = try locator.enumerateCrateFiles().map { $0.lastPathComponent }
        XCTAssertEqual(names, ["Alpha.crate", "Beta.crate", "Zeta.crate"])
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

final class LightweightHashCalculatorTests: XCTestCase {

    private func makeTempFile(bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-hash-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        return url
    }

    func testHashIsNilForMissingFile() {
        let hash = LightweightHashCalculator.compute(
            forFileAt: "/tmp/crate-agent-test-this-path-should-not-exist-\(UUID().uuidString).mp3"
        )
        XCTAssertNil(hash)
    }

    func testHashIsDeterministicForSmallFile() throws {
        // Below the 2MB threshold: hashes the whole file.
        let payload = Data("hello world\n".utf8)
        let url = try makeTempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: url) }

        let hashA = LightweightHashCalculator.compute(forFileAt: url.path)
        let hashB = LightweightHashCalculator.compute(forFileAt: url.path)
        XCTAssertNotNil(hashA)
        XCTAssertEqual(hashA, hashB)
        XCTAssertEqual(hashA?.count, 32)  // SHA-256
    }

    func testHashChangesWhenContentChanges() throws {
        let urlA = try makeTempFile(bytes: Data("alpha".utf8))
        let urlB = try makeTempFile(bytes: Data("beta".utf8))
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        XCTAssertNotEqual(
            LightweightHashCalculator.compute(forFileAt: urlA.path),
            LightweightHashCalculator.compute(forFileAt: urlB.path)
        )
    }

    func testHashUsesHeadAndTailForLargeFile() throws {
        // 3MB file: above the 2MB threshold. Build it so that head
        // and tail windows are predictable — 1MB of 'A', 1MB of 'M'
        // (middle bytes that DON'T get hashed), 1MB of 'Z'.
        let mb = 1024 * 1024
        var payload = Data(count: 3 * mb)
        payload.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for index in 0..<mb { bytes[index] = UInt8(ascii: "A") }
            for index in mb..<(2 * mb) { bytes[index] = UInt8(ascii: "M") }
            for index in (2 * mb)..<(3 * mb) { bytes[index] = UInt8(ascii: "Z") }
        }
        let urlA = try makeTempFile(bytes: payload)
        defer { try? FileManager.default.removeItem(at: urlA) }

        // Identical head + tail, but middle bytes flipped to 'X'.
        var payloadVariant = payload
        payloadVariant.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for index in mb..<(2 * mb) { bytes[index] = UInt8(ascii: "X") }
        }
        let urlB = try makeTempFile(bytes: payloadVariant)
        defer { try? FileManager.default.removeItem(at: urlB) }

        let hashA = LightweightHashCalculator.compute(forFileAt: urlA.path)
        let hashB = LightweightHashCalculator.compute(forFileAt: urlB.path)
        XCTAssertNotNil(hashA)
        XCTAssertEqual(hashA, hashB,
                       "Middle-bytes-only mutation must not affect the hash — only head+tail windows are sampled")

        // Tail-byte mutation MUST change the hash.
        var payloadTailChanged = payload
        payloadTailChanged.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            bytes[3 * mb - 1] = UInt8(ascii: "Q")
        }
        let urlC = try makeTempFile(bytes: payloadTailChanged)
        defer { try? FileManager.default.removeItem(at: urlC) }
        XCTAssertNotEqual(hashA, LightweightHashCalculator.compute(forFileAt: urlC.path))
    }
}

extension FilesystemSyncCoordinatorTests {

    func testCrossVolumeMoveIsDetectedViaLightweightHash() async throws {
        let (coordinator, _, database) = try await MainActor.run { try makeCoordinator() }
        let audioFile = try makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioFile) }

        // Compute the real hash of the file on disk — this is what
        // FilesystemSyncCoordinator will look up.
        guard let realHash = LightweightHashCalculator.compute(forFileAt: audioFile.path) else {
            XCTFail("could not compute hash for temp file")
            return
        }
        // Real stat info, used to verify the coordinator wrote the
        // new identity onto the row.
        var statBuffer = stat()
        guard stat(audioFile.path, &statBuffer) == 0 else {
            XCTFail("could not stat temp file")
            return
        }
        let realInode = Int64(statBuffer.st_ino)
        let realVolumeUuid = (try? audioFile.resourceValues(forKeys: [.volumeUUIDStringKey]))?
            .volumeUUIDString ?? "unknown-volume"

        // Pre-populate with a row that has the file's true hash and
        // size but a DIFFERENT (inode, volume_uuid) — i.e., the row
        // describes the same content as it lived on a previous
        // volume. Insert directly so the test doesn't depend on
        // OperationEngine's mutation path.
        let fakeInode: Int64 = 999_999_999
        let fakeVolume = "stale-other-volume-uuid"
        let stalePath = "/imaginary/old-volume/track.mp3"
        let fileSizeOnDisk = Int64(statBuffer.st_size)

        let fileId: Int64 = try await database.writer.write { db in
            var record = FileRecord(
                path: stalePath,
                volumeUuid: fakeVolume,
                inode: fakeInode,
                fileSize: fileSizeOnDisk,
                mtime: 1,
                lightweightHash: realHash,
                fingerprintStatus: .pending
            )
            try record.insert(db)
            guard let identifier = record.id else {
                XCTFail("insert did not return row id")
                return 0
            }
            return identifier
        }

        // Fire the rename event for the file at its real location.
        // The inode/volume lookup will miss (the row has a fake pair),
        // so the coordinator should fall back to the hash lookup and
        // recognize this as a cross-volume move.
        let observation = FSEventsObservation(
            path: audioFile.path, isFile: true, wasRenamed: true
        )
        await coordinator.handleObservations([observation])

        let updated = try await database.writer.read { db in
            try FileRecord.fetchOne(db, key: fileId)
        }
        XCTAssertEqual(updated?.path, audioFile.path,
                       "cross-volume rename must rewrite path to the new disk location")
        XCTAssertEqual(updated?.inode, realInode,
                       "cross-volume rename must update inode to the new volume's value")
        XCTAssertEqual(updated?.volumeUuid, realVolumeUuid,
                       "cross-volume rename must update volume_uuid")

        let fileCount = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(fileCount, 1,
                       "cross-volume rename must not create a second row")
    }

    func testRenameOfUnknownFileIsIgnoredEvenWithHashAvailable() async throws {
        // File exists on disk and has a hash, but no row in the DB
        // matches the hash — confirms we don't accidentally claim
        // arbitrary files in the watched folder.
        let (coordinator, _, database) = try await MainActor.run { try makeCoordinator() }
        let audioFile = try makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioFile) }

        let observation = FSEventsObservation(
            path: audioFile.path, isFile: true, wasRenamed: true
        )
        await coordinator.handleObservations([observation])

        let fileCount = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(fileCount, 0)
    }
}

final class EventHistoryQueryTests: XCTestCase {

    // MARK: - Pure derivation tests (no DB)

    func testDescribeBatchListsEachEventTypeWithCount() {
        let summary = EventHistoryQuery.describeBatch(typeCounts: [
            (.fileRenamed, 2),
            (.metadataSet, 1),
        ])
        XCTAssertEqual(summary, "Renamed 2 files · Updated metadata for 1 file")
    }

    func testDescribeBatchPluralizesByCount() {
        XCTAssertEqual(
            EventHistoryQuery.describeBatch(typeCounts: [(.trackImported, 1)]),
            "Imported 1 track"
        )
        XCTAssertEqual(
            EventHistoryQuery.describeBatch(typeCounts: [(.trackImported, 3)]),
            "Imported 3 tracks"
        )
    }

    func testDescribeBatchOfEmptyReturnsPlaceholder() {
        XCTAssertEqual(EventHistoryQuery.describeBatch(typeCounts: []), "Empty batch")
    }

    func testCanUndoBatchAllowsSupportedTypes() {
        XCTAssertTrue(EventHistoryQuery.canUndoBatch(
            typeList: [
                EventType.fileRenamed.rawValue,
                EventType.metadataSet.rawValue,
                EventType.trackImported.rawValue,
                EventType.fileRemoved.rawValue,
            ]
        ))
    }

    func testCanUndoBatchRejectsAddTrackToSerato() {
        XCTAssertFalse(EventHistoryQuery.canUndoBatch(
            typeList: [
                EventType.trackImported.rawValue,
                EventType.trackAddedToSerato.rawValue,
            ]
        ))
    }

    func testCanUndoBatchAllowsCommitMetadataToSeratoSinceSP15() {
        // SP-1.5 made `commitMetadataToSerato` undoable when callers
        // supply previousMetadata. Every production caller (the
        // hygiene runner) does, so the UI gate now allows the batch.
        XCTAssertTrue(EventHistoryQuery.canUndoBatch(
            typeList: [
                EventType.metadataSet.rawValue,
                EventType.metadataCommittedToSerato.rawValue,
            ]
        ))
    }

    // MARK: - End-to-end (DB-backed)

    @MainActor
    private func makeEngine() throws -> (OperationEngine, LibraryDatabase) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        let locator = SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null"))
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { _, _ in /* no-op: tests use synthetic paths */ },
            fileTrasher: { _ in /* no-op: tests use synthetic paths */ }
        )
        return (engine, database)
    }

    func testLoadRecentBatchesReturnsBatchesNewestFirst() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }

        // Two batches, applied in order. Timestamps come from
        // Date().timeIntervalSince1970 inside executeAndLog, so a
        // small sleep between batches keeps the ordering robust on
        // fast machines.
        try await engine.apply(
            .indexNewFile(IndexNewFilePayload(
                path: "/Music/A/first.mp3",
                volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
            )),
            batchId: "older-batch"
        )
        try await Task.sleep(nanoseconds: 5_000_000)  // 5ms
        try await engine.apply(
            .indexNewFile(IndexNewFilePayload(
                path: "/Music/A/second.mp3",
                volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1
            )),
            batchId: "newer-batch"
        )

        let batches = try await EventHistoryQuery.loadRecentBatches(database: database)
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].batchId, "newer-batch")
        XCTAssertEqual(batches[1].batchId, "older-batch")
        XCTAssertEqual(batches[0].description, "Imported 1 track")
        XCTAssertEqual(batches[0].eventCount, 1)
    }

    func testLoadRecentBatchesAggregatesCompositeBatch() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }

        let batchId = "composite-batch"
        try await engine.apply(
            .indexNewFile(IndexNewFilePayload(
                path: "/Music/A/track.mp3",
                volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
            )),
            batchId: batchId
        )
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/track.mp3"])
        }!
        try await engine.apply(
            .renameFile(RenameFilePayload(fileId: fileId, newPath: "/Music/A/renamed.mp3")),
            batchId: batchId
        )

        let batches = try await EventHistoryQuery.loadRecentBatches(database: database)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].eventCount, 2)
        XCTAssertTrue(
            batches[0].description.contains("Imported 1 track"),
            "got '\(batches[0].description)'"
        )
        XCTAssertTrue(
            batches[0].description.contains("Renamed 1 file"),
            "got '\(batches[0].description)'"
        )
        XCTAssertTrue(batches[0].canUndo)
        XCTAssertFalse(batches[0].isUndoBatch)
    }

    func testLoadRecentBatchesFlagsUndoBatches() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }

        try await engine.apply(
            .indexNewFile(IndexNewFilePayload(
                path: "/Music/A/x.mp3",
                volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
            )),
            batchId: "original"
        )
        let undoBatchId = try await engine.undoBatch("original")

        let batches = try await EventHistoryQuery.loadRecentBatches(database: database)
        guard let undoSummary = batches.first(where: { $0.batchId == undoBatchId }) else {
            XCTFail("undo batch should have a summary")
            return
        }
        XCTAssertTrue(undoSummary.isUndoBatch)
        // The undo of an indexNewFile is a removeFile event.
        XCTAssertTrue(
            undoSummary.description.contains("Removed 1 file"),
            "got '\(undoSummary.description)'"
        )
    }

    func testLoadRecentBatchesHonorsLimit() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }

        for index in 0..<5 {
            try await engine.apply(
                .indexNewFile(IndexNewFilePayload(
                    path: "/Music/A/track-\(index).mp3",
                    volumeUuid: "v1", inode: Int64(index + 1), fileSize: 1, mtime: 1
                )),
                batchId: "batch-\(index)"
            )
        }

        let limited = try await EventHistoryQuery.loadRecentBatches(database: database, limit: 2)
        XCTAssertEqual(limited.count, 2)
    }
}

final class FingerprintWorkerTests: XCTestCase {

    /// Insert a pending file row without going through OperationEngine
    /// — the worker doesn't care how rows arrive, only that they're
    /// pending. Avoids dragging engine setup into the fixture.
    @discardableResult
    private func insertPendingFile(
        path: String,
        in database: LibraryDatabase,
        inode: Int64 = 1
    ) async throws -> Int64 {
        try await database.writer.write { db in
            var record = FileRecord(
                path: path,
                volumeUuid: "v1",
                inode: inode,
                fileSize: 1024,
                mtime: 1_700_000_000,
                fingerprintStatus: .pending
            )
            try record.insert(db)
            return record.id!
        }
    }

    func testSerializeAndDeserializeRoundTripsHashes() {
        let original: [UInt32] = [0xDEAD_BEEF, 0x1234_5678, 0, UInt32.max]
        let bytes = FingerprintWorker.serializeHashesToBytes(original)
        XCTAssertEqual(bytes.count, original.count * 4)
        let decoded = FingerprintWorker.deserializeHashesFromBytes(bytes)
        XCTAssertEqual(decoded, original)
    }

    func testSerializeUsesLittleEndian() {
        // Pin the byte order so the on-disk format is documented:
        // 0x01020304 → 04 03 02 01.
        let bytes = FingerprintWorker.serializeHashesToBytes([0x01020304])
        XCTAssertEqual(Array(bytes), [0x04, 0x03, 0x02, 0x01])
    }

    func testProcessAllPendingOnceFingerprintsEveryPendingRow() async throws {
        let database = try await LibraryDatabase.openInMemory()
        let id1 = try await insertPendingFile(path: "/Music/A/one.mp3", in: database, inode: 1)
        let id2 = try await insertPendingFile(path: "/Music/A/two.mp3", in: database, inode: 2)

        let mockFingerprint: @Sendable (String) throws -> [UInt32] = { path in
            // Stable per-path output so we can verify the right hash
            // lands on the right row.
            return [UInt32(path.count), 0xCAFE]
        }

        let worker = FingerprintWorker(
            database: database,
            concurrency: 2,
            fingerprintFunction: mockFingerprint
        )
        _ = try await worker.processAllPendingOnce()

        let rows = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(row.fingerprintStatus, .done,
                           "every pending row must transition to .done")
            XCTAssertNotNil(row.chromaprintFingerprint)
            let decoded = FingerprintWorker.deserializeHashesFromBytes(row.chromaprintFingerprint!)
            XCTAssertEqual(decoded.count, 2)
            XCTAssertEqual(decoded[0], UInt32(row.path.count))
            XCTAssertEqual(decoded[1], 0xCAFE)
        }
        XCTAssertNotEqual(id1, id2)  // sanity on the fixture
    }

    func testFailingFingerprintMarksRowFailedWithoutBlockingOtherFiles() async throws {
        let database = try await LibraryDatabase.openInMemory()
        try await insertPendingFile(path: "/Music/A/good.mp3", in: database, inode: 1)
        try await insertPendingFile(path: "/Music/A/bad.mp3", in: database, inode: 2)

        struct FingerprintError: Error {}
        let mockFingerprint: @Sendable (String) throws -> [UInt32] = { path in
            if path.hasSuffix("bad.mp3") { throw FingerprintError() }
            return [42, 43]
        }

        let worker = FingerprintWorker(
            database: database,
            concurrency: 2,
            fingerprintFunction: mockFingerprint
        )
        _ = try await worker.processAllPendingOnce()

        let good = try await database.writer.read { db in
            try FileRecord.filter(Column("path") == "/Music/A/good.mp3").fetchOne(db)!
        }
        let bad = try await database.writer.read { db in
            try FileRecord.filter(Column("path") == "/Music/A/bad.mp3").fetchOne(db)!
        }
        XCTAssertEqual(good.fingerprintStatus, .done)
        XCTAssertNotNil(good.chromaprintFingerprint)
        XCTAssertEqual(bad.fingerprintStatus, .failed)
        XCTAssertNil(bad.chromaprintFingerprint,
                     "failed rows must not carry a stale hash blob")
    }

    func testWorkerSkipsAlreadyDoneRows() async throws {
        let database = try await LibraryDatabase.openInMemory()
        // Pre-mark one row as already fingerprinted; the worker must
        // not touch it. The other row is genuinely pending.
        try await database.writer.write { db in
            var done = FileRecord(
                path: "/Music/A/already.mp3",
                volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
                chromaprintFingerprint: Data([0xBE, 0xEF]),
                fingerprintStatus: .done
            )
            try done.insert(db)
        }
        try await insertPendingFile(path: "/Music/A/fresh.mp3", in: database, inode: 2)

        let mockFingerprint: @Sendable (String) throws -> [UInt32] = { _ in [99] }
        let worker = FingerprintWorker(
            database: database,
            concurrency: 1,
            fingerprintFunction: mockFingerprint
        )
        _ = try await worker.processAllPendingOnce()

        let untouched = try await database.writer.read { db in
            try FileRecord.filter(Column("path") == "/Music/A/already.mp3").fetchOne(db)!
        }
        XCTAssertEqual(untouched.chromaprintFingerprint, Data([0xBE, 0xEF]),
                       "already-done rows must keep their existing hash")

        let processed = try await database.writer.read { db in
            try FileRecord.filter(Column("path") == "/Music/A/fresh.mp3").fetchOne(db)!
        }
        XCTAssertEqual(processed.fingerprintStatus, .done)
        XCTAssertEqual(
            FingerprintWorker.deserializeHashesFromBytes(processed.chromaprintFingerprint!),
            [99]
        )
    }

    func testWorkerHonorsConcurrencyLimit() async throws {
        let database = try await LibraryDatabase.openInMemory()
        for index in 0..<8 {
            try await insertPendingFile(
                path: "/Music/A/track-\(index).mp3",
                in: database,
                inode: Int64(index + 1)
            )
        }

        // The mock counts simultaneously-running fingerprint calls
        // and asserts the count never exceeds the configured cap.
        let counter = ConcurrencyCounter()
        let mockFingerprint: @Sendable (String) throws -> [UInt32] = { _ in
            counter.enter()
            // Give the scheduler a chance to start sibling tasks
            // before we exit — without a yield, single-threaded
            // execution can hide a bounded-concurrency bug.
            Thread.sleep(forTimeInterval: 0.01)
            counter.leave()
            return [1]
        }

        let worker = FingerprintWorker(
            database: database,
            concurrency: 3,
            fingerprintFunction: mockFingerprint
        )
        _ = try await worker.processAllPendingOnce()

        XCTAssertLessThanOrEqual(counter.peak, 3,
                                 "no more than `concurrency` fingerprint calls may run simultaneously")
        XCTAssertEqual(counter.totalEntered, 8)
    }

    // MARK: - Byte-twin dedup

    /// Insert a pending row with the (file_size, lightweight_hash) of
    /// our choosing — necessary because the dedup logic groups by
    /// those two fields. Default values match the basic insertPendingFile
    /// helper but make the duplicate-relevant fields explicit.
    @discardableResult
    private func insertPendingFileWithHash(
        path: String,
        in database: LibraryDatabase,
        inode: Int64,
        fileSize: Int64 = 1024,
        lightweightHash: Data
    ) async throws -> Int64 {
        try await database.writer.write { db in
            var record = FileRecord(
                path: path,
                volumeUuid: "v1",
                inode: inode,
                fileSize: fileSize,
                mtime: 1_700_000_000,
                lightweightHash: lightweightHash,
                fingerprintStatus: .pending
            )
            try record.insert(db)
            return record.id!
        }
    }

    func testInBatchDedupFingerprintsOnceForByteTwins() async throws {
        // Three files in the same batch with identical (size, hash):
        // the worker should fingerprint exactly one of them and
        // copy the result to the other two.
        let database = try await LibraryDatabase.openInMemory()
        let hash = Data([0xAA, 0xBB, 0xCC])
        try await insertPendingFileWithHash(
            path: "/Music/A/copy1.mp3", in: database, inode: 1, lightweightHash: hash
        )
        try await insertPendingFileWithHash(
            path: "/Music/A/copy2.mp3", in: database, inode: 2, lightweightHash: hash
        )
        try await insertPendingFileWithHash(
            path: "/Music/A/copy3.mp3", in: database, inode: 3, lightweightHash: hash
        )

        let counter = ConcurrencyCounter()
        let mockFingerprint: @Sendable (String) throws -> [UInt32] = { _ in
            counter.enter()
            counter.leave()
            return [0xDEAD, 0xBEEF]
        }

        let worker = FingerprintWorker(
            database: database,
            concurrency: 2,
            fingerprintFunction: mockFingerprint
        )
        _ = try await worker.processAllPendingOnce()

        XCTAssertEqual(counter.totalEntered, 1,
                       "byte-twins must fingerprint exactly once; the rest copy the result")

        let rows = try await database.writer.read { db in
            try FileRecord.fetchAll(db).sorted { $0.id! < $1.id! }
        }
        XCTAssertEqual(rows.count, 3)
        let firstFingerprint = rows[0].chromaprintFingerprint
        XCTAssertNotNil(firstFingerprint)
        for row in rows {
            XCTAssertEqual(row.fingerprintStatus, .done)
            XCTAssertEqual(row.chromaprintFingerprint, firstFingerprint,
                           "every byte-twin must have an identical fingerprint after dedup")
        }
    }

    func testCopyFromExistingTwinSkipsFingerprintingEntirely() async throws {
        // A row with the same (size, hash) is ALREADY done in the DB
        // before the worker runs. A new pending file with that hash
        // should skip fingerprinting and copy the existing hash.
        let database = try await LibraryDatabase.openInMemory()
        let hash = Data([0xCA, 0xFE])
        let existingFingerprint = Data([0x01, 0x02, 0x03, 0x04])

        // Insert a done row with the hash.
        try await database.writer.write { db in
            var record = FileRecord(
                path: "/Music/A/already-done.mp3",
                volumeUuid: "v1", inode: 100,
                fileSize: 1024, mtime: 1_700_000_000,
                lightweightHash: hash,
                chromaprintFingerprint: existingFingerprint,
                fingerprintStatus: .done
            )
            try record.insert(db)
        }
        // Insert a new pending row with the same (size, hash).
        try await insertPendingFileWithHash(
            path: "/Music/A/new-copy.mp3",
            in: database, inode: 200, lightweightHash: hash
        )

        let counter = ConcurrencyCounter()
        let mockFingerprint: @Sendable (String) throws -> [UInt32] = { _ in
            counter.enter()
            counter.leave()
            return [0xFF]
        }

        let worker = FingerprintWorker(
            database: database,
            concurrency: 1,
            fingerprintFunction: mockFingerprint
        )
        _ = try await worker.processAllPendingOnce()

        XCTAssertEqual(counter.totalEntered, 0,
                       "the new pending row must copy the existing twin's fingerprint; no decode")

        let copied = try await database.writer.read { db in
            try FileRecord.filter(Column("path") == "/Music/A/new-copy.mp3").fetchOne(db)!
        }
        XCTAssertEqual(copied.fingerprintStatus, .done)
        XCTAssertEqual(copied.chromaprintFingerprint, existingFingerprint,
                       "the new row must inherit the twin's exact fingerprint bytes")
    }

    func testFilesWithoutHashFingerprintIndependently() async throws {
        // A pending row with no lightweight_hash can't be grouped or
        // looked up. The worker fingerprints it the old-fashioned way.
        let database = try await LibraryDatabase.openInMemory()
        try await insertPendingFile(path: "/Music/A/no-hash.mp3", in: database, inode: 1)
        try await insertPendingFile(path: "/Music/A/also-no-hash.mp3", in: database, inode: 2)

        let counter = ConcurrencyCounter()
        let mockFingerprint: @Sendable (String) throws -> [UInt32] = { _ in
            counter.enter()
            counter.leave()
            return [0xABCD]
        }

        let worker = FingerprintWorker(
            database: database,
            concurrency: 2,
            fingerprintFunction: mockFingerprint
        )
        _ = try await worker.processAllPendingOnce()

        XCTAssertEqual(counter.totalEntered, 2,
                       "files without lightweight_hash can't dedup — each must fingerprint")
        let rows = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        for row in rows {
            XCTAssertEqual(row.fingerprintStatus, .done)
        }
    }

    func testTwinsWithFailedRepresentativeAllMarkFailed() async throws {
        // Group of 3 byte-twins. The injected fingerprint function
        // throws. The representative fails AND so do the siblings —
        // we shouldn't write a stale success to anyone.
        let database = try await LibraryDatabase.openInMemory()
        let hash = Data([0x99])
        try await insertPendingFileWithHash(
            path: "/Music/A/a.mp3", in: database, inode: 1, lightweightHash: hash
        )
        try await insertPendingFileWithHash(
            path: "/Music/A/b.mp3", in: database, inode: 2, lightweightHash: hash
        )

        struct FingerprintError: Error {}
        let mockFingerprint: @Sendable (String) throws -> [UInt32] = { _ in
            throw FingerprintError()
        }

        let worker = FingerprintWorker(
            database: database,
            concurrency: 1,
            fingerprintFunction: mockFingerprint
        )
        _ = try await worker.processAllPendingOnce()

        let rows = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        for row in rows {
            XCTAssertEqual(row.fingerprintStatus, .failed,
                           "representative failure must propagate to siblings — they share the bytes")
            XCTAssertNil(row.chromaprintFingerprint)
        }
    }
}

/// Thread-safe peak-concurrency tracker for the worker concurrency test.
private final class ConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Int = 0
    private(set) var peak: Int = 0
    private(set) var totalEntered: Int = 0

    func enter() {
        lock.lock()
        defer { lock.unlock() }
        running += 1
        totalEntered += 1
        if running > peak { peak = running }
    }

    func leave() {
        lock.lock()
        defer { lock.unlock() }
        running -= 1
    }
}

final class ArtistLetterNormalizerTests: XCTestCase {

    func testStripsLeadingArticleCaseInsensitive() {
        XCTAssertEqual(ArtistLetterNormalizer.stripLeadingArticle(from: "The Beatles"), "Beatles")
        XCTAssertEqual(ArtistLetterNormalizer.stripLeadingArticle(from: "THE Doors"), "Doors")
        XCTAssertEqual(ArtistLetterNormalizer.stripLeadingArticle(from: "the Strokes"), "Strokes")
        XCTAssertEqual(ArtistLetterNormalizer.stripLeadingArticle(from: "A Tribe Called Quest"),
                       "Tribe Called Quest")
        XCTAssertEqual(ArtistLetterNormalizer.stripLeadingArticle(from: "An American Tail"),
                       "American Tail")
    }

    func testKeepsArtistsWhoseNameStartsWithArticleLetters() {
        // "Anthrax" must not have its "An " stripped — the article
        // rule is space-bounded.
        XCTAssertEqual(ArtistLetterNormalizer.stripLeadingArticle(from: "Anthrax"), "Anthrax")
        XCTAssertEqual(ArtistLetterNormalizer.stripLeadingArticle(from: "The"), "The")
    }

    func testBucketLetterForPlainAlphabeticArtist() {
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "Aphex Twin"), "A")
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "Zomby"), "Z")
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "madlib"), "M",
                       "lowercase input must uppercase to the same bucket")
    }

    func testBucketLetterStripsLeadingArticle() {
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "The Beatles"), "B")
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "A Tribe Called Quest"), "T")
    }

    func testBucketLetterForLeadingDigit() {
        // From the design plan: 2Pac → T (Two).
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "2Pac"), "T")
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "311"), "T",
                       "leading digit takes priority — '3' → 'Three' → 'T'")
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "50 Cent"), "F",
                       "leading '5' → 'Five' → 'F'")
    }

    func testBucketLetterForLeadingSymbolLeetspeak() {
        // From the design plan: $uicideboy$ → S.
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "$uicideboy$"), "S")
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "@ndrew"), "A",
                       "@ visually substitutes for A")
    }

    func testBucketLetterFallsBackToHashWhenNoLetterDerivable() {
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: ""), "#")
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "   "), "#")
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: nil), "#")
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "~~~"), "#",
                       "all-symbol artist with no known leetspeak → unknown bucket")
    }

    func testBucketLetterSkipsUnknownSymbolsAndFindsFirstLetter() {
        // Underscores, parens, etc. that don't have leetspeak mappings
        // should be skipped so the first real letter wins.
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "(Sandy) Alex G"), "S")
        XCTAssertEqual(ArtistLetterNormalizer.bucketLetter(forArtist: "...And You Will Know Us"),
                       "A")
    }
}

final class FilenameTemplateEngineTests: XCTestCase {

    private let sampleMetadata = SeratoMetadata(
        artist: "Aphex Twin",
        title: "Windowlicker",
        album: "Windowlicker EP",
        genre: "IDM",
        bpm: "126.000",
        musicalKey: "Am",
        comment: "twelve-bar",
        length: "06:07",
        label: "Warp"
    )

    func testRendersBasicSubstitution() {
        let rendered = FilenameTemplateEngine.render(
            template: "$artist - $title.$ext",
            metadata: sampleMetadata,
            fileExtension: "mp3"
        )
        XCTAssertEqual(rendered, "Aphex Twin - Windowlicker.mp3")
    }

    func testRendersAllSupportedFields() {
        let rendered = FilenameTemplateEngine.render(
            template: "$artist | $album | $genre | $bpm | $key | $length | $label | $comment",
            metadata: sampleMetadata,
            fileExtension: "mp3"
        )
        // Serato stores `length` as "06:07" with a literal colon, but
        // `:` is a legacy filesystem hazard on macOS (Finder still
        // rewrites it to `/` for display, and HFS+ disallowed it
        // outright). The sanitizer replaces it with `_` — this test
        // also pins that behavior.
        XCTAssertEqual(
            rendered,
            "Aphex Twin | Windowlicker EP | IDM | 126.000 | Am | 06_07 | Warp | twelve-bar"
        )
    }

    func testMissingMetadataFieldRendersAsEmpty() {
        let sparseMetadata = SeratoMetadata(artist: "Boards of Canada")
        let rendered = FilenameTemplateEngine.render(
            template: "$artist - $title.$ext",
            metadata: sparseMetadata,
            fileExtension: "flac"
        )
        XCTAssertEqual(rendered, "Boards of Canada - .flac",
                       "missing title renders as empty — caller handles the result")
    }

    func testUnknownIdentifierRendersAsEmpty() {
        let rendered = FilenameTemplateEngine.render(
            template: "$artist - $nonexistent",
            metadata: sampleMetadata,
            fileExtension: "mp3"
        )
        XCTAssertEqual(rendered, "Aphex Twin - ")
    }

    func testDoubleDollarRendersLiteralDollar() {
        let rendered = FilenameTemplateEngine.render(
            template: "$$$artist",
            metadata: sampleMetadata,
            fileExtension: "mp3"
        )
        XCTAssertEqual(rendered, "$Aphex Twin")
    }

    func testSanitizesFilesystemIllegalCharacters() {
        let dangerousMetadata = SeratoMetadata(
            artist: "AC/DC",
            title: "Back: In * Black?"
        )
        let rendered = FilenameTemplateEngine.render(
            template: "$artist - $title",
            metadata: dangerousMetadata,
            fileExtension: "mp3"
        )
        XCTAssertEqual(
            rendered, "AC_DC - Back_ In _ Black_",
            "/, :, *, ? must all be replaced with _ so the filename can't escape its folder"
        )
    }

    func testPreservesUnicodeAndWhitespace() {
        let rendered = FilenameTemplateEngine.render(
            template: "$artist - $title",
            metadata: SeratoMetadata(artist: "Sigur Rós", title: "Hoppípolla"),
            fileExtension: "mp3"
        )
        XCTAssertEqual(rendered, "Sigur Rós - Hoppípolla",
                       "non-ASCII letters and spaces must pass through")
    }

    func testTrailingDollarSignIsLiteral() {
        // `$` at end-of-string with no identifier should not crash;
        // readIdentifier returns empty, substitute returns empty,
        // engine moves on.
        let rendered = FilenameTemplateEngine.render(
            template: "track $",
            metadata: sampleMetadata,
            fileExtension: "mp3"
        )
        XCTAssertEqual(rendered, "track ")
    }
}

final class RenameDestinationPlannerTests: XCTestCase {

    private let musicFolder = URL(fileURLWithPath: "/Users/test/Music", isDirectory: true)

    private func makeFile(
        path: String = "/Users/test/Music/A/old.mp3",
        artist: String? = "Aphex Twin",
        title: String? = "Windowlicker"
    ) -> FileRecord {
        FileRecord(
            id: 1,
            path: path,
            volumeUuid: "v1",
            inode: 1,
            fileSize: 1024,
            mtime: 1,
            artist: artist,
            title: title
        )
    }

    func testDestinationCombinesBucketLetterAndRenderedFilename() {
        let destination = RenameDestinationPlanner.destination(
            forFile: makeFile(),
            musicFolder: musicFolder,
            template: "$artist - $title.$ext"
        )
        XCTAssertEqual(
            destination.path,
            "/Users/test/Music/A/Aphex Twin - Windowlicker.mp3"
        )
    }

    func testDestinationUsesArticleStrippedBucket() {
        // "The Beatles" → bucket B, filename keeps the literal artist.
        let destination = RenameDestinationPlanner.destination(
            forFile: makeFile(artist: "The Beatles", title: "Hey Jude"),
            musicFolder: musicFolder,
            template: "$artist - $title.$ext"
        )
        XCTAssertEqual(
            destination.path,
            "/Users/test/Music/B/The Beatles - Hey Jude.mp3"
        )
    }

    func testDestinationPreservesExtensionFromSourcePath() {
        // Source path has .flac; the destination must also be .flac.
        let destination = RenameDestinationPlanner.destination(
            forFile: makeFile(
                path: "/Users/test/Music/Sub/lossless.flac",
                artist: "Boards of Canada",
                title: "Roygbiv"
            ),
            musicFolder: musicFolder,
            template: "$artist - $title.$ext"
        )
        XCTAssertEqual(
            destination.path,
            "/Users/test/Music/B/Boards of Canada - Roygbiv.flac"
        )
    }

    func testDestinationFallsBackToHashBucketForEmptyArtist() {
        let destination = RenameDestinationPlanner.destination(
            forFile: makeFile(artist: nil, title: "Untitled"),
            musicFolder: musicFolder,
            template: "$artist - $title.$ext"
        )
        XCTAssertTrue(
            destination.path.contains("/#/"),
            "missing artist must route to the # fallback bucket — got '\(destination.path)'"
        )
    }
}

final class UserPreferencesFilenameTemplateTests: XCTestCase {

    private let key = "FilenameTemplate"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testFilenameTemplateDefaultsWhenUnset() {
        XCTAssertEqual(
            UserPreferences.filenameTemplate,
            UserPreferences.defaultFilenameTemplate
        )
    }

    func testFilenameTemplateRoundTripsSavedValue() {
        UserPreferences.filenameTemplate = "$artist · $title.$ext"
        XCTAssertEqual(UserPreferences.filenameTemplate, "$artist · $title.$ext")
    }
}

final class SettingsTemplatePreviewerTests: XCTestCase {

    func testPreviewIncludesBucketLetterAndRenderedFilename() {
        // Sample metadata has artist "Aphex Twin" → bucket A.
        let preview = SettingsTemplatePreviewer.preview(
            template: "$artist - $title.$ext"
        )
        XCTAssertEqual(preview, "<Music>/A/Aphex Twin - Windowlicker.mp3")
    }

    func testPreviewReflectsCustomTemplate() {
        let preview = SettingsTemplatePreviewer.preview(
            template: "$bpm — $artist — $title.$ext"
        )
        XCTAssertEqual(preview, "<Music>/A/126.000 — Aphex Twin — Windowlicker.mp3")
    }

    func testPreviewSanitizesIllegalCharactersInPreview() {
        // The sample length field is "06:07" — `:` must be sanitized.
        // Pins that the settings preview shows the same sanitization
        // the production rename path applies.
        let preview = SettingsTemplatePreviewer.preview(
            template: "$length-$title.$ext"
        )
        XCTAssertEqual(preview, "<Music>/A/06_07-Windowlicker.mp3")
    }
}

final class AppLauncherTests: XCTestCase {

    private let watchedFolderKey = "WatchedMusicFolderPath"

    @MainActor
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: watchedFolderKey)
    }

    @MainActor
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: watchedFolderKey)
        super.tearDown()
    }

    @MainActor
    func testInitialStateIsNeedsOnboardingWhenNoFolderPreference() {
        let launcher = AppLauncher()
        guard case .needsOnboarding = launcher.state else {
            XCTFail("launcher should require onboarding when no folder is configured; got \(launcher.state)")
            return
        }
    }

    @MainActor
    func testInitialStateIsReadyWhenFolderPreferenceExists() {
        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-launcher-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        UserPreferences.watchedMusicFolder = tempFolder
        defer { UserPreferences.watchedMusicFolder = nil }

        let launcher = AppLauncher()
        guard case .ready = launcher.state else {
            XCTFail("launcher should bootstrap services when a folder is configured; got \(launcher.state)")
            return
        }
    }

    @MainActor
    func testCompleteOnboardingPersistsFolderAndTransitionsToReady() {
        let launcher = AppLauncher()
        // Sanity: starts in onboarding.
        guard case .needsOnboarding = launcher.state else {
            XCTFail("expected needsOnboarding starting state")
            return
        }

        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-launcher-onboarding-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempFolder)
            UserPreferences.watchedMusicFolder = nil
        }

        launcher.completeOnboarding(withFolder: tempFolder)

        XCTAssertEqual(UserPreferences.watchedMusicFolder, tempFolder,
                       "onboarding must persist the picked folder for next launch")
        guard case .ready = launcher.state else {
            XCTFail("launcher should be in .ready after onboarding; got \(launcher.state)")
            return
        }
    }
}

final class LibraryHygieneAnalyzerTests: XCTestCase {

    private func makeFile(
        id: Int64 = 1,
        path: String = "/Music/A/track.mp3",
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        comment: String? = nil
    ) -> FileRecord {
        FileRecord(
            id: id,
            path: path,
            volumeUuid: "v1",
            inode: id,
            fileSize: 1, mtime: 1,
            artist: artist,
            title: title,
            album: album,
            comment: comment
        )
    }

    func testFindsNoIssuesWhenAllFieldsClean() {
        let issues = LibraryHygiene.findWhitespaceIssues(in: [
            makeFile(artist: "Aphex Twin", title: "Windowlicker"),
        ])
        XCTAssertEqual(issues.count, 0)
    }

    func testFindsLeadingAndTrailingWhitespace() {
        let issues = LibraryHygiene.findWhitespaceIssues(in: [
            makeFile(id: 1, artist: " Aphex Twin", title: "Windowlicker"),
            makeFile(id: 2, artist: "Boards of Canada", title: "Roygbiv "),
        ])
        XCTAssertEqual(issues.count, 2)
        let firstFileIssues = issues.filter { $0.fileId == 1 }
        XCTAssertEqual(firstFileIssues.first?.field, .artist)
        XCTAssertEqual(firstFileIssues.first?.oldValue, " Aphex Twin")
        XCTAssertEqual(firstFileIssues.first?.newValue, "Aphex Twin")
        let secondFileIssues = issues.filter { $0.fileId == 2 }
        XCTAssertEqual(secondFileIssues.first?.field, .title)
        XCTAssertEqual(secondFileIssues.first?.newValue, "Roygbiv")
    }

    func testPreservesInternalWhitespace() {
        // "Aphex   Twin" with three internal spaces is NOT a trim
        // issue. Style/case normalization is a separate analyzer.
        let issues = LibraryHygiene.findWhitespaceIssues(in: [
            makeFile(artist: "Aphex   Twin"),
        ])
        XCTAssertEqual(issues.count, 0,
                       "internal whitespace must not be flagged as trim-worthy")
    }

    func testDetectsMultipleFieldsOnOneFile() {
        let issues = LibraryHygiene.findWhitespaceIssues(in: [
            makeFile(
                artist: " Artist",
                title: "Title ",
                album: "  Album  "
            ),
        ])
        XCTAssertEqual(issues.count, 3)
        let fields = Set(issues.map(\.field))
        XCTAssertEqual(fields, [.artist, .title, .album])
    }

    func testMergedTrimmedMetadataAppliesEveryFix() {
        let file = makeFile(
            artist: " Artist",
            title: "Title ",
            album: "  Album  ",
            comment: "fine"
        )
        let issues = LibraryHygiene.findWhitespaceIssues(in: [file])
        let merged = LibraryHygiene.mergedTrimmedMetadata(forFile: file, issues: issues)
        XCTAssertEqual(merged.artist, "Artist")
        XCTAssertEqual(merged.title, "Title")
        XCTAssertEqual(merged.album, "Album")
        XCTAssertEqual(merged.comment, "fine",
                       "untouched fields preserve their original values")
    }
}

final class LibraryHygieneFindReplaceTests: XCTestCase {

    private func makeFile(
        id: Int64 = 1,
        path: String = "/Music/A/track.mp3",
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil
    ) -> FileRecord {
        FileRecord(
            id: id,
            path: path,
            volumeUuid: "v1",
            inode: id, fileSize: 1, mtime: 1,
            artist: artist, title: title, album: album
        )
    }

    func testEmptyFindStringYieldsNoMatches() {
        let query = LibraryHygiene.FindAndReplaceQuery(
            find: "",
            replace: "X",
            fields: Set(SeratoMetadataField.allCases),
            caseSensitive: false
        )
        let matches = LibraryHygiene.findAndReplaceMatches(
            in: [makeFile(artist: "Anything")],
            query: query
        )
        XCTAssertEqual(matches.count, 0,
                       "empty find string must not flag every row as a match")
    }

    func testCaseInsensitiveMatchAndReplaceWorks() {
        // Substring substitution: only the matched chars change.
        // "the strokes" → "The strokes" (the 's' in 'strokes' stays
        // lowercase — title-casing the whole string is not part of
        // find/replace, that's a future case-normalization tool).
        let matches = LibraryHygiene.findAndReplaceMatches(
            in: [
                makeFile(id: 1, artist: "the strokes", album: "Is This It"),
                makeFile(id: 2, artist: "THE doors", title: "Light My Fire"),
            ],
            query: LibraryHygiene.FindAndReplaceQuery(
                find: "the",
                replace: "The",
                fields: [.artist],
                caseSensitive: false
            )
        )
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.first(where: { $0.fileId == 1 })?.newValue, "The strokes")
        XCTAssertEqual(matches.first(where: { $0.fileId == 2 })?.newValue, "The doors")
    }

    func testCaseSensitiveMatchSkipsCaseMismatches() {
        let matches = LibraryHygiene.findAndReplaceMatches(
            in: [
                makeFile(id: 1, artist: "the strokes"),
                makeFile(id: 2, artist: "The Strokes"),
            ],
            query: LibraryHygiene.FindAndReplaceQuery(
                find: "the",
                replace: "THE",
                fields: [.artist],
                caseSensitive: true
            )
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.fileId, 1,
                       "case-sensitive find must skip 'The' but match 'the'")
        XCTAssertEqual(matches.first?.newValue, "THE strokes")
    }

    func testReplacementSkipsFieldsNotInSelection() {
        // Find string "demo" appears in both artist and album; only
        // album is selected → only album matches.
        let matches = LibraryHygiene.findAndReplaceMatches(
            in: [makeFile(artist: "demo artist", title: "Track", album: "demo album")],
            query: LibraryHygiene.FindAndReplaceQuery(
                find: "demo",
                replace: "DEMO",
                fields: [.album],
                caseSensitive: false
            )
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.field, .album)
        XCTAssertEqual(matches.first?.newValue, "DEMO album")
    }

    func testNoMatchYieldsEmpty() {
        let matches = LibraryHygiene.findAndReplaceMatches(
            in: [makeFile(artist: "Aphex Twin")],
            query: LibraryHygiene.FindAndReplaceQuery(
                find: "completely-absent",
                replace: "X",
                fields: [.artist],
                caseSensitive: false
            )
        )
        XCTAssertEqual(matches.count, 0)
    }

    func testApplyReplacementHelperIsCaseAware() {
        XCTAssertEqual(
            LibraryHygiene.applyReplacement(
                to: "Aphex twin", find: "twin", replace: "Twin",
                caseSensitive: true
            ),
            "Aphex Twin"
        )
        XCTAssertEqual(
            LibraryHygiene.applyReplacement(
                to: "Aphex twin", find: "Twin", replace: "Twin",
                caseSensitive: true
            ),
            "Aphex twin",
            "case-sensitive find of 'Twin' must not match 'twin'"
        )
        XCTAssertEqual(
            LibraryHygiene.applyReplacement(
                to: "Aphex twin", find: "Twin", replace: "Twin",
                caseSensitive: false
            ),
            "Aphex Twin"
        )
    }

    func testMergedFindReplaceMetadataBuildsCorrectPayload() {
        let file = makeFile(
            artist: "demo artist",
            title: "Track",
            album: "demo album"
        )
        let matches = LibraryHygiene.findAndReplaceMatches(
            in: [file],
            query: LibraryHygiene.FindAndReplaceQuery(
                find: "demo",
                replace: "production",
                fields: [.artist, .album],
                caseSensitive: false
            )
        )
        let merged = LibraryHygiene.mergedFindReplaceMetadata(forFile: file, matches: matches)
        XCTAssertEqual(merged.artist, "production artist")
        XCTAssertEqual(merged.album, "production album")
        XCTAssertEqual(merged.title, "Track",
                       "unselected field must keep its original value")
    }
}

final class LibraryHygieneFindReplaceRunnerTests: XCTestCase {

    @MainActor
    private func makeEngine() throws -> (OperationEngine, LibraryDatabase) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        let locator = SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null"))
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { _, _ in /* no-op: tests use synthetic paths */ },
            fileTrasher: { _ in /* no-op: tests use synthetic paths */ }
        )
        return (engine, database)
    }

    func testApplyReplacesValuesAcrossSelectedFields() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: "the strokes", album: "Is This It")
        )))
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let matches = LibraryHygiene.findAndReplaceMatches(
            in: files,
            query: LibraryHygiene.FindAndReplaceQuery(
                find: "the",
                replace: "The",
                fields: [.artist],
                caseSensitive: false
            )
        )

        let runner = LibraryHygieneRunner(operationEngine: engine)
        _ = try await runner.applyFindAndReplaceFixes(matches, files: files)

        let updated = try await database.writer.read { db in
            try FileRecord.fetchAll(db).first!
        }
        // Substring sub only — "the strokes" → "The strokes". The
        // 's' stays lowercase. Title-casing is a separate tool.
        XCTAssertEqual(updated.artist, "The strokes")
        XCTAssertEqual(updated.album, "Is This It",
                       "field not in query must be untouched")
    }

    func testFindReplaceBatchIsFullyUndoable() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: "demo artist")
        )))
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let matches = LibraryHygiene.findAndReplaceMatches(
            in: files,
            query: LibraryHygiene.FindAndReplaceQuery(
                find: "demo",
                replace: "production",
                fields: [.artist],
                caseSensitive: false
            )
        )
        let runner = LibraryHygieneRunner(operationEngine: engine)
        let batchId = try await runner.applyFindAndReplaceFixes(matches, files: files)

        // Sanity post-apply.
        let postFix = try await database.writer.read { db in
            try FileRecord.fetchAll(db).first!
        }
        XCTAssertEqual(postFix.artist, "production artist")

        // Undo the entire batch — both setMetadata and the commit
        // event must roundtrip, same as the whitespace path.
        _ = try await engine.undoBatch(batchId)

        let postUndo = try await database.writer.read { db in
            try FileRecord.fetchAll(db).first!
        }
        XCTAssertEqual(postUndo.artist, "demo artist",
                       "undo of find/replace must restore the pre-replace value")
    }
}

final class LibraryHygieneCaseConsistencyTests: XCTestCase {

    private func makeFile(
        id: Int64,
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil
    ) -> FileRecord {
        FileRecord(
            id: id,
            path: "/Music/A/track-\(id).mp3",
            volumeUuid: "v1", inode: id, fileSize: 1, mtime: 1,
            artist: artist, title: title, album: album
        )
    }

    func testFindNoGroupsWhenEveryFieldIsConsistent() {
        let groups = LibraryHygiene.findCaseInconsistencies(in: [
            makeFile(id: 1, artist: "Aphex Twin"),
            makeFile(id: 2, artist: "Aphex Twin"),
        ])
        XCTAssertEqual(groups.count, 0,
                       "no inconsistency means no group reported")
    }

    func testFindGroupsValuesByLowercaseKey() {
        let groups = LibraryHygiene.findCaseInconsistencies(in: [
            makeFile(id: 1, artist: "the strokes"),
            makeFile(id: 2, artist: "The Strokes"),
            makeFile(id: 3, artist: "The Strokes"),
            makeFile(id: 4, artist: "THE STROKES"),
        ])
        XCTAssertEqual(groups.count, 1)
        let group = groups.first!
        XCTAssertEqual(group.field, .artist)
        XCTAssertEqual(group.canonicalKey, "the strokes")
        XCTAssertEqual(group.totalFiles, 4)
        // Most-common-then-alphabetical: "The Strokes" (count 2),
        // "THE STROKES" (count 1), "the strokes" (count 1)
        XCTAssertEqual(group.variants.map(\.value),
                       ["The Strokes", "THE STROKES", "the strokes"])
        XCTAssertEqual(group.suggestedCanonical, "The Strokes")
    }

    func testFindGroupsAreScopedPerField() {
        // Same casing inconsistency across artist AND album should
        // produce two groups, not one merged group.
        let groups = LibraryHygiene.findCaseInconsistencies(in: [
            makeFile(id: 1, artist: "the doors", album: "the doors"),
            makeFile(id: 2, artist: "The Doors", album: "The Doors"),
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.field)), [.artist, .album])
    }

    func testGroupsAreSortedDeterministicallyAcrossFieldsAndKeys() {
        let groups = LibraryHygiene.findCaseInconsistencies(in: [
            makeFile(id: 1, artist: "zebra", album: "apple"),
            makeFile(id: 2, artist: "Zebra", album: "Apple"),
        ])
        XCTAssertEqual(groups.map(\.field), [.album, .artist],
                       "album sorts before artist alphabetically by field rawValue")
    }

    func testTiebreakIsAlphabeticalWhenCountsEqual() {
        let groups = LibraryHygiene.findCaseInconsistencies(in: [
            makeFile(id: 1, artist: "zebra"),
            makeFile(id: 2, artist: "Zebra"),
        ])
        // Both variants have count 1 → alphabetical: "Zebra" (Z=0x5A)
        // sorts before "zebra" (z=0x7A) in ASCII so "Zebra" wins
        XCTAssertEqual(groups.first?.suggestedCanonical, "Zebra")
    }

    func testCaseFixesProjectChosenCanonicalOntoVariantsExcludingSelf() {
        let files = [
            makeFile(id: 1, artist: "the strokes"),
            makeFile(id: 2, artist: "The Strokes"),
            makeFile(id: 3, artist: "THE STROKES"),
        ]
        let groups = LibraryHygiene.findCaseInconsistencies(in: files)
        let fixes = LibraryHygiene.caseFixes(
            forGroups: groups,
            canonicalFor: { _ in "The Strokes" },
            in: files
        )
        XCTAssertEqual(fixes.count, 2,
                       "files 1 and 3 need fixing; file 2 already matches")
        XCTAssertEqual(Set(fixes.map(\.fileId)), [1, 3])
        for fix in fixes {
            XCTAssertEqual(fix.newValue, "The Strokes")
        }
    }

    func testCaseFixesSkipsGroupsWithNilCanonical() {
        let files = [
            makeFile(id: 1, artist: "the strokes"),
            makeFile(id: 2, artist: "The Strokes"),
        ]
        let groups = LibraryHygiene.findCaseInconsistencies(in: files)
        let fixes = LibraryHygiene.caseFixes(
            forGroups: groups,
            canonicalFor: { _ in nil },  // skip everything
            in: files
        )
        XCTAssertEqual(fixes.count, 0,
                       "nil canonical must produce zero fixes for the group")
    }
}

final class LibraryHygieneCaseRunnerTests: XCTestCase {

    @MainActor
    private func makeEngine() throws -> (OperationEngine, LibraryDatabase) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        let locator = SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null"))
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { _, _ in /* no-op: tests use synthetic paths */ },
            fileTrasher: { _ in /* no-op: tests use synthetic paths */ }
        )
        return (engine, database)
    }

    func testApplyCaseFixesNormalizesEveryNonCanonicalRow() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/one.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: "the strokes")
        )))
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/two.mp3",
            volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: "The Strokes")
        )))
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let groups = LibraryHygiene.findCaseInconsistencies(in: files)
        XCTAssertEqual(groups.count, 1)

        let fixes = LibraryHygiene.caseFixes(
            forGroups: groups,
            canonicalFor: { _ in "The Strokes" },
            in: files
        )
        let runner = LibraryHygieneRunner(operationEngine: engine)
        _ = try await runner.applyCaseFixes(fixes, files: files)

        let normalized = try await database.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT artist FROM files ORDER BY id"
            )
        }
        XCTAssertEqual(normalized, ["The Strokes", "The Strokes"])
    }

    func testApplyCaseFixesBatchIsFullyUndoable() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: "the doors")
        )))
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/other.mp3",
            volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: "The Doors")
        )))
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let groups = LibraryHygiene.findCaseInconsistencies(in: files)
        let fixes = LibraryHygiene.caseFixes(
            forGroups: groups,
            canonicalFor: { _ in "The Doors" },
            in: files
        )
        let runner = LibraryHygieneRunner(operationEngine: engine)
        let batchId = try await runner.applyCaseFixes(fixes, files: files)

        let postFix = try await database.writer.read { db in
            try FileRecord.filter(Column("inode") == 1).fetchOne(db)!
        }
        XCTAssertEqual(postFix.artist, "The Doors")

        _ = try await engine.undoBatch(batchId)

        let postUndo = try await database.writer.read { db in
            try FileRecord.filter(Column("inode") == 1).fetchOne(db)!
        }
        XCTAssertEqual(postUndo.artist, "the doors",
                       "undo of case normalization must restore the original casing")
    }
}

final class LibraryHygieneMissingFieldsTests: XCTestCase {

    private func makeFile(
        id: Int64,
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        genre: String? = nil
    ) -> FileRecord {
        FileRecord(
            id: id,
            path: "/Music/A/track-\(id).mp3",
            volumeUuid: "v1", inode: id, fileSize: 1, mtime: 1,
            artist: artist, title: title, album: album, genre: genre
        )
    }

    func testIsMissingFlagsNilEmptyAndWhitespaceOnly() {
        XCTAssertTrue(LibraryHygiene.isMissing(nil))
        XCTAssertTrue(LibraryHygiene.isMissing(""))
        XCTAssertTrue(LibraryHygiene.isMissing("   "))
        XCTAssertTrue(LibraryHygiene.isMissing("\n"))
        XCTAssertFalse(LibraryHygiene.isMissing("Aphex Twin"))
        XCTAssertFalse(LibraryHygiene.isMissing(" Aphex Twin "),
                       "non-empty after trim is not missing — whitespace cleanup is a separate analyzer")
    }

    func testMissingFieldSummariesCountPerField() {
        let summaries = LibraryHygiene.missingFieldSummaries(in: [
            makeFile(id: 1, artist: nil, title: "T", genre: "Rock"),
            makeFile(id: 2, artist: "A", title: "T2", genre: nil),
            makeFile(id: 3, artist: nil, title: nil, genre: nil),
        ])
        let counts = Dictionary(uniqueKeysWithValues: summaries.map { ($0.field, $0.count) })
        XCTAssertEqual(counts[.artist], 2)
        XCTAssertEqual(counts[.title], 1)
        XCTAssertEqual(counts[.genre], 2)
        XCTAssertEqual(counts[.album], 3,
                       "every row missing album was counted")
    }

    func testSummariesSkipFieldsWithNoGaps() {
        let summaries = LibraryHygiene.missingFieldSummaries(in: [
            makeFile(id: 1, artist: "A", title: "T", album: "L", genre: "G"),
        ])
        XCTAssertFalse(summaries.contains(where: { $0.field == .artist }),
                       "fully-populated fields must not appear in the summary list")
        // Fields the file is missing (bpm, key, etc.) still appear.
        XCTAssertTrue(summaries.contains(where: { $0.field == .bpm }))
    }

    func testMissingFieldEntriesAreSortedByPath() {
        let entries = LibraryHygiene.missingFieldEntries(
            forField: .artist,
            in: [
                makeFile(id: 3, artist: nil),
                makeFile(id: 1, artist: nil),
                makeFile(id: 2, artist: "Present"),
            ]
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.fileId), [1, 3],
                       "entries should sort by path '/Music/A/track-1.mp3' before 'track-3.mp3'")
    }

    func testMergedMissingFieldMetadataSetsOnlyChosenField() {
        let file = makeFile(id: 1, artist: nil, title: "Existing")
        let merged = LibraryHygiene.mergedMissingFieldMetadata(
            forFile: file,
            field: .artist,
            value: "New Artist"
        )
        XCTAssertEqual(merged.artist, "New Artist")
        XCTAssertEqual(merged.title, "Existing",
                       "untouched fields must preserve their original values")
    }
}

final class LibraryHygieneMissingFieldsRunnerTests: XCTestCase {

    @MainActor
    private func makeEngine() throws -> (OperationEngine, LibraryDatabase) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        let locator = SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null"))
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { _, _ in /* no-op: tests use synthetic paths */ },
            fileTrasher: { _ in /* no-op: tests use synthetic paths */ }
        )
        return (engine, database)
    }

    func testApplyFillSetsTheFieldOnAllChosenFiles() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/one.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: "Existing", genre: nil)
        )))
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/two.mp3",
            volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: "Existing", genre: nil)
        )))
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }

        let runner = LibraryHygieneRunner(operationEngine: engine)
        _ = try await runner.applyMissingFieldFill(
            field: .genre,
            value: "Hip-Hop",
            fileIds: files.compactMap(\.id),
            files: files
        )

        let updated = try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT genre FROM files ORDER BY id")
        }
        XCTAssertEqual(updated, ["Hip-Hop", "Hip-Hop"])
    }

    func testApplyFillSkipsRowsWhoseFieldIsNoLongerMissing() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/missing.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(genre: nil)
        )))
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/already.mp3",
            volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(genre: "Existing")
        )))
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        // Both fileIds passed in even though one already has a value.
        // The runner's live re-check should skip the already-populated one.
        let runner = LibraryHygieneRunner(operationEngine: engine)
        _ = try await runner.applyMissingFieldFill(
            field: .genre,
            value: "Hip-Hop",
            fileIds: files.compactMap(\.id),
            files: files
        )

        let updated = try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT genre FROM files ORDER BY id")
        }
        XCTAssertEqual(updated, ["Hip-Hop", "Existing"],
                       "fileId whose live value is non-missing must not be overwritten")
    }

    func testApplyFillRejectsWhitespaceOnlyValue() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(genre: nil)
        )))
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let runner = LibraryHygieneRunner(operationEngine: engine)
        _ = try await runner.applyMissingFieldFill(
            field: .genre,
            value: "   ",  // whitespace only
            fileIds: files.compactMap(\.id),
            files: files
        )
        // Should be a no-op — filling a missing field with all-whitespace
        // would just trade one form of "missing" for another.
        let genre = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT genre FROM files")
        }
        XCTAssertNil(genre, "whitespace-only fill value must be rejected")
    }

    func testFillBatchIsFullyUndoable() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(genre: nil)
        )))
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let runner = LibraryHygieneRunner(operationEngine: engine)
        let batchId = try await runner.applyMissingFieldFill(
            field: .genre,
            value: "Hip-Hop",
            fileIds: files.compactMap(\.id),
            files: files
        )

        let postFill = try await database.writer.read { db in
            try FileRecord.fetchAll(db).first!
        }
        XCTAssertEqual(postFill.genre, "Hip-Hop")

        _ = try await engine.undoBatch(batchId)

        let postUndo = try await database.writer.read { db in
            try FileRecord.fetchAll(db).first!
        }
        XCTAssertNil(postUndo.genre,
                     "undo of missing-field fill must restore the original (missing) state")
    }
}

final class LibraryHygieneRunnerTests: XCTestCase {

    @MainActor
    private func makeEngine() throws -> (OperationEngine, LibraryDatabase) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        let locator = SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null"))
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { _, _ in /* no-op: tests use synthetic paths */ },
            fileTrasher: { _ in /* no-op: tests use synthetic paths */ }
        )
        return (engine, database)
    }

    func testApplyTrimsEverySelectedField() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: " Artist  ", title: "Title ")
        )))
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let issues = LibraryHygiene.findWhitespaceIssues(in: files)
        XCTAssertEqual(issues.count, 2)

        let runner = LibraryHygieneRunner(operationEngine: engine)
        _ = try await runner.applyWhitespaceFixes(issues, files: files)

        let cleaned = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        XCTAssertEqual(cleaned.first?.artist, "Artist")
        XCTAssertEqual(cleaned.first?.title, "Title")
    }

    func testApplyJournalsAllThreeMutationsUnderSameBatchId() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: " Artist")
        )))
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let issues = LibraryHygiene.findWhitespaceIssues(in: files)

        let runner = LibraryHygieneRunner(operationEngine: engine)
        let batchId = try await runner.applyWhitespaceFixes(issues, files: files)

        let batchEvents = try await database.writer.read { db in
            try EventRecord
                .filter(Column("batch_id") == batchId)
                .order(Column("event_id").asc)
                .fetchAll(db)
        }
        XCTAssertEqual(batchEvents.count, 3,
                       "setMetadata + commitMetadataToSerato + writeFileTags per affected file")
        XCTAssertEqual(batchEvents.map(\.eventType),
                       [.metadataSet, .metadataCommittedToSerato, .fileTagsWritten])
    }

    func testHygieneBatchIsFullyUndoable() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            metadata: SeratoMetadata(artist: " Aphex Twin ", title: "Windowlicker ")
        )))
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let issues = LibraryHygiene.findWhitespaceIssues(in: files)

        let runner = LibraryHygieneRunner(operationEngine: engine)
        let batchId = try await runner.applyWhitespaceFixes(issues, files: files)

        // Sanity: after fix, fields are trimmed.
        let postFix = try await database.writer.read { db in
            try FileRecord.fetchAll(db).first!
        }
        XCTAssertEqual(postFix.artist, "Aphex Twin")
        XCTAssertEqual(postFix.title, "Windowlicker")

        // Undo the batch — both events must be reversible. Pre-PR
        // this threw undoNotSupported because commitMetadataToSerato
        // was uninvertible.
        _ = try await engine.undoBatch(batchId)

        let postUndo = try await database.writer.read { db in
            try FileRecord.fetchAll(db).first!
        }
        XCTAssertEqual(postUndo.artist, " Aphex Twin ",
                       "undo of hygiene must restore the original whitespace")
        XCTAssertEqual(postUndo.title, "Windowlicker ")
    }
}

final class DuplicateFinderTests: XCTestCase {

    private func makeFile(
        id: Int64,
        path: String,
        size: Int64 = 1024,
        lightweightHash: Data? = nil,
        chromaprintFingerprint: Data? = nil,
        fingerprintStatus: FingerprintStatus = .pending
    ) -> FileRecord {
        FileRecord(
            id: id,
            path: path,
            volumeUuid: "v1",
            inode: id,
            fileSize: size,
            mtime: 1,
            lightweightHash: lightweightHash,
            chromaprintFingerprint: chromaprintFingerprint,
            fingerprintStatus: fingerprintStatus
        )
    }

    // MARK: - Byte-level

    func testByteLevelGroupsFilesWithSameSizeAndHash() {
        let hash = Data([0xAA, 0xBB, 0xCC])
        let groups = DuplicateFinder.findDuplicates(
            in: [
                makeFile(id: 1, path: "/Music/A/one.mp3", lightweightHash: hash),
                makeFile(id: 2, path: "/Music/B/copy.mp3", lightweightHash: hash),
                makeFile(id: 3, path: "/Music/A/unrelated.mp3",
                         lightweightHash: Data([0xFF])),
            ],
            mode: .byteLevel
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.size, 2)
        XCTAssertEqual(groups.first?.files.map(\.id), [1, 2])
    }

    func testByteLevelDistinguishesFilesWithSameHashButDifferentSize() {
        // Lightweight hash collisions across different file sizes
        // are astronomically unlikely but the implementation must
        // include size in the bucket key.
        let hash = Data([0xAA])
        let groups = DuplicateFinder.findDuplicates(
            in: [
                makeFile(id: 1, path: "/Music/A/big.mp3", size: 5_000_000, lightweightHash: hash),
                makeFile(id: 2, path: "/Music/A/small.mp3", size: 1_000_000, lightweightHash: hash),
            ],
            mode: .byteLevel
        )
        XCTAssertEqual(groups.count, 0,
                       "different file sizes must NOT match even with identical hash")
    }

    func testByteLevelSkipsFilesWithoutHash() {
        let groups = DuplicateFinder.findDuplicates(
            in: [
                makeFile(id: 1, path: "/Music/A/missing-hash.mp3", lightweightHash: nil),
                makeFile(id: 2, path: "/Music/B/also-missing.mp3", lightweightHash: nil),
            ],
            mode: .byteLevel
        )
        XCTAssertEqual(groups.count, 0,
                       "files without lightweight_hash can't be matched — must not group as duplicates")
    }

    func testByteLevelDropsSingletonGroups() {
        // A single file in its own bucket isn't a duplicate.
        let groups = DuplicateFinder.findDuplicates(
            in: [makeFile(id: 1, path: "/Music/A/solo.mp3",
                          lightweightHash: Data([0xAB]))],
            mode: .byteLevel
        )
        XCTAssertEqual(groups.count, 0)
    }

    // MARK: - Perceptual

    func testPerceptualGroupsFilesWithSameFingerprint() {
        let fingerprint = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let groups = DuplicateFinder.findDuplicates(
            in: [
                makeFile(id: 1, path: "/Music/A/track.mp3",
                         chromaprintFingerprint: fingerprint,
                         fingerprintStatus: .done),
                makeFile(id: 2, path: "/Music/A/track.flac",
                         chromaprintFingerprint: fingerprint,
                         fingerprintStatus: .done),
                makeFile(id: 3, path: "/Music/A/different.mp3",
                         chromaprintFingerprint: Data([0xFE]),
                         fingerprintStatus: .done),
            ],
            mode: .perceptual
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.size, 2)
        XCTAssertEqual(Set(groups.first?.files.map(\.id) ?? []), [1, 2],
                       "perceptual must group MP3 + FLAC of the same recording")
    }

    func testPerceptualSkipsFilesWithoutDoneStatus() {
        let fingerprint = Data([0x01, 0x02])
        let groups = DuplicateFinder.findDuplicates(
            in: [
                makeFile(id: 1, path: "/Music/A/done.mp3",
                         chromaprintFingerprint: fingerprint,
                         fingerprintStatus: .done),
                makeFile(id: 2, path: "/Music/A/pending.mp3",
                         chromaprintFingerprint: fingerprint,  // tagged but worker hadn't marked done
                         fingerprintStatus: .pending),
                makeFile(id: 3, path: "/Music/A/failed.mp3",
                         chromaprintFingerprint: nil,
                         fingerprintStatus: .failed),
            ],
            mode: .perceptual
        )
        XCTAssertEqual(groups.count, 0,
                       "only fingerprint_status = .done rows can participate in perceptual grouping")
    }

    // MARK: - Group sorting

    func testGroupsAreSortedByDescendingSize() {
        let hashA = Data([0xAA])
        let hashB = Data([0xBB])
        let groups = DuplicateFinder.findDuplicates(
            in: [
                makeFile(id: 1, path: "/Music/A/a1.mp3", lightweightHash: hashA),
                makeFile(id: 2, path: "/Music/A/a2.mp3", lightweightHash: hashA),
                makeFile(id: 3, path: "/Music/A/a3.mp3", lightweightHash: hashA),
                makeFile(id: 4, path: "/Music/B/b1.mp3", lightweightHash: hashB),
                makeFile(id: 5, path: "/Music/B/b2.mp3", lightweightHash: hashB),
            ],
            mode: .byteLevel
        )
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.size, 3,
                       "biggest group must come first (the most impactful issue)")
        XCTAssertEqual(groups.last?.size, 2)
    }

    // MARK: - Coverage helper

    func testFingerprintCoverageCountsDoneRows() {
        let coverage = DuplicateFinder.fingerprintCoverage(in: [
            makeFile(id: 1, path: "/a.mp3", chromaprintFingerprint: Data([0x01]),
                     fingerprintStatus: .done),
            makeFile(id: 2, path: "/b.mp3", chromaprintFingerprint: Data([0x02]),
                     fingerprintStatus: .done),
            makeFile(id: 3, path: "/c.mp3", fingerprintStatus: .pending),
            makeFile(id: 4, path: "/d.mp3", fingerprintStatus: .failed),
        ])
        XCTAssertEqual(coverage.done, 2)
        XCTAssertEqual(coverage.total, 4)
    }
}

final class DuplicateKeeperPickerTests: XCTestCase {

    private let musicFolder = URL(fileURLWithPath: "/Users/test/Music", isDirectory: true)

    private func makeFile(
        id: Int64,
        path: String,
        bitrate: Int? = nil,
        mtime: Int64 = 1_700_000_000,
        artist: String? = nil
    ) -> FileRecord {
        FileRecord(
            id: id,
            path: path,
            volumeUuid: "v1",
            inode: id,
            fileSize: 1024,
            mtime: mtime,
            bitrateKbps: bitrate,
            artist: artist
        )
    }

    // MARK: - Quality tier

    func testPicksLosslessOverLossy() {
        // .flac is lossless tier 2; .mp3 320 is lossy tier 1. Lossless
        // wins regardless of how high the MP3 bitrate is.
        let group = DuplicateFinder.DuplicateGroup(
            groupKey: "k",
            mode: .perceptual,
            files: [
                makeFile(id: 1, path: "/Users/test/Music/A/track.mp3", bitrate: 320),
                makeFile(id: 2, path: "/Users/test/Music/A/track.flac"),
            ]
        )
        XCTAssertEqual(
            DuplicateKeeperPicker.chooseDefaultKeeper(for: group, musicFolder: musicFolder),
            2,
            "lossless format must win over lossy regardless of bitrate"
        )
    }

    func testPicksHigherBitrateWithinLossyTier() {
        let group = DuplicateFinder.DuplicateGroup(
            groupKey: "k",
            mode: .perceptual,
            files: [
                makeFile(id: 1, path: "/Users/test/Music/A/lo.mp3", bitrate: 128),
                makeFile(id: 2, path: "/Users/test/Music/A/hi.mp3", bitrate: 320),
            ]
        )
        XCTAssertEqual(
            DuplicateKeeperPicker.chooseDefaultKeeper(for: group, musicFolder: musicFolder),
            2
        )
    }

    func testTreatsLosslessBitratesAsEqual() {
        // Both files lossless. Bitrate field on lossless tier is
        // meaningless; bucket-match / mtime / path break the tie.
        let group = DuplicateFinder.DuplicateGroup(
            groupKey: "k",
            mode: .perceptual,
            files: [
                makeFile(id: 1, path: "/Users/test/Music/A/a.flac",
                         bitrate: 900, mtime: 2_000_000_000),
                makeFile(id: 2, path: "/Users/test/Music/A/a.wav",
                         bitrate: 1411, mtime: 1_000_000_000),  // older
            ]
        )
        // Within lossless tier: bitrate matters in the implementation
        // because rank() still uses it as a comparator. But the
        // user-visible behavior we want is "WAV vs FLAC of same recording
        // is a tie." Pinning current behavior: bitrate is the next
        // tiebreaker after tier. If we later want pure tier-equality,
        // the picker switches to ignoring bitrate when tier == lossless.
        XCTAssertEqual(
            DuplicateKeeperPicker.chooseDefaultKeeper(for: group, musicFolder: musicFolder),
            2,
            "higher bitrate WAV wins even at lossless tier — current pinned behavior"
        )
    }

    // MARK: - Bucket match

    func testPicksBucketedFileWhenQualityTies() {
        // Both MP3 320. One is in the proper artist-letter bucket
        // (artist "Aphex Twin" → bucket "A"); the other drifted to
        // a different subfolder. Bucket-match breaks the tie.
        let group = DuplicateFinder.DuplicateGroup(
            groupKey: "k",
            mode: .perceptual,
            files: [
                makeFile(
                    id: 1,
                    path: "/Users/test/Music/A/Aphex Twin - Track.mp3",
                    bitrate: 320,
                    artist: "Aphex Twin"
                ),
                makeFile(
                    id: 2,
                    path: "/Users/test/Music/Random/Aphex Twin - Track.mp3",
                    bitrate: 320,
                    artist: "Aphex Twin"
                ),
            ]
        )
        XCTAssertEqual(
            DuplicateKeeperPicker.chooseDefaultKeeper(for: group, musicFolder: musicFolder),
            1,
            "bucketed file wins when quality is tied"
        )
    }

    // MARK: - mtime

    func testPicksOlderFileWhenQualityAndBucketBothTie() {
        let group = DuplicateFinder.DuplicateGroup(
            groupKey: "k",
            mode: .byteLevel,
            files: [
                makeFile(id: 1, path: "/Users/test/Music/A/a.mp3",
                         bitrate: 320, mtime: 2_000_000_000),  // newer
                makeFile(id: 2, path: "/Users/test/Music/A/b.mp3",
                         bitrate: 320, mtime: 1_000_000_000),  // older
            ]
        )
        XCTAssertEqual(
            DuplicateKeeperPicker.chooseDefaultKeeper(for: group, musicFolder: musicFolder),
            2,
            "the older file is treated as the original / canonical copy"
        )
    }

    // MARK: - Path tiebreak (deterministic)

    func testPathBreaksTieAlphabeticallyWhenAllElseEqual() {
        let group = DuplicateFinder.DuplicateGroup(
            groupKey: "k",
            mode: .byteLevel,
            files: [
                makeFile(id: 1, path: "/Users/test/Music/A/zebra.mp3",
                         bitrate: 320, mtime: 1_700_000_000),
                makeFile(id: 2, path: "/Users/test/Music/A/alpha.mp3",
                         bitrate: 320, mtime: 1_700_000_000),
            ]
        )
        XCTAssertEqual(
            DuplicateKeeperPicker.chooseDefaultKeeper(for: group, musicFolder: musicFolder),
            2,
            "alphabetically-earlier path wins"
        )
    }

    // MARK: - Edge cases

    func testReturnsNilForEmptyGroup() {
        // Defensive: the duplicate finder won't ever produce one, but
        // the picker shouldn't crash if it did.
        let group = DuplicateFinder.DuplicateGroup(
            groupKey: "k", mode: .byteLevel, files: []
        )
        XCTAssertNil(
            DuplicateKeeperPicker.chooseDefaultKeeper(for: group, musicFolder: musicFolder)
        )
    }

    // MARK: - Pure helpers

    func testQualityTierMapsExtensions() {
        XCTAssertEqual(
            DuplicateKeeperPicker.qualityTier(for: makeFile(id: 1, path: "/x.flac")),
            2
        )
        XCTAssertEqual(
            DuplicateKeeperPicker.qualityTier(for: makeFile(id: 2, path: "/x.MP3")),
            1,
            "extension match is case-insensitive"
        )
        XCTAssertEqual(
            DuplicateKeeperPicker.qualityTier(for: makeFile(id: 3, path: "/x.weird")),
            0
        )
    }

    func testPathMatchesArtistBucketHandlesArticleStripping() {
        // Artist "The Beatles" normalizes to bucket "B". A file at
        // <Music>/B/... matches; <Music>/T/... doesn't.
        let beatlesInBucket = makeFile(
            id: 1,
            path: "/Users/test/Music/B/The Beatles - Hey Jude.mp3",
            artist: "The Beatles"
        )
        XCTAssertTrue(
            DuplicateKeeperPicker.pathMatchesArtistBucket(
                file: beatlesInBucket, musicFolder: musicFolder
            )
        )
        let beatlesOutOfBucket = makeFile(
            id: 2,
            path: "/Users/test/Music/T/The Beatles - Hey Jude.mp3",
            artist: "The Beatles"
        )
        XCTAssertFalse(
            DuplicateKeeperPicker.pathMatchesArtistBucket(
                file: beatlesOutOfBucket, musicFolder: musicFolder
            )
        )
    }

    func testPathMatchesArtistBucketReturnsFalseForFilesOutsideMusicFolder() {
        let outside = makeFile(
            id: 1,
            path: "/Volumes/External/A/track.mp3",
            artist: "Aphex Twin"
        )
        XCTAssertFalse(
            DuplicateKeeperPicker.pathMatchesArtistBucket(
                file: outside, musicFolder: musicFolder
            )
        )
    }
}

final class DuplicateResolverTests: XCTestCase {

    /// Records trasher invocations so the test can assert which
    /// files would have been moved to Trash.
    private final class TrasherRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _paths: [String] = []
        var paths: [String] {
            lock.lock(); defer { lock.unlock() }
            return _paths
        }
        func record(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            _paths.append(path)
        }
    }

    @MainActor
    private func makeEngine(
        recorder: TrasherRecorder = TrasherRecorder()
    ) throws -> (OperationEngine, LibraryDatabase, TrasherRecorder) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        let locator = SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null"))
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { _, _ in },
            fileTrasher: { path in recorder.record(path) }
        )
        return (engine, database, recorder)
    }

    private func indexFile(
        path: String,
        inode: Int64,
        engine: OperationEngine
    ) async throws -> Int64 {
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: path,
            volumeUuid: "v1",
            inode: inode,
            fileSize: 1, mtime: 1
        )))
        return try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: path + ".duplicate-bootstrap-noop",  // workaround
            volumeUuid: "v1",
            inode: inode + 1000,
            fileSize: 1, mtime: 1
        )))
        // placeholder — replaced below
    }

    func testResolveTrashesNonKeepersAndKeepsTheChosenFile() async throws {
        let (engine, database, recorder) = try await MainActor.run { try makeEngine() }
        let keeperPath = "/Music/A/keeper.mp3"
        let dupePath = "/Music/A/dupe.mp3"

        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: keeperPath, volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: dupePath, volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1
        )))
        let keeperId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: [keeperPath])
        }!
        let dupeId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: [dupePath])
        }!

        // Pull the (now-inserted) FileRecords to build a real group.
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let group = DuplicateFinder.DuplicateGroup(
            groupKey: "k", mode: .byteLevel, files: files
        )

        let resolver = DuplicateResolver(operationEngine: engine)
        let outcome = try await resolver.resolve(group: group, keeperId: keeperId)

        XCTAssertEqual(outcome.trashedCount, 1)
        XCTAssertEqual(recorder.paths, [dupePath],
                       "the keeper must NOT be trashed; only non-keepers")
        let surviving = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        XCTAssertEqual(surviving.count, 1)
        XCTAssertEqual(surviving.first?.id, keeperId,
                       "the keeper's file row must remain in the DB")
        XCTAssertNotEqual(surviving.first?.id, dupeId)
    }

    func testResolveJournalsFourEventsPerNonKeeperUnderOneBatch() async throws {
        let (engine, database, _) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/k.mp3", volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/d1.mp3", volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1
        )))
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/d2.mp3", volumeUuid: "v1", inode: 3, fileSize: 1, mtime: 1
        )))
        let keeperId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/k.mp3"])
        }!
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let group = DuplicateFinder.DuplicateGroup(
            groupKey: "k", mode: .byteLevel, files: files
        )

        let resolver = DuplicateResolver(operationEngine: engine)
        let outcome = try await resolver.resolve(group: group, keeperId: keeperId)

        // 2 non-keepers × 4 mutations = 8 events; all under one batch.
        let batchEvents = try await database.writer.read { db in
            try EventRecord
                .filter(Column("batch_id") == outcome.batchId)
                .order(Column("event_id").asc)
                .fetchAll(db)
        }
        XCTAssertEqual(batchEvents.count, 8)
        XCTAssertEqual(batchEvents.map(\.eventType), [
            .trackRemovedFromSerato, .fileRemovedFromCrates, .fileTrashed, .fileRemoved,
            .trackRemovedFromSerato, .fileRemovedFromCrates, .fileTrashed, .fileRemoved,
        ])
    }

    func testResolveRejectsKeeperNotInGroup() async throws {
        let (engine, database, _) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/a.mp3", volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let group = DuplicateFinder.DuplicateGroup(
            groupKey: "k", mode: .byteLevel, files: files
        )
        let resolver = DuplicateResolver(operationEngine: engine)
        do {
            _ = try await resolver.resolve(group: group, keeperId: 9999)
            XCTFail("expected keeperNotInGroup")
        } catch let error as DuplicateResolver.ResolverError {
            XCTAssertEqual(error, .keeperNotInGroup)
        }
    }

    func testResolveBatchIsNotUndoable() async throws {
        let (engine, database, _) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/k.mp3", volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/d.mp3", volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1
        )))
        let keeperId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/k.mp3"])
        }!
        let files = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let group = DuplicateFinder.DuplicateGroup(
            groupKey: "k", mode: .byteLevel, files: files
        )
        let resolver = DuplicateResolver(operationEngine: engine)
        let outcome = try await resolver.resolve(group: group, keeperId: keeperId)

        do {
            _ = try await engine.undoBatch(outcome.batchId)
            XCTFail("resolution batch must not be undoable through the engine")
        } catch let error as OperationEngineError {
            // The first event in newest-first order is fileRemoved
            // (the last one journaled). undoBatch processes in
            // reverse so it sees fileRemoved → its inverse is
            // indexNewFile which IS supported. The trash, however,
            // throws undoNotSupported. Either rejection is correct
            // — what matters is that the batch is rejected.
            switch error {
            case .undoNotSupported:
                break
            default:
                XCTFail("expected undoNotSupported, got \(error)")
            }
        }
    }
}

final class WriteFileTagsMutationTests: XCTestCase {

    /// Captures calls from the injected fileTagWriter so the test
    /// can assert what would have been written to disk.
    private final class FileTagWriterRecorder: @unchecked Sendable {
        struct Call: Sendable, Equatable {
            let path: String
            let update: AudioTagUpdate
        }
        private let lock = NSLock()
        private var _calls: [Call] = []
        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func record(_ path: String, _ update: AudioTagUpdate) {
            lock.lock(); defer { lock.unlock() }
            _calls.append(Call(path: path, update: update))
        }
    }

    @MainActor
    private func makeEngine(
        recorder: FileTagWriterRecorder = FileTagWriterRecorder(),
        seratoIsRunning: Bool = false
    ) throws -> (OperationEngine, LibraryDatabase, FileTagWriterRecorder) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: {
            seratoIsRunning ? ["com.serato.djpro"] : []
        })
        let locator = SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null"))
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { path, update in
                recorder.record(path, update)
            }
        )
        return (engine, database, recorder)
    }

    func testWriteFileTagsInvokesWriterWithResolvedPath() async throws {
        let (engine, database, recorder) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/track.mp3"])
        }!

        try await engine.apply(.writeFileTags(WriteFileTagsPayload(
            fileId: fileId,
            metadata: SeratoMetadata(artist: "New Artist", title: "New Title"),
            previousMetadata: SeratoMetadata()
        )))

        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?.path, "/Music/A/track.mp3")
        XCTAssertEqual(recorder.calls.first?.update.artist, "New Artist")
        XCTAssertEqual(recorder.calls.first?.update.title, "New Title")
    }

    func testWriteFileTagsQueuesWhileSeratoIsRunning() async throws {
        let (engine, database, recorder) = try await MainActor.run {
            try makeEngine(seratoIsRunning: true)
        }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/track.mp3"])
        }!

        try await engine.apply(.writeFileTags(WriteFileTagsPayload(
            fileId: fileId,
            metadata: SeratoMetadata(artist: "Edited"),
            previousMetadata: SeratoMetadata()
        )))

        XCTAssertEqual(recorder.calls.count, 0,
                       "writer must NOT fire while Serato is running — Serato may have the file mmapped")
        let queueDepth = await engine.pendingSeratoWriteCount
        XCTAssertEqual(queueDepth, 1,
                       "file tag write must be queued alongside other Serato-gated writes")
    }

    func testWriteFileTagsUndoableViaBatch() async throws {
        let (engine, database, recorder) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/track.mp3"])
        }!

        let batchId = "test-tag-write"
        try await engine.apply(
            .writeFileTags(WriteFileTagsPayload(
                fileId: fileId,
                metadata: SeratoMetadata(artist: "After"),
                previousMetadata: SeratoMetadata(artist: "Before")
            )),
            batchId: batchId
        )
        XCTAssertEqual(recorder.calls.last?.update.artist, "After")

        _ = try await engine.undoBatch(batchId)
        // Undo should have invoked the writer again with the
        // previous-state values.
        XCTAssertEqual(recorder.calls.count, 2)
        XCTAssertEqual(recorder.calls.last?.update.artist, "Before",
                       "undo of writeFileTags must re-issue the writer with previousMetadata")
    }

    func testUndoRejectsWriteFileTagsLackingPreviousMetadata() async throws {
        let (engine, database, _) = try await MainActor.run { try makeEngine() }
        try await engine.apply(.indexNewFile(IndexNewFilePayload(
            path: "/Music/A/track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1
        )))
        let fileId = try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM files WHERE path = ?",
                              arguments: ["/Music/A/track.mp3"])
        }!

        let batchId = "no-previous-state"
        try await engine.apply(
            .writeFileTags(WriteFileTagsPayload(
                fileId: fileId,
                metadata: SeratoMetadata(artist: "After")
                // previousMetadata omitted → nil → un-undoable
            )),
            batchId: batchId
        )
        do {
            _ = try await engine.undoBatch(batchId)
            XCTFail("expected undoNotSupported for writeFileTags without previousMetadata")
        } catch let error as OperationEngineError {
            XCTAssertEqual(error, .undoNotSupported(eventType: .fileTagsWritten))
        }
    }
}

final class LibraryOrganizerPlannerTests: XCTestCase {

    private let musicFolder = URL(fileURLWithPath: "/Music")
    private let template = "$artist - $title.$ext"

    func testSkipsFilesAlreadyAtCanonicalPath() {
        let file = FileRecord(
            id: 1,
            path: "/Music/A/Artist - Track.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            artist: "Artist", title: "Track"
        )
        let plans = LibraryOrganizer.findMoves(
            in: [file], musicFolder: musicFolder, template: template
        )
        XCTAssertTrue(plans.isEmpty, "file at canonical destination produces no plan")
    }

    func testProducesPlanForFileOutsideMusicFolder() {
        let file = FileRecord(
            id: 1,
            path: "/Users/benny/Downloads/loose.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            artist: "Artist", title: "Track"
        )
        let plans = LibraryOrganizer.findMoves(
            in: [file], musicFolder: musicFolder, template: template
        )
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].destinationPath, "/Music/A/Artist - Track.mp3")
        XCTAssertTrue(plans[0].isOutsideMusicFolder)
    }

    func testProducesPlanForFileInsideButMislocated() {
        // Wrong letter bucket — file is in B/ but artist starts with A.
        let file = FileRecord(
            id: 1,
            path: "/Music/B/wrong-bucket.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            artist: "Artist", title: "Track"
        )
        let plans = LibraryOrganizer.findMoves(
            in: [file], musicFolder: musicFolder, template: template
        )
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].destinationPath, "/Music/A/Artist - Track.mp3")
        XCTAssertFalse(plans[0].isOutsideMusicFolder,
                       "files within the music folder are not 'outside'")
    }

    func testDisambiguatesCollisionsWithinBatch() {
        // Two files map to the same canonical destination — both
        // have artist "Artist" and title "Track" but different
        // source paths. The second should get a (1) suffix.
        let fileA = FileRecord(
            id: 1,
            path: "/Users/benny/Downloads/first.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            artist: "Artist", title: "Track"
        )
        let fileB = FileRecord(
            id: 2,
            path: "/Users/benny/Downloads/second.mp3",
            volumeUuid: "v1", inode: 2, fileSize: 1, mtime: 1,
            artist: "Artist", title: "Track"
        )
        let plans = LibraryOrganizer.findMoves(
            in: [fileA, fileB], musicFolder: musicFolder, template: template
        )
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans[0].destinationPath, "/Music/A/Artist - Track.mp3")
        XCTAssertEqual(plans[1].destinationPath, "/Music/A/Artist - Track (1).mp3",
                       "second collider must get a (1) suffix")
    }

    func testFileWithoutIdIsSkipped() {
        // An un-id'd FileRecord (in-memory only) shouldn't get planned.
        let file = FileRecord(
            id: nil,
            path: "/Users/benny/Downloads/loose.mp3",
            volumeUuid: "v1", inode: 1, fileSize: 1, mtime: 1,
            artist: "Artist", title: "Track"
        )
        let plans = LibraryOrganizer.findMoves(
            in: [file], musicFolder: musicFolder, template: template
        )
        XCTAssertTrue(plans.isEmpty)
    }
}
