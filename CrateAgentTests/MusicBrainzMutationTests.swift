import CryptoKit
import GRDB
import XCTest
@testable import CrateAgent

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
        recordingMBID: String = "rec"
    ) -> ApplyMusicBrainzMatchPayload {
        ApplyMusicBrainzMatchPayload(
            fileID: fileID,
            acoustID: "aid",
            recordingMBID: recordingMBID,
            releaseMBID: "rel",
            artistMBID: "art",
            isrc: "ISRC123",
            fingerprintHash: fingerprintHash,
            artist: artist,
            title: title,
            album: album,
            year: year,
            currentFileYear: currentFileYear
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
        let update = recorder.calls.first!.update
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
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(fileID: fileId, fingerprintHash: fingerprint)),
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
        let lastCall = recorder.calls.last!
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

        let undoUpdate = recorder.calls.last!.update
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

        let undoUpdate = recorder.calls.last!.update
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

        let undoUpdate = recorder.calls.last!.update
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

    /// Two files share one recording (FLAC+MP3 → same fingerprint, one
    /// track row — invariant #4). Batch A creates the row; a LATER batch
    /// B adopts it and overwrites its identity. Undoing A must not null
    /// the identity B established.
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
        // with a different recording → adopts the row, overwrites identity.
        try await engine.apply(
            .applyMusicBrainzMatch(fullPayload(
                fileID: file2, fingerprintHash: fingerprint, recordingMBID: "recB"
            )),
            batchId: "batchB"
        )

        try await engine.undoBatch("batchA")

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertEqual(
                track.musicbrainzRecordingId, "recB",
                "batch B's identity (applied after A) must survive undo of A"
            )
            let f2 = try FileRecord.fetchOne(db, key: file2)!
            XCTAssertEqual(f2.trackId, track.id, "file2 still links to the row B owns")
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

    /// Pre-existing-row variant: A updates a pre-existing row, then B
    /// updates it again. Undoing A must retain B's identity, not restore
    /// A's captured `previous`.
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
                fileID: file2, fingerprintHash: fingerprint, recordingMBID: "recB"
            )),
            batchId: "batchB"
        )

        try await engine.undoBatch("batchA")

        try await database.writer.read { db in
            let track = try TrackRecord
                .filter(Column("fingerprint_hash") == fingerprint).fetchOne(db)!
            XCTAssertEqual(
                track.musicbrainzRecordingId, "recB",
                "undoing A must not restore recX over B's later recB"
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

        let update = recorder.calls.first!.update
        XCTAssertNil(update.artist)
        XCTAssertNil(update.title)
        XCTAssertEqual(update.album, "NewAlbum")
        XCTAssertEqual(update.year, 1994)
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
