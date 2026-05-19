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
            seratoLocator: locator
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
            seratoLocator: locator
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
            seratoLocator: locator
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
