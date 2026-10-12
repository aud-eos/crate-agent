@testable import CrateAgent
import CryptoKit
import GRDB
import SQLite3
import XCTest

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
    func testLargeHygieneResyncChunksRealSQLiteQueriesAndPreservesOwners() async throws {
        let (engine, database, directory, _) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: ThrowingTagWriter(), seratoIsRunning: true)
        }
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let fileIDs = try await database.writer.write { db in
            try (0 ..< 1100).map { index in
                var file = FileRecord(path: "/large/\(index).mp3", volumeUuid: "large", inode: Int64(index), fileSize: 1, mtime: 1)
                file.libraryMembership = .active
                file.fileAvailability = .available
                try file.insert(db)
                return try XCTUnwrap(file.id)
            }
        }
        let mutations = fileIDs.flatMap { fileID in [
            TrackMutation.commitMetadataToSerato(CommitMetadataToSeratoPayload(fileId: fileID, metadata: SeratoMetadata(artist: "Artist"))),
            .writeFileTags(WriteFileTagsPayload(fileId: fileID, metadata: SeratoMetadata(title: "Original"))),
        ] }
        _ = try await engine.applyBatch(mutations, batchId: "large-hygiene")
        _ = try await engine.applyBatch([XCTUnwrap(fileIDs.first), XCTUnwrap(fileIDs.last)].map { fileID in
            .writeFileTags(WriteFileTagsPayload(fileId: fileID, metadata: SeratoMetadata(title: "Newer")))
        }, batchId: "newer-tags")
        try await database.writer.write { db in
            _ = sqlite3_limit(db.sqliteConnection, SQLITE_LIMIT_VARIABLE_NUMBER, 1000)
            XCTAssertEqual(sqlite3_limit(db.sqliteConnection, SQLITE_LIMIT_VARIABLE_NUMBER, -1), 1000)
        }
        let before = try await eventCount(in: database, batchId: "large-hygiene")
        let outcome = try await engine.resyncSeratoForBatch("large-hygiene")
        XCTAssertEqual(outcome.queuedCount, 2198)
        XCTAssertEqual(outcome.appliedCount, 0)
        let after = try await eventCount(in: database, batchId: "large-hygiene")
        XCTAssertEqual(after, before)
    }

    func testResyncRejectsMalformedReplayablePayloadsBeforeWriting() async throws {
        for eventType in [EventType.fileRenamed, .musicBrainzMatchApplied, .musicBrainzMatchReverted,
                          .metadataCommittedToSerato, .fileTagsWritten]
        {
            for malformedPayload in ["{", "{}"] {
                let tagWriter = ThrowingTagWriter()
                let (engine, database, directory, fileIDs) = try await MainActor.run {
                    try makeEngineWithLibrary(tagWriter: tagWriter)
                }
                defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
                let databasePath = directory.appendingPathComponent("database V2")
                let originalBytes = try Data(contentsOf: databasePath)
                let eventID = try await database.writer.write { db in
                    var event = EventRecord(batchId: "broken", timestamp: 1, fileId: fileIDs[0],
                                            eventType: eventType, payloadJson: malformedPayload, inversePayloadJson: "{}")
                    try event.insert(db)
                    return event.eventId!
                }
                await XCTAssertThrowsErrorAsync(try await engine.resyncSeratoForBatch("broken")) { error in
                    XCTAssertTrue(error.localizedDescription.contains("broken"))
                    XCTAssertTrue(error.localizedDescription.contains(String(eventID)))
                    XCTAssertTrue(error.localizedDescription.contains(eventType.rawValue))
                }
                XCTAssertEqual(try Data(contentsOf: databasePath), originalBytes)
                XCTAssertTrue(tagWriter.writtenPaths.isEmpty)
            }
        }
    }

    func testResyncRejectsMalformedOwnershipHistoryBeforeWriting() async throws {
        let tagWriter = ThrowingTagWriter()
        let (engine, database, directory, fileIDs) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        _ = try await engine.applyBatch(matchMutations(fileIds: [fileIDs[0]]), batchId: "valid")
        let originalPaths = tagWriter.writtenPaths
        try await database.writer.write { db in
            var event = EventRecord(batchId: "broken-owner", timestamp: 2, fileId: fileIDs[0],
                                    eventType: .metadataSet, payloadJson: "{", inversePayloadJson: "{}")
            try event.insert(db)
        }
        await XCTAssertThrowsErrorAsync(try await engine.resyncSeratoForBatch("valid")) { error in
            XCTAssertTrue(error.localizedDescription.contains("broken-owner"))
            XCTAssertTrue(error.localizedDescription.contains(EventType.metadataSet.rawValue))
        }
        XCTAssertEqual(tagWriter.writtenPaths, originalPaths)
    }

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

    private let audioRoot = FileManager.default.temporaryDirectory.appendingPathComponent("owned-engine-audio-\(UUID().uuidString)")
    private var seratoPaths: [String] {
        ["one.mp3", "two.mp3", "three.mp3"].map { SeratoLibraryLocator.seratoRelativePath(fromAbsolute: audioRoot.appendingPathComponent($0).path) }
    }

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
        let rootDirectory = audioRoot
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
                let path = "/\(seratoPath)"
                try Data([UInt8(index)]).write(to: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: path)
                let identity = try FileMetadataCollector.collectVerified(at: path)
                var file = FileRecord(
                    path: path, volumeUuid: identity.volumeUuid, inode: identity.inode,
                    fileSize: identity.fileSize, mtime: identity.mtime, lightweightHash: identity.lightweightHash, artist: "old", title: "old", album: "old"
                )
                file.libraryMembership = .active
                file.fileAvailability = .available
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
        XCTAssertEqual(distinctWritten, Set(fileIds.map { audioRoot.appendingPathComponent(nameForFileIndex(fileIds, $0)).path }),
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
        XCTAssertFalse(tagWriter.writtenPaths.contains("/\(seratoPaths[1])"),
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
        XCTAssertTrue(tagWriter.writtenPaths.contains("/\(seratoPaths[1])"),
                      "the failed file-tag write is replayed by resync")
        let records = try readDatabaseRecords(
            databasePath: seratoDirectory.appendingPathComponent("database V2").path
        )
        let firstRecord = records.first { $0.path == seratoPaths[0] }
        XCTAssertEqual(firstRecord?.artist, "Hygiene0",
                       "committed metadata present in database V2 after the batch + resync")
    }

    // MARK: - #3999974013: resync must not replay a superseded (undone) batch

    /// After a batch is undone, re-syncing that ORIGINAL batch must not replay
    /// its forward writes — they'd resurrect the reverted artist/title/album/
    /// year over the current (reverted) state. Its applied events are
    /// superseded by the later revert events on the same files.
    func testHygieneUndoLocalSnapshotDoesNotSuppressV2Recovery() async throws {
        try await assertHygieneUndoV2Recovery(legacyJournal: false)
    }

    func testLegacyHygieneUndoLocalSnapshotDoesNotSuppressV2Recovery() async throws {
        try await assertHygieneUndoV2Recovery(legacyJournal: true)
    }

    private func stripMetadataAuthority(in database: LibraryDatabase) async throws {
        try await database.writer.write { db in
            let events = try EventRecord.filter(Column("event_type") == EventType.metadataSet.rawValue).fetchAll(db)
            for event in events {
                let eventID = try XCTUnwrap(event.eventId)
                var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.payloadJson.utf8)) as? [String: Any])
                payload.removeValue(forKey: "isSeratoAuthoritative")
                var inverse = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.inversePayloadJson.utf8)) as? [String: Any])
                inverse.removeValue(forKey: "isSeratoAuthoritative")
                let payloadJSON = try String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                let inverseJSON = try String(decoding: JSONSerialization.data(withJSONObject: inverse), as: UTF8.self)
                try db.execute(sql: "UPDATE events SET payload_json = ?, inverse_payload_json = ? WHERE event_id = ?",
                               arguments: [payloadJSON, inverseJSON, eventID])
            }
        }
    }

    private func assertHygieneUndoV2Recovery(legacyJournal: Bool) async throws {
        let tagWriter = ThrowingTagWriter()
        let (engine, database, seratoDirectory, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        let fileID = fileIds[0]
        let original = SeratoMetadata(artist: "old", title: "old", album: "old")
        let edited = SeratoMetadata(artist: "Edited", title: "Edited title", album: "old")
        let batchID = "hygiene-undo-v2-recovery"
        _ = try await engine.applyBatch([
            .setMetadata(SetMetadataPayload(fileId: fileID, metadata: edited)),
            .commitMetadataToSerato(CommitMetadataToSeratoPayload(fileId: fileID, metadata: edited, previousMetadata: original)),
            .writeFileTags(WriteFileTagsPayload(fileId: fileID, metadata: edited, previousMetadata: original)),
        ], batchId: batchID)
        let databaseURL = seratoDirectory.appendingPathComponent("database V2")
        let appliedBytes = try Data(contentsOf: databaseURL)
        if legacyJournal {
            try await stripMetadataAuthority(in: database)
        }
        try Data([0xFF, 0xFF, 0xFF]).write(to: databaseURL)
        var undoID: String?
        do {
            _ = try await engine.undoBatch(batchID)
            XCTFail("corrupt V2 must fail the real undo writer")
        } catch let OperationEngineError.externalSyncIncomplete(failedBatchID, _) {
            undoID = failedBatchID
        }
        let undoBatchID = try XCTUnwrap(undoID)
        let restored = try await database.writer.read { db in try FileRecord.fetchOne(db, key: fileID) }
        XCTAssertEqual(restored?.artist, "old")
        try appliedBytes.write(to: databaseURL)
        if legacyJournal {
            try await stripMetadataAuthority(in: database)
        }
        _ = try await engine.resyncSeratoForBatch(undoBatchID)
        let records = try readDatabaseRecords(databasePath: databaseURL.path)
        let record = try XCTUnwrap(records.first { $0.path == seratoPaths[0] })
        XCTAssertEqual(record.artist, "old")
        XCTAssertEqual(record.title, "old")
    }

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
        let record = records.first { $0.path == seratoPaths[0] }
        XCTAssertEqual(record?.artist, "H0", "V2 metadata present after resync (not dropped as superseded)")
        XCTAssertTrue(tagWriter.writtenPaths.contains("/\(seratoPaths[0])"), "the file-tag write replayed too")
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
        let record = records.first { $0.path == seratoPaths[0] }
        XCTAssertEqual(
            record?.artist, "Nas",
            "the earlier full match's V2 metadata is current (the later year-only match didn't touch V2) and must survive resync"
        )
    }

    // MARK: - #4000405427: undo restores V2 from the DB snapshot, tag from disk

    /// When Serato's snapshot (`FileRecord`/database V2) and the embedded file
    /// tag disagreed before a match, undo must send the DB snapshot back to
    /// database V2 (matching the restored SQLite row) and the on-disk snapshot
    /// back to the audio file — not share one snapshot for both, which left
    /// Serato and the sidecar DB inconsistent after undo.
    func testUndoRestoresDatabaseV2FromDbSnapshotNotOnDiskTag() async throws {
        let tagWriter = ThrowingTagWriter() // never throws
        let (engine, _, seratoDirectory, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        // The harness seeds the DB row artist = "old"; the file's embedded tag
        // (captured into the payload) differs.
        let file = fileIds[0]
        try await engine.applyBatch(
            [.applyMusicBrainzMatch(ApplyMusicBrainzMatchPayload(
                fileID: file, acoustID: "aid", recordingMBID: "recA", releaseMBID: "relA",
                artistMBID: "art", isrc: "isrc", fingerprintHash: sha256(Data("fp".utf8)),
                expectedFileSize: 1, expectedMtime: 1,
                artist: "New Artist", title: nil, album: nil, year: nil,
                currentFileArtist: "Disk Artist"
            ))],
            batchId: "batchA"
        )

        try await engine.undoBatch("batchA")

        let records = try readDatabaseRecords(
            databasePath: seratoDirectory.appendingPathComponent("database V2").path
        )
        let record = records.first { $0.path == seratoPaths[0] }
        XCTAssertEqual(
            record?.artist, "old",
            "undo must restore database V2 from the DB snapshot (\"old\"), not the on-disk tag (\"Disk Artist\")"
        )
    }

    // MARK: - #4000806481: resync supersession is per FIELD, not per target

    /// Batch A writes only `title`, a later batch B writes only `artist` to the
    /// same file. B does not supersede A's title (different field), so re-syncing
    /// A still replays its title — per-target ranking would have dropped A's
    /// whole write because B is the newer metadata event.
    func testResyncKeepsEarlierFieldWhenLaterBatchWritesADifferentField() async throws {
        let tagWriter = ThrowingTagWriter() // never throws
        let (engine, _, seratoDirectory, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        let file = fileIds[0]

        try await engine.applyBatch(
            [.commitMetadataToSerato(CommitMetadataToSeratoPayload(
                fileId: file, metadata: SeratoMetadata(title: "A Title"),
                previousMetadata: SeratoMetadata(title: "old")
            ))],
            batchId: "batchA"
        )
        try await engine.applyBatch(
            [.commitMetadataToSerato(CommitMetadataToSeratoPayload(
                fileId: file, metadata: SeratoMetadata(artist: "B Artist"),
                previousMetadata: SeratoMetadata(artist: "old")
            ))],
            batchId: "batchB"
        )

        // Re-syncing A must still replay its title field (B only touched artist).
        let outcome = try await engine.resyncSeratoForBatch("batchA")
        XCTAssertEqual(outcome.appliedCount, 1, "A's title field is still current and must replay")

        let records = try readDatabaseRecords(
            databasePath: seratoDirectory.appendingPathComponent("database V2").path
        )
        let record = records.first { $0.path == seratoPaths[0] }
        XCTAssertEqual(record?.title, "A Title", "A's title survives B's artist-only write")
    }

    // MARK: - #4001251164: a later Serato import supersedes an older match's V2 field

    /// A user edits a field directly in Serato after an Auto-Tag batch; the
    /// scanner imports that newer value as a `.metadataSet` event. Re-syncing
    /// the older match must NOT re-write its stale value over the user's newer
    /// Serato edit — the import is the latest OWNER of that database-V2 field
    /// even though it emits no outbound write of its own. (The match keeps
    /// ownership of the audio-TAG field, which a Serato edit doesn't touch, so
    /// the tag write still replays — only the V2 field is dropped.)
    func testResyncDropsMatchV2FieldSupersededByLaterSeratoImport() async throws {
        let tagWriter = ThrowingTagWriter() // never throws
        let (engine, _, seratoDirectory, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        let file = fileIds[0]
        let databaseV2Path = seratoDirectory.appendingPathComponent("database V2").path

        // Batch A: a match writes artist "Nas" to database V2 (and the tag).
        try await engine.applyBatch(
            [.applyMusicBrainzMatch(ApplyMusicBrainzMatchPayload(
                fileID: file, acoustID: "aid", recordingMBID: "recA", releaseMBID: "relA",
                artistMBID: "art", isrc: "isrc", fingerprintHash: sha256(Data("fp".utf8)),
                expectedFileSize: 1, expectedMtime: 1,
                artist: "Nas", title: nil, album: nil, year: nil
            ))],
            batchId: "batchA"
        )

        // The user then edits the artist directly in Serato → database V2 now
        // holds "User Edit"; the scanner imports that as a `.metadataSet` event.
        _ = try batchUpdateDatabaseRecords(
            databasePath: databaseV2Path,
            updates: [SeratoTrackMetadataUpdate(
                trackPath: seratoPaths[0],
                update: SeratoMetadataUpdate(
                    artist: "User Edit", title: nil, album: nil, genre: nil, bpm: nil,
                    key: nil, comment: nil, length: nil, label: nil
                )
            )]
        )
        try await engine.apply(
            .setMetadata(SetMetadataPayload(fileId: file, metadata: SeratoMetadata(artist: "User Edit"), isSeratoAuthoritative: true)),
            batchId: "seratoImport"
        )

        // Re-syncing batch A must NOT overwrite the user's newer V2 artist with
        // the stale match value: the later import owns that field.
        _ = try await engine.resyncSeratoForBatch("batchA")

        let records = try readDatabaseRecords(databasePath: databaseV2Path)
        let record = records.first { $0.path == seratoPaths[0] }
        XCTAssertEqual(
            record?.artist, "User Edit",
            "the user's newer in-Serato edit (imported as .metadataSet) must survive — resync must not clobber it with the stale match artist"
        )
    }

    /// A `.metadataSet` claims ownership only of the fields it actually CHANGED,
    /// not every field in its snapshot. The scanner imports a FULL V2 snapshot
    /// when any one field drifts, so a user editing ONLY artist in Serato must
    /// not let the import strip the older match's ownership of the co-imported,
    /// unchanged title — otherwise a later V2 clobber of that title could never
    /// be restored by re-syncing the match (independent-review concern on
    /// #4001251164).
    func testResyncStillRestoresCoImportedFieldNotChangedByLaterSeratoImport() async throws {
        let tagWriter = ThrowingTagWriter() // never throws
        let (engine, _, seratoDirectory, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        let file = fileIds[0]
        let databaseV2Path = seratoDirectory.appendingPathComponent("database V2").path

        // Batch A: a match writes artist "Nas" and title "NY State" to V2.
        try await engine.applyBatch(
            [.applyMusicBrainzMatch(ApplyMusicBrainzMatchPayload(
                fileID: file, acoustID: "aid", recordingMBID: "recA", releaseMBID: "relA",
                artistMBID: "art", isrc: "isrc", fingerprintHash: sha256(Data("fp".utf8)),
                expectedFileSize: 1, expectedMtime: 1,
                artist: "Nas", title: "NY State", album: nil, year: nil
            ))],
            batchId: "batchA"
        )

        // The user edits ONLY the artist in Serato. The scanner imports the full
        // V2 snapshot (artist changed, title unchanged) as one `.metadataSet`;
        // applySetMetadata captures previousMetadata from the post-match row, so
        // only artist differs.
        try await engine.apply(
            .setMetadata(SetMetadataPayload(
                fileId: file,
                metadata: SeratoMetadata(artist: "User Edit", title: "NY State"), isSeratoAuthoritative: true
            )),
            batchId: "seratoImport"
        )

        // Serato then clobbers the title in V2 (running-write loss / reimport).
        _ = try batchUpdateDatabaseRecords(
            databasePath: databaseV2Path,
            updates: [SeratoTrackMetadataUpdate(
                trackPath: seratoPaths[0],
                update: SeratoMetadataUpdate(
                    artist: "User Edit", title: "CLOBBERED", album: nil, genre: nil, bpm: nil,
                    key: nil, comment: nil, length: nil, label: nil
                )
            )]
        )

        // Re-syncing batch A must restore the title (the match still owns it —
        // the import only changed artist) while leaving the user's artist edit.
        _ = try await engine.resyncSeratoForBatch("batchA")

        let records = try readDatabaseRecords(databasePath: databaseV2Path)
        let record = records.first { $0.path == seratoPaths[0] }
        XCTAssertEqual(
            record?.title, "NY State",
            "the match still owns the co-imported title the user never edited, so resync restores it after a clobber"
        )
        XCTAssertEqual(
            record?.artist, "User Edit",
            "the user's edited artist is owned by the import and is not overwritten"
        )
    }

    /// A CLEAR in Serato (a field going from a value to absent) must also claim
    /// V2 ownership. `metadataFieldMap` drops nils, so a cleared field is absent
    /// from the import's `metadata`; comparing over the UNION of old+new keys is
    /// what lets the value→nil transition supersede the older match — otherwise
    /// re-syncing the batch restores the value the user deliberately cleared
    /// (finding #4001407067).
    func testResyncDoesNotRestoreFieldClearedByLaterSeratoImport() async throws {
        let tagWriter = ThrowingTagWriter() // never throws
        let (engine, _, seratoDirectory, fileIds) = try await MainActor.run {
            try makeEngineWithLibrary(tagWriter: tagWriter)
        }
        let file = fileIds[0]
        let databaseV2Path = seratoDirectory.appendingPathComponent("database V2").path

        // Batch A: a match writes artist "Nas" to V2 (title/album untouched).
        try await engine.applyBatch(
            [.applyMusicBrainzMatch(ApplyMusicBrainzMatchPayload(
                fileID: file, acoustID: "aid", recordingMBID: "recA", releaseMBID: "relA",
                artistMBID: "art", isrc: "isrc", fingerprintHash: sha256(Data("fp".utf8)),
                expectedFileSize: 1, expectedMtime: 1,
                artist: "Nas", title: nil, album: nil, year: nil
            ))],
            batchId: "batchA"
        )

        // The user CLEARS the artist in Serato; the scanner imports the snapshot
        // (artist now absent). applySetMetadata captures previousMetadata from
        // the post-match row, so artist transitions "Nas" → nil.
        try await engine.apply(
            .setMetadata(SetMetadataPayload(
                fileId: file,
                metadata: SeratoMetadata(artist: nil, title: "old", album: "old"), isSeratoAuthoritative: true
            )),
            batchId: "seratoImport"
        )

        // The clear reaches V2 (artist emptied there too).
        _ = try batchUpdateDatabaseRecords(
            databasePath: databaseV2Path,
            updates: [SeratoTrackMetadataUpdate(
                trackPath: seratoPaths[0],
                update: SeratoMetadataUpdate(
                    artist: "", title: nil, album: nil, genre: nil, bpm: nil,
                    key: nil, comment: nil, length: nil, label: nil
                )
            )]
        )

        // Re-syncing batch A must NOT restore the cleared artist: the later
        // import (the clear) owns the field.
        _ = try await engine.resyncSeratoForBatch("batchA")

        let records = try readDatabaseRecords(databasePath: databaseV2Path)
        let record = records.first { $0.path == seratoPaths[0] }
        XCTAssertTrue(
            record?.artist == "" || record?.artist == nil,
            "the user's clear must survive as cleared — resync must not restore the match's artist (was \(String(describing: record?.artist)))"
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
