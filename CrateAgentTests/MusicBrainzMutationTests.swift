@testable import CrateAgent
import CryptoKit
import GRDB
import XCTest

/// The correctness core for SP-2: the `applyMusicBrainzMatch` mutation
/// and its full inverse. Every state change routes through
/// `OperationEngine.applyMutation` (invariant #1), writes a journal
/// event with a forward + inverse payload (invariant #2), gates Serato
/// library writes on the watchdog (invariant #3), and keys the canonical
/// `tracks` row by Chromaprint fingerprint hash (invariant #4).
final class MusicBrainzMutationTests: XCTestCase {
    /// Captures `fileTagWriter` invocations so tests can assert exactly
    /// what would be written to (or restored on) disk, including the
    /// year field that only reaches the file-tag path.
    private final class FileTagWriterRecorder: @unchecked Sendable {
        struct Call: Sendable, Equatable {
            let path: String
            let update: AudioTagUpdate
        }

        private let lock = NSLock()
        private var storedCalls: [Call] = []
        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return storedCalls
        }

        func record(_ path: String, _ update: AudioTagUpdate) {
            lock.lock(); defer { lock.unlock() }
            storedCalls.append(Call(path: path, update: update))
        }
    }

    private let sampleFingerprintBytes = Data("chromaprint-sample-fingerprint".utf8)

    private func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    @MainActor
    private func makeEngine(
        recorder: FileTagWriterRecorder,
        seratoIsRunning: Bool = false
    ) throws -> (OperationEngine, LibraryDatabase) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: {
            seratoIsRunning ? ["com.serato.djpro"] : []
        })
        let locator = SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null"))
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { path, update in recorder.record(path, update) }
        )
        return (engine, database)
    }

    @MainActor
    private func makeEngineWithFile(
        artist: String?,
        title: String?,
        album: String?,
        recorder: FileTagWriterRecorder,
        seratoIsRunning: Bool = false,
        path: String = "/Music/N/track.mp3",
        inode: Int64 = 1
    ) throws -> (OperationEngine, LibraryDatabase, Int64) {
        let (engine, database) = try makeEngine(recorder: recorder, seratoIsRunning: seratoIsRunning)
        let fileId = try database.writer.write { db -> Int64 in
            var file = FileRecord(
                path: path,
                volumeUuid: "v1",
                inode: inode,
                fileSize: 1,
                mtime: 1,
                artist: artist,
                title: title,
                album: album
            )
            try file.insert(db)
            return file.id!
        }
        return (engine, database, fileId)
    }

    private func fullPayload(
        fileID: Int64,
        fingerprintHash: Data,
        artist: String? = "Nas",
        title: String? = "N.Y. State of Mind",
        album: String? = "Illmatic",
        year: Int? = 1994,
        currentFileYear: Int? = nil,
        currentFileArtist: String? = nil,
        currentFileTitle: String? = nil,
        currentFileAlbum: String? = nil,
        recordingMBID: String = "rec",
        releaseMBID: String = "rel",
        // Match `makeEngineWithFile`'s indexed identity so the D-A staleness
        // check passes by default; a stale-candidate test overrides these.
        expectedFileSize: Int64 = 1,
        expectedMtime: Int64 = 1
    ) -> ApplyMusicBrainzMatchPayload {
        ApplyMusicBrainzMatchPayload(
            fileID: fileID,
            acoustID: "aid",
            recordingMBID: recordingMBID,
            releaseMBID: releaseMBID,
            artistMBID: "art",
            isrc: "ISRC123",
            fingerprintHash: fingerprintHash,
            expectedFileSize: expectedFileSize,
            expectedMtime: expectedMtime,
            artist: artist,
            title: title,
            album: album,
            year: year,
            currentFileYear: currentFileYear,
            currentFileArtist: currentFileArtist,
            currentFileTitle: currentFileTitle,
            currentFileAlbum: currentFileAlbum
        )
    }

    // MARK: - Apply

    func testApplyCreatesTrackLinksFileWritesTagsAndEvent() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, fileId) = try await MainActor.run {
            try makeEngineWithFile(artist: "old", title: "old", album: "old", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(fileID: fileId, fingerprintHash: fingerprint)),
            batchId: "apply-1"
        )

        try await database.writer.read { db in
            let file = try FileRecord.fetchOne(db, key: fileId)!
            XCTAssertNotNil(file.trackId, "file must be linked to the canonical track row")
            let track = try TrackRecord.fetchOne(db, key: file.trackId!)!
            XCTAssertEqual(track.fingerprintHash, fingerprint, "track keyed by fingerprint (invariant #4)")
            XCTAssertEqual(track.acoustidId, "aid")
            XCTAssertEqual(track.musicbrainzRecordingId, "rec")
            XCTAssertEqual(track.musicbrainzReleaseId, "rel")
            XCTAssertEqual(track.musicbrainzArtistId, "art")
            XCTAssertEqual(track.isrc, "ISRC123")
            XCTAssertEqual(track.year, 1994)
            XCTAssertEqual(track.artist, "Nas")
            XCTAssertEqual(track.title, "N.Y. State of Mind")
            XCTAssertEqual(track.album, "Illmatic")

            XCTAssertEqual(file.artist, "Nas")
            XCTAssertEqual(file.title, "N.Y. State of Mind")
            XCTAssertEqual(file.album, "Illmatic")

            let event = try EventRecord
                .filter(Column("event_type") == "music_brainz_match_applied")
                .fetchOne(db)
            XCTAssertNotNil(event)
            XCTAssertEqual(event?.trackId, file.trackId, "event carries track_id for per-track history")
            XCTAssertFalse(event!.inversePayloadJson.isEmpty, "inverse payload must be journaled")
            let inverse = try JSONDecoder().decode(
                RevertMusicBrainzMatchPayload.self,
                from: Data(event!.inversePayloadJson.utf8)
            )
            XCTAssertTrue(inverse.applied.createdTrackRow, "forward created the row → inverse knows to null it")
        }

        XCTAssertEqual(recorder.calls.count, 1, "file-tag write dispatched immediately (Serato closed)")
        let update = try XCTUnwrap(recorder.calls.first?.update)
        XCTAssertEqual(update.artist, "Nas")
        XCTAssertEqual(update.title, "N.Y. State of Mind")
        XCTAssertEqual(update.album, "Illmatic")
        XCTAssertEqual(update.year, 1994, "year reaches ONLY the file-tag write (SeratoMetadata has no year)")
    }

    // MARK: - Undo round-trips

    func testUndoRoundTripsNewTrackRow() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, fileId) = try await MainActor.run {
            try makeEngineWithFile(artist: "old", title: "old (Dirty)", album: "old", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        // The file's real embedded tags (D-D): undo restores these to the
        // audio file, not the Serato-imported DB snapshot.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: fileId, fingerprintHash: fingerprint,
                currentFileArtist: "old", currentFileTitle: "old (Dirty)", currentFileAlbum: "old"
            )),
            batchId: "rt-new"
        )
        try await engine.undoBatch("rt-new")

        try await database.writer.read { db in
            let file = try FileRecord.fetchOne(db, key: fileId)!
            XCTAssertEqual(file.title, "old (Dirty)", "exact title restore")
            XCTAssertEqual(file.artist, "old")
            XCTAssertEqual(file.album, "old")
            XCTAssertNil(file.trackId, "link removed on undo")

            // The created row is left orphaned, its identifiers nulled.
            let track = try TrackRecord.filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)
            XCTAssertNotNil(track, "created row is kept (orphaned), not deleted")
            XCTAssertNil(track?.musicbrainzRecordingId)
            XCTAssertNil(track?.isrc)
            XCTAssertNil(track?.year)
            XCTAssertNil(track?.artist)
        }

        // Undo re-issued the file-tag writer with the previous state.
        let lastCall = try XCTUnwrap(recorder.calls.last)
        XCTAssertEqual(lastCall.update.artist, "old")
        XCTAssertEqual(lastCall.update.title, "old (Dirty)")
        XCTAssertEqual(lastCall.update.album, "old")
        // The file had no on-disk year; the match added 1994. Undo must
        // *clear* the added year, not leave it (nil = leave-unchanged).
        XCTAssertNil(lastCall.update.year, "no value to restore — clear instead")
        XCTAssertTrue(lastCall.update.clearYear, "match-added year must be removed on undo")
    }

    /// C1a: a match that adds a field absent before the match (album)
    /// must, on undo, *clear* that field in the audio tags — not leave
    /// the just-applied value in place. nil = leave-unchanged, so undo
    /// must pass an empty string.
    func testUndoClearsFieldAddedFromEmpty() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, _, fileId) = try await MainActor.run {
            try makeEngineWithFile(artist: "old", title: "old", album: nil, recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        // Match adds album where the file had none; artist/title left as-is.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: fileId, fingerprintHash: fingerprint,
                artist: nil, title: nil, album: "Illmatic", year: nil
            )),
            batchId: "add-album"
        )
        try await engine.undoBatch("add-album")

        let undoUpdate = try XCTUnwrap(recorder.calls.last?.update)
        XCTAssertEqual(
            undoUpdate.album, "",
            "album added from empty must be cleared (empty string), not left unchanged (nil)"
        )
        XCTAssertNil(undoUpdate.artist, "artist wasn't written by the match → left unchanged on undo")
        XCTAssertNil(undoUpdate.title, "title wasn't written by the match → left unchanged on undo")
    }

    /// C1a: year restore must come from the file's captured pre-match
    /// on-disk year, for a match that CREATED the track row.
    func testUndoRestoresFileYearForNewTrackRow() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, _, fileId) = try await MainActor.run {
            try makeEngineWithFile(artist: "old", title: "old", album: "old", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        // File was 2001 on disk; match sets 1994.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: fileId, fingerprintHash: fingerprint, year: 1994, currentFileYear: 2001
            )),
            batchId: "year-new"
        )
        try await engine.undoBatch("year-new")

        let undoUpdate = try XCTUnwrap(recorder.calls.last?.update)
        XCTAssertEqual(undoUpdate.year, 2001, "undo restores the file's real pre-match year, not nil/1994")
        XCTAssertFalse(undoUpdate.clearYear, "there was a prior year to restore → not a clear")
    }

    /// C1a: the restored year is the file's captured pre-match year even
    /// when a pre-existing track row carries a *different* `tracks.year`
    /// — proving the source is the file, not the track row (invariant #4).
    func testUndoRestoresFileYearIndependentOfTrackRow() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, fileId) = try await MainActor.run {
            try makeEngineWithFile(artist: "old", title: "old", album: "old", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        // Pre-existing canonical row whose year (2000) differs from the
        // file's on-disk year (2001).
        try await database.writer.write { db in
            var track = TrackRecord(
                fingerprintHash: fingerprint,
                musicbrainzRecordingId: "orig-rec",
                artist: "OrigArtist", year: 2000
            )
            try track.insert(db)
            try db.execute(
                sql: "UPDATE files SET track_id = ? WHERE id = ?",
                arguments: [track.id!, fileId]
            )
        }

        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: fileId, fingerprintHash: fingerprint, year: 1994, currentFileYear: 2001
            )),
            batchId: "year-pre"
        )
        try await engine.undoBatch("year-pre")

        let undoUpdate = try XCTUnwrap(recorder.calls.last?.update)
        XCTAssertEqual(
            undoUpdate.year, 2001,
            "restore the file's captured year (2001), not the track row's year (2000)"
        )
        XCTAssertFalse(undoUpdate.clearYear)
    }

    func testUndoRoundTripsPreexistingTrackRow() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, fileId) = try await MainActor.run {
            try makeEngineWithFile(artist: "origA", title: "origT", album: "origAl", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)

        // Seed a pre-existing canonical track row with original identity,
        // and link the file to it.
        let seededTrackId = try await database.writer.write { db -> Int64 in
            var track = TrackRecord(
                fingerprintHash: fingerprint,
                acoustidId: "orig-aid",
                musicbrainzRecordingId: "orig-rec",
                musicbrainzReleaseId: "orig-rel",
                musicbrainzArtistId: "orig-art",
                isrc: "orig-isrc",
                artist: "OrigArtist",
                title: "OrigTitle",
                album: "OrigAlbum",
                year: 2000
            )
            try track.insert(db)
            let trackId = track.id!
            try db.execute(
                sql: "UPDATE files SET track_id = ? WHERE id = ?",
                arguments: [trackId, fileId]
            )
            return trackId
        }

        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(fileID: fileId, fingerprintHash: fingerprint)),
            batchId: "rt-pre"
        )
        try await database.writer.read { db in
            let track = try TrackRecord.fetchOne(db, key: seededTrackId)!
            XCTAssertEqual(track.musicbrainzRecordingId, "rec", "apply overwrote identity on existing row")
            XCTAssertEqual(track.isrc, "ISRC123")
        }

        try await engine.undoBatch("rt-pre")

        try await database.writer.read { db in
            let trackCount = try TrackRecord.filter(Column("fingerprint_hash") == fingerprint).fetchCount(db)
            XCTAssertEqual(trackCount, 1, "pre-existing row kept, not duplicated")
            let track = try TrackRecord.fetchOne(db, key: seededTrackId)!
            XCTAssertEqual(track.acoustidId, "orig-aid", "identifiers restored")
            XCTAssertEqual(track.musicbrainzRecordingId, "orig-rec")
            XCTAssertEqual(track.musicbrainzReleaseId, "orig-rel")
            XCTAssertEqual(track.musicbrainzArtistId, "orig-art")
            XCTAssertEqual(track.isrc, "orig-isrc")
            XCTAssertEqual(track.year, 2000)
            XCTAssertEqual(track.artist, "OrigArtist")

            let file = try FileRecord.fetchOne(db, key: fileId)!
            XCTAssertEqual(file.trackId, seededTrackId, "file link restored to the seeded row")
            XCTAssertEqual(file.artist, "origA")
            XCTAssertEqual(file.title, "origT")
            XCTAssertEqual(file.album, "origAl")
        }
    }

    // MARK: - C1b: undo must not clobber a later batch's match

    /// Two files are FLAC+MP3 of one recording (same fingerprint, SAME
    /// recording → one track row, invariant #4). Batch A creates the row;
    /// a LATER batch B adopts it (same recording, so identity doesn't
    /// drift). Undoing A must not null the row B now depends on — only the
    /// reference count reveals B's dependency. (A DIFFERENT-recording B on
    /// the same fingerprint is a collision, rejected outright — see
    /// `testDifferentRecordingOnSharedFingerprintIsRejected`.)
    func testUndoCreatedRowDoesNotClobberLaterBatchOnSameFingerprint() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(
                artist: "a1", title: "t1", album: "al1",
                recorder: recorder, path: "/Music/A/one.mp3", inode: 1
            )
        }
        let file2 = try await database.writer.write { db -> Int64 in
            var file = FileRecord(
                path: "/Music/A/two.flac", volumeUuid: "v1", inode: 2,
                fileSize: 1, mtime: 1, artist: "a2", title: "t2", album: "al2"
            )
            try file.insert(db)
            return file.id!
        }
        let fingerprint = sha256(sampleFingerprintBytes)

        // Batch A creates the fingerprint-keyed row.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA"
            )),
            batchId: "batchA"
        )
        // Batch B (later) matches the second file to the same fingerprint
        // and the SAME recording → adopts the row (no identity drift).
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file2, fingerprintHash: fingerprint, recordingMBID: "recA"
            )),
            batchId: "batchB"
        )

        try await engine.undoBatch("batchA")

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertEqual(
                track.musicbrainzRecordingId, "recA",
                "file2 still depends on the row — undo of A must not null it"
            )
            let f2 = try FileRecord.fetchOne(db, key: file2)!
            XCTAssertEqual(f2.trackId, track.id, "file2 still links to the row it depends on")
            let f1 = try FileRecord.fetchOne(db, key: file1)!
            XCTAssertNil(f1.trackId, "the undone file (file1) is unlinked")
        }
    }

    /// The genuinely-solo case still orphans correctly: A created the row,
    /// nothing else references it, identity unchanged → undo nulls it.
    func testUndoSoloCreatedRowStillOrphans() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, fileId) = try await MainActor.run {
            try makeEngineWithFile(artist: "old", title: "old", album: "old", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(fileID: fileId, fingerprintHash: fingerprint)),
            batchId: "solo"
        )
        try await engine.undoBatch("solo")

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertNil(track.musicbrainzRecordingId, "solo orphan row identity nulled")
            XCTAssertNil(track.isrc)
            XCTAssertNil(track.acoustidId)
            XCTAssertNil(try FileRecord.fetchOne(db, key: fileId)!.trackId, "file unlinked")
        }
    }

    /// Pre-existing-row variant: A re-identifies a pre-existing row it
    /// solely owns (no other file references it yet — a legitimate
    /// correction), then a later B adopts the row with the SAME recording.
    /// Undoing A must retain the row B now depends on, not restore A's
    /// captured `previous`.
    func testUndoPreexistingRowDoesNotClobberLaterUpdate() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(
                artist: "a1", title: "t1", album: "al1",
                recorder: recorder, path: "/Music/A/one.mp3", inode: 1
            )
        }
        let file2 = try await database.writer.write { db -> Int64 in
            var file = FileRecord(
                path: "/Music/A/two.flac", volumeUuid: "v1", inode: 2,
                fileSize: 1, mtime: 1, artist: "a2", title: "t2", album: "al2"
            )
            try file.insert(db)
            return file.id!
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        // Seed a pre-existing row (recX) and link file1, so batch A hits
        // the existing-row branch rather than creating a row.
        try await database.writer.write { db in
            var track = TrackRecord(
                fingerprintHash: fingerprint, musicbrainzRecordingId: "recX", artist: "X"
            )
            try track.insert(db)
            try db.execute(
                sql: "UPDATE files SET track_id = ? WHERE id = ?",
                arguments: [track.id!, file1]
            )
        }

        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA"
            )),
            batchId: "batchA"
        )
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file2, fingerprintHash: fingerprint, recordingMBID: "recA"
            )),
            batchId: "batchB"
        )

        try await engine.undoBatch("batchA")

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertEqual(
                track.musicbrainzRecordingId, "recA",
                "undoing A must not restore recX — file2 now depends on recA"
            )
        }
    }

    /// The Critical the drift guard alone misses: duplicates (FLAC+MP3)
    /// resolve to the SAME recording, so when a later batch B re-matches
    /// the shared row to the same MBID, nothing drifts. Only the
    /// reference count reveals that B (via file2) now depends on the row,
    /// so undoing A must still leave the row's identity alone.
    func testUndoPreexistingRowSameRecordingDoesNotClobberLaterBatch() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(
                artist: "a1", title: "t1", album: "al1",
                recorder: recorder, path: "/Music/A/one.mp3", inode: 1
            )
        }
        let file2 = try await database.writer.write { db -> Int64 in
            var file = FileRecord(
                path: "/Music/A/two.flac", volumeUuid: "v1", inode: 2,
                fileSize: 1, mtime: 1, artist: "a2", title: "t2", album: "al2"
            )
            try file.insert(db)
            return file.id!
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        // Pre-existing row (recX), not yet linked to either file, so batch
        // A takes the existing-row branch with previousTrackID == nil.
        try await database.writer.write { db in
            var track = TrackRecord(
                fingerprintHash: fingerprint, musicbrainzRecordingId: "recX", artist: "X"
            )
            try track.insert(db)
        }

        // Batch A: file1 → recA (existing-row branch, previous = recX).
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA"
            )),
            batchId: "batchA"
        )
        // Batch B (later): file2, same fingerprint, SAME recording — no
        // identity drift, but file2 now depends on the row.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file2, fingerprintHash: fingerprint, recordingMBID: "recA"
            )),
            batchId: "batchB"
        )

        try await engine.undoBatch("batchA")

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertEqual(
                track.musicbrainzRecordingId, "recA",
                "same-recording B still references the row — undo A must not restore recX"
            )
            let f2 = try FileRecord.fetchOne(db, key: file2)!
            XCTAssertEqual(f2.trackId, track.id, "file2 still links to the row it depends on")
            let f1 = try FileRecord.fetchOne(db, key: file1)!
            XCTAssertNil(f1.trackId, "the undone file (file1) is unlinked")
        }
    }

    // MARK: - Out-of-order undo is rejected (#3999114450)

    /// The SAME file is matched by batch A, then re-matched by a later batch B
    /// to a DIFFERENT recording (a legitimate self-correction — no other file
    /// references the row, so B is not a collision). Undoing the OLDER batch A
    /// now would relink the file away from B and overwrite B's DB metadata +
    /// on-disk tags. It must be refused loudly, leaving B's match intact, so
    /// the user undoes the newer match first (LIFO).
    func testUndoOfMatchSupersededOnSameFileIsRejected() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(artist: "old", title: "old", album: "old", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)

        // Batch A: file1 → recA.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA"
            )),
            batchId: "batchA"
        )
        // Batch B (later): the SAME file1, re-matched to a DIFFERENT recording.
        // Only file1 references the row, so this is a self-correction, not a
        // collision — it proceeds and moves the row to recB.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recB"
            )),
            batchId: "batchB"
        )

        let writesBeforeUndo = recorder.calls.count
        do {
            try await engine.undoBatch("batchA")
            XCTFail("expected undoSupersededByLaterMatch")
        } catch let OperationEngineError.undoSupersededByLaterMatch(fid) {
            XCTAssertEqual(fid, file1)
        }

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertEqual(track.musicbrainzRecordingId, "recB", "B's current identity must survive the refused undo")
            XCTAssertEqual(try FileRecord.fetchOne(db, key: file1)!.trackId, track.id, "file1 still links to B's row")
            XCTAssertEqual(
                try EventRecord.filter(Column("batch_id").like("undo:batchA%")).fetchCount(db), 0,
                "a refused undo journals nothing"
            )
        }
        XCTAssertEqual(recorder.calls.count, writesBeforeUndo, "a refused undo rewrites no audio tags")
    }

    /// The cross-batch hole a row-state guard can't see: the SAME file is
    /// re-matched by a later batch to the SAME recording but a DIFFERENT
    /// release. At the earlier batch's revert the row looks identical to a
    /// legitimate sibling (recording unchanged, release drifted, no surviving
    /// reference), so only the EVENT LOG distinguishes them. Undoing the older
    /// batch out of order must still be rejected (finding #3999974010 review).
    func testUndoOfSameFileRematchedToSameRecordingDifferentReleaseIsRejected() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(artist: "old", title: "old", album: "old", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)

        // Batch A: file1 → recA / rel1.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA", releaseMBID: "rel1"
            )),
            batchId: "batchA"
        )
        // Batch B (later): the SAME file1, SAME recording recA, DIFFERENT
        // release rel2 — a self-correction the apply-side guard allows.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA", releaseMBID: "rel2"
            )),
            batchId: "batchB"
        )

        do {
            try await engine.undoBatch("batchA")
            XCTFail("expected undoSupersededByLaterMatch")
        } catch let OperationEngineError.undoSupersededByLaterMatch(fid) {
            XCTAssertEqual(fid, file1)
        }

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertEqual(track.musicbrainzReleaseId, "rel2", "B's current release must survive the refused undo")
            XCTAssertEqual(try FileRecord.fetchOne(db, key: file1)!.trackId, track.id, "file1 still linked to B's row")
        }
    }

    /// A REDO (undoing an `undo:` batch, whose events are `musicBrainzMatchReverted`)
    /// must be rejected when the file was matched by a later batch in between —
    /// otherwise it reapplies the stale original over the newer link/tags. The
    /// out-of-order guard must therefore inspect reverted events, not just
    /// applied ones (finding #4000261463).
    func testRedoOfMatchSupersededByLaterBatchIsRejected() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(artist: "old", title: "old", album: "old", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)

        // Batch A: file1 → recA.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA"
            )),
            batchId: "batchA"
        )
        // Undo A → an undo batch of reverted events.
        let undoBatchId = try await engine.undoBatch("batchA")
        // Batch B (later): re-match file1 to a different recording.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recB"
            )),
            batchId: "batchB"
        )

        // Redo A = undo the undo batch. Must be rejected — B now owns file1.
        do {
            try await engine.undoBatch(undoBatchId)
            XCTFail("expected undoSupersededByLaterMatch for the redo")
        } catch let OperationEngineError.undoSupersededByLaterMatch(fid) {
            XCTAssertEqual(fid, file1)
        }

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertEqual(track.musicbrainzRecordingId, "recB", "B's match must survive the refused redo")
        }
    }

    /// Undoing a match on a shared pre-existing row must restore the row's
    /// captured previous identity even when an OLDER file still references it —
    /// that older file's state is exactly what `previousTrackIdentifiers`
    /// restores. Only a genuinely LATER owner blocks restoration (finding
    /// #4000261456).
    func testUndoRestoresSharedRowWhenOnlyAnOlderFileReferencesIt() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(
                artist: "a1", title: "t1", album: "al1",
                recorder: recorder, path: "/Music/A/one.mp3", inode: 1
            )
        }
        let file2 = try await database.writer.write { db -> Int64 in
            var file = FileRecord(
                path: "/Music/A/two.flac", volumeUuid: "v1", inode: 2,
                fileSize: 1, mtime: 1, artist: "a2", title: "t2", album: "al2"
            )
            try file.insert(db)
            return file.id!
        }
        let fingerprint = sha256(sampleFingerprintBytes)

        // Batch A (older): file1 → recA / rel1 creates the row.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA", releaseMBID: "rel1"
            )),
            batchId: "batchA"
        )
        // Batch B: file2 → recA (same recording) / rel2 — adopts the shared row
        // (existing-row branch, previous = rel1) and drifts its release to rel2.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file2, fingerprintHash: fingerprint, recordingMBID: "recA", releaseMBID: "rel2"
            )),
            batchId: "batchB"
        )

        // Undo B. file1 (older) still references the row, but B is the row's
        // latest matcher, so the row must be restored to rel1 (its pre-B state
        // that file1 relies on), not left carrying B's rel2.
        try await engine.undoBatch("batchB")

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertEqual(track.musicbrainzReleaseId, "rel1", "undo B restores the row's pre-B release for the older file")
            XCTAssertEqual(try FileRecord.fetchOne(db, key: file1)!.trackId, track.id, "file1 still references the row")
            XCTAssertNil(try FileRecord.fetchOne(db, key: file2)!.trackId, "the undone file2 is unlinked")
        }
    }

    /// LIFO undo of TWO batches that both adopted a pre-existing shared row must
    /// fully restore it. On the second undo the row is already unlinked and back
    /// at the first batch's identity, but the latest `musicBrainzMatchApplied`
    /// still points at the (now-reverted) later file — so the latest-matcher
    /// test alone would wrongly block restoration. The sole-owner fallback
    /// covers it (finding #4000261456 review).
    func testLifoUndoOfTwoAdoptersFullyRestoresPreexistingRow() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(
                artist: "a1", title: "t1", album: "al1",
                recorder: recorder, path: "/Music/A/one.mp3", inode: 1
            )
        }
        let file2 = try await database.writer.write { db -> Int64 in
            var file = FileRecord(
                path: "/Music/A/two.flac", volumeUuid: "v1", inode: 2,
                fileSize: 1, mtime: 1, artist: "a2", title: "t2", album: "al2"
            )
            try file.insert(db)
            return file.id!
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        // Pre-existing row (recX/relX), not linked to either file, so BOTH
        // matches take the existing-row branch (createdTrackRow == false).
        try await database.writer.write { db in
            var track = TrackRecord(
                fingerprintHash: fingerprint, musicbrainzRecordingId: "recX",
                musicbrainzReleaseId: "relX", artist: "X"
            )
            try track.insert(db)
        }

        // Batch A: file1 → recA/rel1 (previous = recX/relX).
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA", releaseMBID: "rel1"
            )),
            batchId: "batchA"
        )
        // Batch B: file2 → recA/rel2 (previous = recA/rel1).
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file2, fingerprintHash: fingerprint, recordingMBID: "recA", releaseMBID: "rel2"
            )),
            batchId: "batchB"
        )

        // LIFO: undo B, then A.
        try await engine.undoBatch("batchB")
        try await engine.undoBatch("batchA")

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertEqual(track.musicbrainzRecordingId, "recX", "fully undone → row back at the pre-existing recording")
            XCTAssertEqual(track.musicbrainzReleaseId, "relX", "fully undone → row back at the pre-existing release")
            XCTAssertNil(try FileRecord.fetchOne(db, key: file1)!.trackId)
            XCTAssertNil(try FileRecord.fetchOne(db, key: file2)!.trackId)
        }
    }

    /// After the documented LIFO recovery — re-match file, then undo the newer
    /// match — the ORIGINAL match must become undoable again. A later match that
    /// was itself undone leaves applied+reverted rows in the log but is no
    /// longer live, so the out-of-order guard must not treat it as a live
    /// supersession (finding #4000668517).
    func testUndoOfOriginalMatchAllowedAfterLaterMatchUndone() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(artist: "old", title: "old", album: "old", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)

        // Batch A: file1 → recA.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA"
            )),
            batchId: "batchA"
        )
        // Batch B (later): re-match file1 → recB.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recB"
            )),
            batchId: "batchB"
        )
        // LIFO recovery: undo the newer match B first.
        try await engine.undoBatch("batchB")

        // Now A is the current match — undoing it must be ALLOWED (not thrown).
        try await engine.undoBatch("batchA")

        try await database.writer.read { db in
            XCTAssertNil(
                try FileRecord.fetchOne(db, key: file1)!.trackId,
                "after undoing B then A, file1 is unlinked"
            )
        }
    }

    /// A sibling (FLAC+MP3 of ONE recording) matched to a DIFFERENT release
    /// drifts the shared row's `releaseMBID` — but that is NOT a supersession
    /// of the first file's match, so undoing the older batch must SUCCEED
    /// (unlink its file, leave the shared row for the sibling). Guards against
    /// the out-of-order-undo check over-firing on legitimate cherry-picked
    /// identity drift.
    func testUndoOfSiblingWithDifferentReleaseIsNotRejected() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(
                artist: "a1", title: "t1", album: "al1",
                recorder: recorder, path: "/Music/A/one.mp3", inode: 1
            )
        }
        let file2 = try await database.writer.write { db -> Int64 in
            var file = FileRecord(
                path: "/Music/A/two.flac", volumeUuid: "v1", inode: 2,
                fileSize: 1, mtime: 1, artist: "a2", title: "t2", album: "al2"
            )
            try file.insert(db)
            return file.id!
        }
        let fingerprint = sha256(sampleFingerprintBytes)

        // Batch A: file1 → recA, release rel1.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA", releaseMBID: "rel1"
            )),
            batchId: "batchA"
        )
        // Batch B: sibling file2 → SAME recording recA but a DIFFERENT release
        // rel2 (ReleaseSelector picks per file). The shared row's releaseMBID
        // drifts to rel2, so forwardIdentityStillOnRow is false for A — but
        // file2 references the row, so this is a sibling, not a supersession.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file2, fingerprintHash: fingerprint, recordingMBID: "recA", releaseMBID: "rel2"
            )),
            batchId: "batchB"
        )

        // Must NOT throw — a legitimate sibling undo.
        try await engine.undoBatch("batchA")

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertEqual(track.musicbrainzRecordingId, "recA", "the shared row survives for the sibling")
            XCTAssertEqual(track.musicbrainzReleaseId, "rel2", "the sibling's release is not clobbered by A's undo")
            XCTAssertEqual(try FileRecord.fetchOne(db, key: file2)!.trackId, track.id, "file2 still links to the row")
            XCTAssertNil(try FileRecord.fetchOne(db, key: file1)!.trackId, "the undone file1 is unlinked")
        }
    }

    /// A SINGLE batch containing two files that share a fingerprint+recording
    /// but pick different releases must stay undoable (finding #3999974010).
    /// `undoBatch` reverts newest-first, so file2's inverse unlinks it before
    /// file1's inverse runs — dropping the reference count. The undo guard must
    /// key on the RECORDING (unchanged: recA) and not throw on the sibling's
    /// release drift, or the whole batch becomes permanently non-undoable.
    func testUndoOfSingleBatchMultiReleaseDuplicatesSucceeds() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(
                artist: "a1", title: "t1", album: "al1",
                recorder: recorder, path: "/Music/A/one.mp3", inode: 1
            )
        }
        let file2 = try await database.writer.write { db -> Int64 in
            var file = FileRecord(
                path: "/Music/A/two.flac", volumeUuid: "v1", inode: 2,
                fileSize: 1, mtime: 1, artist: "a2", title: "t2", album: "al2"
            )
            try file.insert(db)
            return file.id!
        }
        let fingerprint = sha256(sampleFingerprintBytes)

        // One batch: file1 -> recA/rel1 (creates the row), file2 -> recA/rel2
        // (adopts it, drifting releaseMBID to rel2).
        _ = try await engine.applyBatch(
            [
                .applyMusicBrainzMatch(fullPayload(
                    fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA", releaseMBID: "rel1"
                )),
                .applyMusicBrainzMatch(fullPayload(
                    fileID: file2, fingerprintHash: fingerprint, recordingMBID: "recA", releaseMBID: "rel2"
                )),
            ],
            batchId: "dup"
        )

        // Must NOT throw despite the sibling's release drift + newest-first order.
        try await engine.undoBatch("dup")

        try await database.writer.read { db in
            XCTAssertNil(try FileRecord.fetchOne(db, key: file1)!.trackId, "file1 unlinked by undo")
            XCTAssertNil(try FileRecord.fetchOne(db, key: file2)!.trackId, "file2 unlinked by undo")
        }
    }

    // MARK: - Identity-only confirm schedules no audio-tag write (#3999114458)

    /// When the user keeps every display field (artist/title/album/year all
    /// nil, no year clear) and confirms only the recording identity, the DB
    /// link is still established but NO audio-file write is scheduled — an
    /// empty patch would still rewrite the file (Rust `remove_others(true)`),
    /// bump its mtime, and strip secondary ID3v1/APE tags.
    func testIdentityOnlyConfirmSchedulesNoFileTagWrite() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, fileId) = try await MainActor.run {
            try makeEngineWithFile(artist: "old", title: "old", album: "old", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: fileId, fingerprintHash: fingerprint,
                artist: nil, title: nil, album: nil, year: nil
            )),
            batchId: "identity-only"
        )

        XCTAssertEqual(recorder.calls.count, 0, "identity-only confirm must not rewrite the audio file")

        try await database.writer.read { db in
            let file = try FileRecord.fetchOne(db, key: fileId)!
            XCTAssertNotNil(file.trackId, "the recording link is still established in the DB")
            let track = try TrackRecord.fetchOne(db, key: file.trackId!)!
            XCTAssertEqual(track.musicbrainzRecordingId, "rec", "identity is recorded")
            XCTAssertEqual(file.artist, "old", "the display fields the user kept are untouched")
        }
    }

    // MARK: - D-A: legacy event decode (fields added mid-branch)

    /// An event JOURNALED by an earlier build of this branch — before D-A
    /// added `expectedFileSize`/`expectedMtime` — must still decode when read
    /// back (e.g. on undo of that batch). The two fields are optional, so a
    /// legacy-shape payload lacking them decodes with both nil.
    func testLegacyPayloadWithoutExpectedFieldsDecodes() throws {
        // fingerprintHash [0x01,0x02,0x03] encodes as base64 "AQID".
        let legacyJson = """
        {"fileID":7,"recordingMBID":"rec","fingerprintHash":"AQID","createdTrackRow":false}
        """
        let payload = try JSONDecoder().decode(
            ApplyMusicBrainzMatchPayload.self, from: Data(legacyJson.utf8)
        )
        XCTAssertNil(payload.expectedFileSize, "legacy event has no captured on-disk size")
        XCTAssertNil(payload.expectedMtime, "legacy event has no captured on-disk mtime")
        XCTAssertEqual(payload.fileID, 7)
        XCTAssertEqual(payload.recordingMBID, "rec")
        XCTAssertEqual(payload.fingerprintHash, Data([0x01, 0x02, 0x03]))
    }

    // MARK: - D-C: capped-fingerprint collision between different recordings

    /// Two DIFFERENT songs share their first 120s → same capped fingerprint,
    /// but resolve to DIFFERENT recordings. The second match must be
    /// rejected rather than overwrite the first's canonical identity that
    /// other files depend on (invariant #4).
    func testDifferentRecordingOnSharedFingerprintIsRejected() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(
                artist: "a1", title: "t1", album: "al1",
                recorder: recorder, path: "/Music/A/one.mp3", inode: 1
            )
        }
        let file2 = try await database.writer.write { db -> Int64 in
            var file = FileRecord(
                path: "/Music/A/two.flac", volumeUuid: "v1", inode: 2,
                fileSize: 1, mtime: 1, artist: "a2", title: "t2", album: "al2"
            )
            try file.insert(db)
            return file.id!
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        // file1 → recA creates and owns the row.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA"
            )),
            batchId: "a"
        )
        // file2 shares the capped fingerprint but is a different recording.
        do {
            try await engine.apply(
                .applyMusicBrainzMatch(fullPayload(
                    fileID: file2, fingerprintHash: fingerprint, recordingMBID: "recB"
                )),
                batchId: "b"
            )
            XCTFail("expected fingerprintRecordingConflict")
        } catch let OperationEngineError.fingerprintRecordingConflict(fid, existing, incoming) {
            XCTAssertEqual(fid, file2)
            XCTAssertEqual(existing, "recA")
            XCTAssertEqual(incoming, "recB")
        }

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertEqual(track.musicbrainzRecordingId, "recA", "existing identity preserved")
            XCTAssertEqual(
                try FileRecord.fetchOne(db, key: file1)!.trackId, track.id, "file1 still linked"
            )
            XCTAssertNil(
                try FileRecord.fetchOne(db, key: file2)!.trackId, "colliding file2 not linked"
            )
            XCTAssertEqual(
                try EventRecord.filter(Column("batch_id") == "b").fetchCount(db), 0,
                "rejected match journals nothing"
            )
        }
    }

    /// The legitimate duplicate case: FLAC+MP3 of ONE recording share a
    /// fingerprint AND resolve to the SAME recording → merges onto one row
    /// without conflict.
    func testSameRecordingOnSharedFingerprintMergesWithoutConflict() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, file1) = try await MainActor.run {
            try makeEngineWithFile(
                artist: "a1", title: "t1", album: "al1",
                recorder: recorder, path: "/Music/A/one.mp3", inode: 1
            )
        }
        let file2 = try await database.writer.write { db -> Int64 in
            var file = FileRecord(
                path: "/Music/A/two.flac", volumeUuid: "v1", inode: 2,
                fileSize: 1, mtime: 1, artist: "a2", title: "t2", album: "al2"
            )
            try file.insert(db)
            return file.id!
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file1, fingerprintHash: fingerprint, recordingMBID: "recA"
            )),
            batchId: "a"
        )
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file2, fingerprintHash: fingerprint, recordingMBID: "recA"
            )),
            batchId: "b"
        )

        try await database.writer.read { db in
            let rows = try TrackRecord.filter(Column("fingerprint_hash") == fingerprint).fetchAll(db)
            XCTAssertEqual(rows.count, 1, "one recording → one track row")
            let track = rows[0]
            XCTAssertEqual(track.musicbrainzRecordingId, "recA")
            XCTAssertEqual(try FileRecord.fetchOne(db, key: file1)!.trackId, track.id)
            XCTAssertEqual(try FileRecord.fetchOne(db, key: file2)!.trackId, track.id)
        }
    }

    // MARK: - D-D: undo restores the file's real on-disk tags

    /// The file's embedded artist differs from its Serato-imported DB row.
    /// A match overwrites the artist; undo must rewrite the file's ORIGINAL
    /// embedded artist back into the audio tags — not the DB-row value.
    func testUndoRestoresOnDiskFileTagsNotDatabaseSnapshot() async throws {
        let recorder = FileTagWriterRecorder()
        // DB row (Serato snapshot) says artist "DB Artist"; the file's real
        // embedded tag is "Disk Artist".
        let (engine, _, fileId) = try await MainActor.run {
            try makeEngineWithFile(artist: "DB Artist", title: "DB Title", album: "DB Album", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: fileId, fingerprintHash: fingerprint,
                artist: "Nas", title: "N.Y. State of Mind", album: "Illmatic", year: nil,
                currentFileArtist: "Disk Artist",
                currentFileTitle: "Disk Title",
                currentFileAlbum: "Disk Album"
            )),
            batchId: "dd"
        )
        try await engine.undoBatch("dd")

        let undoUpdate = try XCTUnwrap(recorder.calls.last?.update)
        XCTAssertEqual(undoUpdate.artist, "Disk Artist", "undo restores the file's real embedded artist, not the DB row")
        XCTAssertEqual(undoUpdate.title, "Disk Title", "undo restores the file's real embedded title")
        XCTAssertEqual(undoUpdate.album, "Disk Album", "undo restores the file's real embedded album")
    }

    // MARK: - Cherry-pick

    func testPartialFieldSetOnlyWritesChosenFields() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, fileId) = try await MainActor.run {
            try makeEngineWithFile(artist: "origA", title: "origT", album: "origAl", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        // title + artist absent (not applied); album present; identity always applied.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: fileId,
                fingerprintHash: fingerprint,
                artist: nil,
                title: nil,
                album: "NewAlbum",
                year: 1994
            )),
            batchId: "partial"
        )

        try await database.writer.read { db in
            let file = try FileRecord.fetchOne(db, key: fileId)!
            XCTAssertEqual(file.title, "origT", "absent title leaves files.title unchanged")
            XCTAssertEqual(file.artist, "origA", "absent artist leaves files.artist unchanged")
            XCTAssertEqual(file.album, "NewAlbum", "present album is applied")

            let track = try TrackRecord.fetchOne(db, key: file.trackId!)!
            XCTAssertEqual(track.musicbrainzRecordingId, "rec", "identity always written")
            XCTAssertEqual(track.isrc, "ISRC123")
            XCTAssertEqual(track.album, "NewAlbum")
            XCTAssertEqual(track.year, 1994)
            XCTAssertNil(track.title, "absent title not written to the new track row")
            XCTAssertNil(track.artist, "absent artist not written to the new track row")
        }

        let update = try XCTUnwrap(recorder.calls.first?.update)
        XCTAssertNil(update.artist)
        XCTAssertNil(update.title)
        XCTAssertEqual(update.album, "NewAlbum")
        XCTAssertEqual(update.year, 1994)
    }

    // MARK: - E-K: a nil title (from a review-row `.keep`) never touches an existing canonical title

    /// A re-match against a file already linked to an EXISTING canonical
    /// `tracks` row, with `payload.title == nil` (what `AutoTagRowModel`
    /// now sends for `.keep`) must leave that row's `title` — and the
    /// user's cherry-picked `(Clean)/(Dirty)/(Radio Version)` flags it
    /// carries — completely untouched.
    func testNilTitleLeavesExistingCanonicalTrackTitleUntouched() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, fileId) = try await MainActor.run {
            try makeEngineWithFile(artist: "origA", title: "origT", album: "origAl", recorder: recorder)
        }
        let fingerprint = sha256(sampleFingerprintBytes)

        // Seed a pre-existing canonical track row carrying a DJ-preserved
        // title with a version flag.
        try await database.writer.write { db in
            var track = TrackRecord(
                fingerprintHash: fingerprint,
                musicbrainzRecordingId: "orig-rec",
                title: "N.Y. State of Mind (Clean)"
            )
            try track.insert(db)
            try db.execute(
                sql: "UPDATE files SET track_id = ? WHERE id = ?",
                arguments: [track.id!, fileId]
            )
        }

        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: fileId,
                fingerprintHash: fingerprint,
                artist: nil,
                title: nil,
                album: nil,
                year: nil
            )),
            batchId: "keep-title"
        )

        try await database.writer.read { db in
            let file = try FileRecord.fetchOne(db, key: fileId)!
            let track = try TrackRecord.fetchOne(db, key: file.trackId!)!
            XCTAssertEqual(
                track.title, "N.Y. State of Mind (Clean)",
                "nil title must leave the canonical track title untouched"
            )
            XCTAssertEqual(file.title, "origT", "nil title must leave the file's title untouched too")
        }

        XCTAssertNil(recorder.calls.first?.update.title, "nil title must not reach the file-tag write either")
    }

    // MARK: - Serato-running gate

    func testSeratoRunningQueuesSeratoWriteButProceedsWithTagAndDB() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database, fileId) = try await MainActor.run {
            try makeEngineWithFile(
                artist: "old", title: "old", album: "old",
                recorder: recorder, seratoIsRunning: true
            )
        }
        let fingerprint = sha256(sampleFingerprintBytes)
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(fileID: fileId, fingerprintHash: fingerprint)),
            batchId: "running"
        )

        // App-DB writes proceed immediately regardless of Serato state.
        try await database.writer.read { db in
            let file = try FileRecord.fetchOne(db, key: fileId)!
            XCTAssertEqual(file.title, "N.Y. State of Mind", "files metadata updated immediately")
            XCTAssertNotNil(file.trackId, "track row created + linked immediately")
        }

        // Both the Serato-DB metadata update and the file-tag write are
        // queued while Serato is running (invariant #3 + the mmapped-file
        // safety guard that gates file-tag writes).
        let queueDepth = await engine.pendingSeratoWriteCount
        XCTAssertEqual(queueDepth, 2, "Serato-DB update + file-tag write both queued")
        XCTAssertEqual(recorder.calls.count, 0, "file-tag writer must not fire while Serato runs")

        try await engine.drainPendingSeratoUpdates()
        let drainedDepth = await engine.pendingSeratoWriteCount
        XCTAssertEqual(drainedDepth, 0, "queue drains on Serato quit")
        XCTAssertEqual(recorder.calls.count, 1, "file-tag write dispatched on drain")
        XCTAssertEqual(recorder.calls.first?.update.year, 1994)
    }

    // MARK: - Batch is one undo unit

    func testBatchOfConfirmsIsOneUndoUnit() async throws {
        let recorder = FileTagWriterRecorder()
        let (engine, database) = try await MainActor.run { try makeEngine(recorder: recorder) }
        let fileIdA = try await database.writer.write { db -> Int64 in
            var file = FileRecord(path: "/Music/A/a.mp3", volumeUuid: "v1", inode: 1,
                                  fileSize: 1, mtime: 1, artist: "oldA", title: "oldA", album: "oldA")
            try file.insert(db)
            return file.id!
        }
        let fileIdB = try await database.writer.write { db -> Int64 in
            var file = FileRecord(path: "/Music/B/b.mp3", volumeUuid: "v1", inode: 2,
                                  fileSize: 1, mtime: 1, artist: "oldB", title: "oldB", album: "oldB")
            try file.insert(db)
            return file.id!
        }
        let fingerprintA = sha256(Data("fp-a".utf8))
        let fingerprintB = sha256(Data("fp-b".utf8))

        let eventIds = try await engine.applyBatch(
            [
                .applyMusicBrainzMatch(fullPayload(fileID: fileIdA, fingerprintHash: fingerprintA,
                                                   artist: "ArtistA", title: "TitleA", album: "AlbumA")),
                .applyMusicBrainzMatch(fullPayload(fileID: fileIdB, fingerprintHash: fingerprintB,
                                                   artist: "ArtistB", title: "TitleB", album: "AlbumB")),
            ],
            batchId: "one-unit"
        )
        XCTAssertEqual(eventIds.count, 2)

        try await database.writer.read { db in
            let count = try EventRecord.filter(Column("batch_id") == "one-unit").fetchCount(db)
            XCTAssertEqual(count, 2, "both matches share one batch id")
            XCTAssertNotNil(try FileRecord.fetchOne(db, key: fileIdA)!.trackId)
            XCTAssertNotNil(try FileRecord.fetchOne(db, key: fileIdB)!.trackId)
        }

        try await engine.undoBatch("one-unit")

        try await database.writer.read { db in
            let fileA = try FileRecord.fetchOne(db, key: fileIdA)!
            let fileB = try FileRecord.fetchOne(db, key: fileIdB)!
            XCTAssertNil(fileA.trackId, "undo reverts the first match")
            XCTAssertNil(fileB.trackId, "undo reverts the second match")
            XCTAssertEqual(fileA.title, "oldA")
            XCTAssertEqual(fileB.title, "oldB")
        }
    }
}
