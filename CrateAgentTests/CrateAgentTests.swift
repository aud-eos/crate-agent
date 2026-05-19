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

        let queueDepth = await engine.pendingSeratoRenameCount
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

        let queueDepth = await engine.pendingSeratoRenameCount
        XCTAssertEqual(queueDepth, 1, "the rewrite must be queued, not applied")
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

        let queueDepthAfterDrain = await engine.pendingSeratoRenameCount
        XCTAssertEqual(queueDepthAfterDrain, 0)
    }

    // MARK: - Synthetic Serato fixture helpers

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
    private func makeScanner() throws -> (LibraryScanner, OperationEngine, LibraryDatabase) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        let locator = SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null"))
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator
        )
        let scanner = LibraryScanner(operationEngine: engine, database: database)
        return (scanner, engine, database)
    }

    private func makeTempLibrary(
        filesAtRelativePaths relativePaths: [String]
    ) throws -> URL {
        let rootUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-test-scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootUrl, withIntermediateDirectories: true)
        for relativePath in relativePaths {
            let fileUrl = rootUrl.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileUrl.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("audio".utf8).write(to: fileUrl)
        }
        return rootUrl
    }

    func testScanIndexesAllAudioFiles() async throws {
        let (scanner, _, database) = try await MainActor.run { try makeScanner() }
        let libraryRoot = try makeTempLibrary(filesAtRelativePaths: [
            "A/Track One.mp3",
            "A/Track Two.flac",
            "B/Some Song.m4a",
            "B/Subfolder/Deep Cut.wav",
        ])
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let result = try await scanner.scan(libraryRoot)
        XCTAssertEqual(result.filesEncountered, 4)
        XCTAssertEqual(result.filesIndexed, 4)
        XCTAssertEqual(result.filesSkipped, 0)

        let indexedCount = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(indexedCount, 4)
    }

    func testScanSkipsNonAudioFiles() async throws {
        let (scanner, _, database) = try await MainActor.run { try makeScanner() }
        let libraryRoot = try makeTempLibrary(filesAtRelativePaths: [
            "A/Track.mp3",
            "A/.DS_Store",
            "A/cover.jpg",
            "A/notes.txt",
        ])
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let result = try await scanner.scan(libraryRoot)
        XCTAssertEqual(result.filesEncountered, 1, "only the .mp3 should be encountered")

        let indexedCount = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(indexedCount, 1)
    }

    func testRescanSkipsAlreadyIndexedFiles() async throws {
        let (scanner, _, database) = try await MainActor.run { try makeScanner() }
        let libraryRoot = try makeTempLibrary(filesAtRelativePaths: [
            "A/Track.mp3",
            "B/Other.flac",
        ])
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let firstResult = try await scanner.scan(libraryRoot)
        XCTAssertEqual(firstResult.filesIndexed, 2)
        XCTAssertEqual(firstResult.filesSkipped, 0)

        let secondResult = try await scanner.scan(libraryRoot)
        XCTAssertEqual(secondResult.filesEncountered, 2)
        XCTAssertEqual(secondResult.filesIndexed, 0,
                       "second scan must not re-index known files")
        XCTAssertEqual(secondResult.filesSkipped, 2)

        let totalRows = try await database.writer.read { db in
            try FileRecord.fetchCount(db)
        }
        XCTAssertEqual(totalRows, 2, "rescan must not duplicate rows")
    }

    func testReferenceSetAllowsManagedLibraryFilesThatSeratoReferences() async throws {
        // Construct paths that fall inside the *real* managed library
        // root for the current user. ManagedLibraryDetector uses
        // FileManager.default.homeDirectoryForCurrentUser by default,
        // so we have to play in that namespace to exercise the filter.
        let realHomeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let testRunDirectory = realHomeDirectory
            .appendingPathComponent("Music/Music/Media", isDirectory: true)
            .appendingPathComponent("crate-agent-test-\(UUID().uuidString)", isDirectory: true)

        // If the user's home doesn't have a Music/Music/Media dir at
        // all (machine without Apple Music) we skip the test rather
        // than create one. The detector logic is exhaustively
        // covered by ManagedLibraryDetectorTests above; this test is
        // about scanner integration only.
        let parent = realHomeDirectory.appendingPathComponent("Music/Music/Media", isDirectory: true)
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw XCTSkip("Apple Music's Media folder not present on this machine; skipping integration test")
        }

        try FileManager.default.createDirectory(at: testRunDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRunDirectory) }

        let inSeratoFile = testRunDirectory.appendingPathComponent("InSerato.mp3")
        let notInSeratoFile = testRunDirectory.appendingPathComponent("NotInSerato.mp3")
        try Data("audio".utf8).write(to: inSeratoFile)
        try Data("audio".utf8).write(to: notInSeratoFile)

        let referenceSet = SeratoLibraryReferenceSet(paths: [inSeratoFile.path])

        let (scanner, _, database) = try await MainActor.run { try makeScanner() }
        _ = try await scanner.scan(testRunDirectory, seratoReferenceSet: referenceSet)

        let indexedPaths = try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM files ORDER BY path")
        }
        XCTAssertEqual(
            indexedPaths,
            [inSeratoFile.path],
            "Serato-referenced managed file is indexed; others under the same managed root are skipped"
        )
    }

    func testProgressCallbackFiresOnFinalBatchEvenForSmallScans() async throws {
        let (scanner, _, _) = try await MainActor.run { try makeScanner() }
        let libraryRoot = try makeTempLibrary(filesAtRelativePaths: [
            "A/Track.mp3",
            "B/Other.flac",
        ])
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let progressLock = NSLock()
        var progressUpdates: [LibraryScanner.ScanProgress] = []

        _ = try await scanner.scan(libraryRoot) { progress in
            progressLock.lock()
            progressUpdates.append(progress)
            progressLock.unlock()
        }

        progressLock.lock()
        let snapshot = progressUpdates
        progressLock.unlock()

        XCTAssertFalse(snapshot.isEmpty, "at least one progress callback expected")
        XCTAssertEqual(snapshot.last?.filesIndexed, 2)
        XCTAssertEqual(snapshot.last?.filesEncountered, 2)
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

    func testCreatedAudioFileGetsIndexed() async throws {
        let (coordinator, _, database) = try await MainActor.run { try makeCoordinator() }
        let audioFile = try makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audioFile) }

        let observation = FSEventsObservation(
            path: audioFile.path, isFile: true, wasCreated: true
        )
        await coordinator.handleObservations([observation])

        let indexed = try await database.writer.read { db in
            try FileRecord.fetchOne(db, sql: "SELECT * FROM files WHERE path = ?",
                                    arguments: [audioFile.path])
        }
        XCTAssertNotNil(indexed)
        XCTAssertEqual(indexed?.path, audioFile.path)
        XCTAssertGreaterThan(indexed?.fileSize ?? 0, 0)
        XCTAssertEqual(indexed?.fingerprintStatus, .pending)
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

final class ManagedLibraryDetectorTests: XCTestCase {

    private let fakeHome = URL(fileURLWithPath: "/Users/testuser")

    func testFlagsAppleMusicMediaPath() {
        XCTAssertTrue(ManagedLibraryDetector.isInsideManagedLibrary(
            "/Users/testuser/Music/Music/Media/Music/Artist/Track.mp3",
            homeDirectory: fakeHome
        ))
    }

    func testFlagsLegacyITunesMediaPath() {
        XCTAssertTrue(ManagedLibraryDetector.isInsideManagedLibrary(
            "/Users/testuser/Music/iTunes/iTunes Media/Music/Artist/Track.mp3",
            homeDirectory: fakeHome
        ))
    }

    func testFlagsLogicAudioMusicAppsPath() {
        XCTAssertTrue(ManagedLibraryDetector.isInsideManagedLibrary(
            "/Users/testuser/Music/Audio Music Apps/Sampler Loops/loop.wav",
            homeDirectory: fakeHome
        ))
    }

    func testDoesNotFlagUserDjLibrary() {
        XCTAssertFalse(ManagedLibraryDetector.isInsideManagedLibrary(
            "/Users/testuser/Music/MyDjLibrary/Artist/Track.mp3",
            homeDirectory: fakeHome
        ))
    }

    func testDoesNotFalseMatchSimilarPrefix() {
        // `MediaTwo` should NOT match `Media` — the trailing-slash
        // check in the detector is what prevents false positives.
        XCTAssertFalse(ManagedLibraryDetector.isInsideManagedLibrary(
            "/Users/testuser/Music/Music/MediaTwo/Track.mp3",
            homeDirectory: fakeHome
        ))
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
