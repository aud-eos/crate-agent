import CryptoKit
import GRDB
import XCTest
@testable import CrateAgent

/// Group C2 (#836 + #3998713590): the batch-apply / external-write path.
///
/// `applyBatch` commits the SQLite transaction (events + inverse
/// payloads + row updates) BEFORE the external Serato-library and
/// audio-tag writes run. A post-commit external-write failure must NOT
/// read as "nothing happened" — the batch IS applied. These tests pin:
///
///   1. A mid-external-write failure (Serato closed) surfaces the typed
///      `.externalSyncIncomplete` outcome carrying the batchId, with the
///      whole batch committed to the DB.
///   2. A subsequent `resyncSeratoForBatch` finishes the missing external
///      writes idempotently WITHOUT inserting duplicate events.
///   3. A fully-successful batch journals exactly once and does not throw.
///   4. An N-row apply coalesces the `database V2` metadata updates into
///      exactly ONE read/rewrite pass (C2b), not N.
final class OperationEnginePartialFailureTests: XCTestCase {
    /// Records successful file-tag writes and can be told to throw on a
    /// chosen call number, simulating a read-only file / permissions
    /// error partway through the external-write phase.
    private final class ThrowingTagWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private var storedPaths: [String] = []
        var throwOnCall: Int?

        var writtenPaths: [String] {
            lock.lock(); defer { lock.unlock() }
            return storedPaths
        }

        func write(_ path: String) throws {
            lock.lock(); defer { lock.unlock() }
            callCount += 1
            if let target = throwOnCall, callCount == target {
                throw NSError(domain: "test", code: 13, userInfo: [
                    NSLocalizedDescriptionKey: "simulated read-only file",
                ])
            }
            storedPaths.append(path)
        }
    }

    /// Counts calls to the injected `database V2` metadata batch writer
    /// (one call == one V2 read+rewrite pass) and delegates to the real
    /// Rust FFI so the on-disk file is still updated for content checks.
    private final class MetadataBatchWriterSpy: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var callCount = 0

        func write(_ databasePath: String, _ updates: [SeratoTrackMetadataUpdate]) throws -> UInt32 {
            lock.lock(); callCount += 1; lock.unlock()
            return try batchUpdateDatabaseRecords(databasePath: databasePath, updates: updates)
        }
    }

    private let seratoPaths = ["Music/A/one.mp3", "Music/A/two.mp3", "Music/A/three.mp3"]

    private func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Build an engine over a real synthesized `database V2` seeded with
    /// the three otrks, plus three matching file rows in the sidecar DB.
    @MainActor
    private func makeEngineWithLibrary(
        tagWriter: ThrowingTagWriter,
        metadataSpy: MetadataBatchWriterSpy? = nil,
        seratoIsRunning: Bool = false
    ) throws -> (OperationEngine, LibraryDatabase, URL, [Int64]) {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crate-agent-c2-\(UUID().uuidString)", isDirectory: true)
        let seratoDirectory = rootDirectory.appendingPathComponent("_Serato_", isDirectory: true)
        try FileManager.default.createDirectory(
            at: seratoDirectory.appendingPathComponent("Subcrates", isDirectory: true),
            withIntermediateDirectories: true
        )
        let databaseV2 = seratoDirectory.appendingPathComponent("database V2")
        try OperationEngineTests.synthesizeDatabaseV2BytesForTest(withTrackPaths: seratoPaths)
            .write(to: databaseV2)

        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: {
            seratoIsRunning ? ["com.serato.djpro"] : []
        })
        let locator = SeratoLibraryLocator(seratoDirectory: seratoDirectory)
        let metadataWriter: OperationEngine.SeratoMetadataBatchWriter
        if let spy = metadataSpy {
            metadataWriter = { databasePath, updates in try spy.write(databasePath, updates) }
        } else {
            metadataWriter = { databasePath, updates in
                try batchUpdateDatabaseRecords(databasePath: databasePath, updates: updates)
            }
        }
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { path, _ in try tagWriter.write(path) },
            seratoMetadataBatchWriter: metadataWriter
        )

        // Absolute paths shaped so seratoRelativePath strips the leading
        // slash back to the fixture's Serato-relative form.
        let fileIds = try database.writer.write { db -> [Int64] in
            try seratoPaths.enumerated().map { index, seratoPath in
                var file = FileRecord(
                    path: "/\(seratoPath)", volumeUuid: "v1", inode: Int64(index + 1),
                    fileSize: 1, mtime: 1, artist: "old", title: "old", album: "old"
                )
                try file.insert(db)
                return file.id!
            }
        }
        return (engine, database, seratoDirectory, fileIds)
    }

    private func matchMutations(fileIds: [Int64]) -> [TrackMutation] {
        fileIds.enumerated().map { index, fileId in
            .applyMusicBrainzMatch(ApplyMusicBrainzMatchPayload(
                fileID: fileId,
                acoustID: "aid\(index)",
                recordingMBID: "rec\(index)",
                releaseMBID: "rel\(index)",
                artistMBID: "art\(index)",
                isrc: "isrc\(index)",
                fingerprintHash: sha256(Data("fp-\(index)".utf8)),
                expectedFileSize: 1,
                expectedMtime: 1,
                artist: "Artist\(index)",
                title: "Title\(index)",
                album: "Album\(index)",
                year: 1994 + index
            ))
        }
    }

    private func eventCount(
        in database: LibraryDatabase, batchId: String
    ) async throws -> Int {
        try await database.writer.read { db in
            try EventRecord.filter(Column("batch_id") == batchId).fetchCount(db)
        }
    }

    // MARK: - #836: partial external-write failure

    func testPartialExternalFailureCommitsBatchAndSurfacesTypedOutcome() async throws {
        let tagWriter = ThrowingTagWriter()
        tagWriter.throwOnCall = 2 // fail the 2nd of 3 file-tag writes
        let (engine, database, seratoDirectory, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        let batchId = "auto-tag-partial"
        let mutations = matchMutations(fileIds: fileIds)

        var caughtBatchId: String?
        do {
            _ = try await engine.applyBatch(mutations, batchId: batchId)
            XCTFail("expected external write to throw after the DB commit")
        } catch let OperationEngineError.externalSyncIncomplete(failedBatchId, _) {
            caughtBatchId = failedBatchId
        }
        XCTAssertEqual(caughtBatchId, batchId,
                       "partial failure must surface the batchId, not an opaque total-failure throw")

        // The DB transaction committed ALL three matches despite the
        // external write failing partway.
        try await database.writer.read { db in
            let events = try EventRecord
                .filter(Column("batch_id") == batchId)
                .filter(Column("event_type") == EventType.musicBrainzMatchApplied.rawValue)
                .fetchCount(db)
            XCTAssertEqual(events, 3, "every match's event must be journaled (batch committed)")
            for fileId in fileIds {
                let file = try FileRecord.fetchOne(db, key: fileId)!
                XCTAssertNotNil(file.trackId, "every file row linked to its track (committed)")
            }
        }

        // Recovery: the writer now succeeds; resync finishes the missing
        // external writes WITHOUT inserting duplicate events.
        let eventsBeforeResync = try await eventCount(in: database, batchId: batchId)
        tagWriter.throwOnCall = nil
        let outcome = try await engine.resyncSeratoForBatch(batchId)
        XCTAssertEqual(outcome.appliedCount, 3, "all three matches replayed to disk")
        XCTAssertEqual(outcome.queuedCount, 0, "Serato closed — nothing queued")

        let eventsAfterResync = try await eventCount(in: database, batchId: batchId)
        XCTAssertEqual(eventsAfterResync, eventsBeforeResync,
                       "resync must not re-journal — event count unchanged")

        // Every file's tag write eventually landed, and V2 metadata is set.
        let distinctWritten = Set(tagWriter.writtenPaths)
        XCTAssertEqual(distinctWritten, Set(fileIds.map { "/Music/A/\(nameForFileIndex(fileIds, $0))" }),
                       "all three file-tag writes landed after resync")

        let records = try readDatabaseRecords(
            databasePath: seratoDirectory.appendingPathComponent("database V2").path
        )
        XCTAssertEqual(records.compactMap(\.artist).sorted(), ["Artist0", "Artist1", "Artist2"],
                       "database V2 metadata updated for every track after resync")
    }

    private func nameForFileIndex(_ fileIds: [Int64], _ fileId: Int64) -> String {
        let index = fileIds.firstIndex(of: fileId)!
        return ["one.mp3", "two.mp3", "three.mp3"][index]
    }

    // MARK: - #836: Hygiene / importer event types (metadataCommittedToSerato + fileTagsWritten)

    /// The blast-radius gap: `.externalSyncIncomplete` is universal across
    /// every post-commit external-write failure, but `resyncSeratoForBatch`
    /// must be able to replay the writes for the Hygiene/importer event
    /// types too — otherwise the offered Re-sync returns (0,0) "no changes
    /// to replay" while the writes genuinely did not land.
    func testHygieneStylePartialFailureResyncReplaysMetadataAndTagWrites() async throws {
        let tagWriter = ThrowingTagWriter()
        tagWriter.throwOnCall = 1 // fail the file-tag write
        let (engine, database, seratoDirectory, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        let batchId = "hygiene-partial"
        // A commitMetadataToSerato (→ database-V2 metadata update event)
        // plus a writeFileTags (→ audio file-tag write event): the two
        // Serato-projecting event types the hygiene/importer paths emit.
        let mutations: [TrackMutation] = [
            .commitMetadataToSerato(CommitMetadataToSeratoPayload(
                fileId: fileIds[0],
                metadata: SeratoMetadata(artist: "Hygiene0", title: "Committed0"),
                previousMetadata: SeratoMetadata(artist: "old", title: "old")
            )),
            .writeFileTags(WriteFileTagsPayload(
                fileId: fileIds[1],
                metadata: SeratoMetadata(artist: "Hygiene1", title: "Tagged1"),
                previousMetadata: SeratoMetadata(artist: "old", title: "old")
            )),
        ]

        var caughtBatchId: String?
        do {
            _ = try await engine.applyBatch(mutations, batchId: batchId)
            XCTFail("expected the file-tag write to throw after the DB commit")
        } catch let OperationEngineError.externalSyncIncomplete(failedBatchId, _) {
            caughtBatchId = failedBatchId
        }
        XCTAssertEqual(caughtBatchId, batchId,
                       "Hygiene-path partial failure must surface the batchId too")

        // Both events committed to the DB despite the external failure.
        let committedEvents = try await eventCount(in: database, batchId: batchId)
        XCTAssertEqual(committedEvents, 2)
        // The failed file-tag write genuinely did not land during apply.
        XCTAssertFalse(tagWriter.writtenPaths.contains("/Music/A/two.mp3"),
                       "the file-tag write threw, so it did not land during apply")

        // Recovery must replay BOTH Hygiene event types — not return (0,0).
        tagWriter.throwOnCall = nil
        let outcome = try await engine.resyncSeratoForBatch(batchId)
        XCTAssertEqual(outcome.appliedCount, 2,
                       "both the committed-metadata and file-tags events replay (no (0,0) false promise)")
        XCTAssertEqual(outcome.queuedCount, 0)
        let eventsAfterResync = try await eventCount(in: database, batchId: batchId)
        XCTAssertEqual(eventsAfterResync, committedEvents,
                       "resync must not re-journal Hygiene events either")

        // The previously-missing file-tag write landed on resync, and the
        // committed metadata is present in database V2.
        XCTAssertTrue(tagWriter.writtenPaths.contains("/Music/A/two.mp3"),
                      "the failed file-tag write is replayed by resync")
        let records = try readDatabaseRecords(
            databasePath: seratoDirectory.appendingPathComponent("database V2").path
        )
        let firstRecord = records.first { $0.path == "Music/A/one.mp3" }
        XCTAssertEqual(firstRecord?.artist, "Hygiene0",
                       "committed metadata present in database V2 after the batch + resync")
    }

    // MARK: - #3999974013: resync must not replay a superseded (undone) batch

    /// After a batch is undone, re-syncing that ORIGINAL batch must not replay
    /// its forward writes — they'd resurrect the reverted artist/title/album/
    /// year over the current (reverted) state. Its applied events are
    /// superseded by the later revert events on the same files.
    func testResyncOfUndoneBatchSkipsSupersededForwardWrites() async throws {
        let tagWriter = ThrowingTagWriter() // never throws
        let (engine, _, _, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        let batchId = "auto-tag-then-undone"
        _ = try await engine.applyBatch(matchMutations(fileIds: fileIds), batchId: batchId)
        _ = try await engine.undoBatch(batchId)
        let writesAfterUndo = tagWriter.writtenPaths.count

        let outcome = try await engine.resyncSeratoForBatch(batchId)
        XCTAssertEqual(outcome.appliedCount, 0, "superseded forward writes are skipped")
        XCTAssertEqual(outcome.queuedCount, 0)
        XCTAssertEqual(
            tagWriter.writtenPaths.count, writesAfterUndo,
            "no stale forward tag write is replayed for an undone batch"
        )
    }

    // MARK: - #3999974011: a failed undo restore write is recoverable via resync

    /// If a tag-restore write throws partway through `undoBatch`, the SQLite
    /// revert and its `.musicBrainzMatchReverted` event are already committed;
    /// re-syncing the UNDO batch must replay the missing restore write, so the
    /// file/Serato don't stay stuck with the applied metadata.
    func testUndoRestoreWriteFailureIsRecoverableByResyncingUndoBatch() async throws {
        let tagWriter = ThrowingTagWriter()
        let (engine, _, _, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        let batchId = "auto-tag-recoverable-undo"
        // Apply one match — its file-tag write is call #1 and lands.
        _ = try await engine.applyBatch(matchMutations(fileIds: [fileIds[0]]), batchId: batchId)

        // Fail the undo's restore file-tag write (call #2).
        tagWriter.throwOnCall = 2
        var undoBatchId: String?
        do {
            undoBatchId = try await engine.undoBatch(batchId)
            XCTFail("expected the undo restore write to throw after the DB revert committed")
        } catch let OperationEngineError.externalSyncIncomplete(failedBatchId, _) {
            undoBatchId = failedBatchId
        }
        let resolvedUndoBatchId = try XCTUnwrap(undoBatchId)

        // Recovery: the reverted event is replayable, so re-syncing the undo
        // batch lands the restore write that failed mid-undo.
        tagWriter.throwOnCall = nil
        let outcome = try await engine.resyncSeratoForBatch(resolvedUndoBatchId)
        XCTAssertEqual(outcome.appliedCount, 1, "the reverted event's restore write is replayed")
        XCTAssertEqual(outcome.queuedCount, 0)
    }

    // MARK: - #4000261452: per-projection-target resync supersession

    /// A hygiene batch journals `commitMetadataToSerato` (Serato V2) then
    /// `fileTagsWritten` (audio tag) for the SAME file — different external
    /// stores. Re-sync must replay BOTH; a global "latest metadata event per
    /// file wins" wrongly treats the later tag event as superseding the earlier
    /// V2 event and permanently drops the V2 re-sync.
    func testResyncReplaysBothV2AndTagForSameFileHygieneBatch() async throws {
        let tagWriter = ThrowingTagWriter() // never throws
        let (engine, _, seratoDirectory, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        let batchId = "hygiene-same-file"
        let mutations: [TrackMutation] = [
            .commitMetadataToSerato(CommitMetadataToSeratoPayload(
                fileId: fileIds[0],
                metadata: SeratoMetadata(artist: "H0", title: "Committed0"),
                previousMetadata: SeratoMetadata(artist: "old", title: "old")
            )),
            .writeFileTags(WriteFileTagsPayload(
                fileId: fileIds[0],
                metadata: SeratoMetadata(artist: "H0", title: "Tagged0"),
                previousMetadata: SeratoMetadata(artist: "old", title: "old")
            )),
        ]
        _ = try await engine.applyBatch(mutations, batchId: batchId)

        let outcome = try await engine.resyncSeratoForBatch(batchId)
        XCTAssertEqual(
            outcome.appliedCount, 2,
            "both the V2-metadata and file-tag events replay; the later tag event must not suppress the V2 one"
        )
        XCTAssertEqual(outcome.queuedCount, 0)

        let records = try readDatabaseRecords(
            databasePath: seratoDirectory.appendingPathComponent("database V2").path
        )
        let record = records.first { $0.path == "Music/A/one.mp3" }
        XCTAssertEqual(record?.artist, "H0", "V2 metadata present after resync (not dropped as superseded)")
        XCTAssertTrue(tagWriter.writtenPaths.contains("/Music/A/one.mp3"), "the file-tag write replayed too")
    }

    // MARK: - #104 reground: resync ranks by ACTUAL writes, not event type

    /// A later year-only re-match of a file produces NO Serato-V2 write (only a
    /// file-tag write). Re-syncing the EARLIER full match's batch must still
    /// replay that batch's V2 metadata — it is the file's current V2 state,
    /// since the later match didn't touch V2. Ranking supersession by event
    /// TYPE (both are musicBrainzMatchApplied) would wrongly drop it.
    func testResyncKeepsEarlierV2WhenLaterMatchTouchesOnlyTheTag() async throws {
        let tagWriter = ThrowingTagWriter() // never throws
        let (engine, _, seratoDirectory, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        let fingerprint = sha256(Data("shared-fp".utf8))
        let file = fileIds[0]

        // Batch A: a full match — writes V2 metadata (Nas/…/Illmatic) + tag.
        try await engine.applyBatch(
            [.applyMusicBrainzMatch(ApplyMusicBrainzMatchPayload(
                fileID: file, acoustID: "aid", recordingMBID: "recA", releaseMBID: "relA",
                artistMBID: "art", isrc: "isrc", fingerprintHash: fingerprint,
                expectedFileSize: 1, expectedMtime: 1,
                artist: "Nas", title: "N.Y. State of Mind", album: "Illmatic", year: 1994
            ))],
            batchId: "batchA"
        )
        // Batch B (later): a YEAR-ONLY re-match of the same file — no V2 write.
        try await engine.applyBatch(
            [.applyMusicBrainzMatch(ApplyMusicBrainzMatchPayload(
                fileID: file, acoustID: "aid", recordingMBID: "recA", releaseMBID: "relA",
                artistMBID: "art", isrc: "isrc", fingerprintHash: fingerprint,
                expectedFileSize: 1, expectedMtime: 1,
                artist: nil, title: nil, album: nil, year: 1995
            ))],
            batchId: "batchB"
        )

        // Re-sync batch A: its V2 metadata must replay (A is the latest event
        // that actually produced a V2 write — B produced none).
        let outcome = try await engine.resyncSeratoForBatch("batchA")
        XCTAssertEqual(outcome.appliedCount, 1, "A's V2 metadata write still replays")

        let records = try readDatabaseRecords(
            databasePath: seratoDirectory.appendingPathComponent("database V2").path
        )
        let record = records.first { $0.path == "Music/A/one.mp3" }
        XCTAssertEqual(
            record?.artist, "Nas",
            "the earlier full match's V2 metadata is current (the later year-only match didn't touch V2) and must survive resync"
        )
    }

    // MARK: - Regression: full success

    func testFullySuccessfulBatchJournalsOnceAndDoesNotThrow() async throws {
        let tagWriter = ThrowingTagWriter() // never throws
        let (engine, database, _, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        let batchId = "auto-tag-ok"
        let eventIds = try await engine.applyBatch(matchMutations(fileIds: fileIds), batchId: batchId)
        XCTAssertEqual(eventIds.count, 3)

        let events = try await eventCount(in: database, batchId: batchId)
        XCTAssertEqual(events, 3, "exactly one event per match — journaled once")
        XCTAssertEqual(Set(tagWriter.writtenPaths).count, 3, "every file tagged")
    }

    // MARK: - C2b: metadata coalescing

    func testBatchCoalescesMetadataIntoSingleDatabaseV2Rewrite() async throws {
        let tagWriter = ThrowingTagWriter() // never throws
        let metadataSpy = MetadataBatchWriterSpy()
        let (engine, database, seratoDirectory, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter, metadataSpy: metadataSpy)
        }
        let batchId = "auto-tag-coalesce"
        _ = try await engine.applyBatch(matchMutations(fileIds: fileIds), batchId: batchId)

        XCTAssertEqual(metadataSpy.callCount, 1,
                       "a 3-row apply must coalesce into ONE database V2 read/rewrite pass, not 3")

        // The single pass still updated every track's metadata.
        let records = try readDatabaseRecords(
            databasePath: seratoDirectory.appendingPathComponent("database V2").path
        )
        XCTAssertEqual(records.compactMap(\.album).sorted(), ["Album0", "Album1", "Album2"])

        let events = try await eventCount(in: database, batchId: batchId)
        XCTAssertEqual(events, 3)
    }

    // MARK: - Serato-running path unchanged

    func testSeratoRunningQueuesBatchWritesWithoutRewritingOrThrowing() async throws {
        let tagWriter = ThrowingTagWriter()
        let metadataSpy = MetadataBatchWriterSpy()
        let (engine, _, _, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter, metadataSpy: metadataSpy, seratoIsRunning: true)
        }
        // Must NOT throw and must NOT touch disk while Serato runs.
        _ = try await engine.applyBatch(matchMutations(fileIds: fileIds), batchId: "auto-tag-running")

        XCTAssertEqual(metadataSpy.callCount, 0, "no V2 rewrite while Serato is running")
        XCTAssertEqual(tagWriter.writtenPaths.count, 0, "no file-tag writes while Serato is running")
        let queueDepth = await engine.pendingSeratoWriteCount
        XCTAssertEqual(queueDepth, 6, "3 metadata updates + 3 file-tag writes queued")
    }
}
