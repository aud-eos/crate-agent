@testable import CrateAgent
import GRDB
import XCTest

final class SongFamilySuggesterTests: XCTestCase {
    private var database: LibraryDatabase!
    private var engine: OperationEngine!
    private var families: SongFamilyService!
    private var suggester: SongFamilySuggester!
    private let audioFixture = OwnedProcessingAudioFixture()
    private var nextInode: Int64 = 0

    @MainActor
    override func setUp() async throws {
        database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        engine = OperationEngine(database: database, seratoWatchdog: watchdog,
                                 seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")),
                                 fileTagWriter: { _, _ in XCTFail("Grouping wrote audio tags") }, fileTagReader: { _ in AudioTags.none })
        families = SongFamilyService(engine: engine, database: database)
        suggester = SongFamilySuggester(database: database, families: families)
    }

    override func tearDownWithError() throws {
        try audioFixture.remove()
    }

    func testSuggestsFilesSharingANormalizedArtistAndTitleStemWithTiers() async throws {
        let clean = try await addFile(artist: "Beyoncé feat. Jay-Z", title: "Crazy in Love (Clean)")
        let dirty = try await addFile(artist: "BEYONCE", title: "Crazy In Love! [feat. Jay-Z] (Dirty)")
        let instrumental = try await addFile(artist: "Beyonce & Jay-Z", title: "Crazy in Love - Instrumental")
        let firstRemix = try await addFile(artist: "Drake", title: "Hotline Bling (DJ X Remix)")
        let secondRemix = try await addFile(artist: "Drake", title: "Hotline Bling (DJ Y Remix)")
        _ = try await addFile(artist: "Drake", title: "Hotline Bling (Clean)", fingerprinted: false)
        _ = try await addFile(artist: "Michael Jackson", title: "Dirty Diana")
        _ = try await addFile(artist: "Michael Jackson", title: "Diana (Clean)")

        let found = try await suggester.suggestions()

        XCTAssertEqual(found.suggestions.map(\.confidence), [.high, .medium])
        XCTAssertEqual(found.suggestions.map(\.target), [.newFamily, .newFamily])
        XCTAssertEqual(found.suggestions.map { suggestion in suggestion.recordings.flatMap(\.files).map(\.id) },
                       [[clean, dirty, instrumental], [firstRemix, secondRemix]])
        XCTAssertEqual(found.awaitingFingerprint, 1)
    }

    func testLeavesSameAudioOutForDuplicates() async throws {
        let clean = try await addFile(artist: "Artist", title: "Song (Clean)")
        let dirty = try await addFile(artist: "Artist", title: "Song (Dirty)")
        _ = try await addFile(artist: "Artist", title: "Song (Instrumental)")
        try await recordAudioDigest(Data("same-pcm".utf8), for: [clean, dirty])
        let sharedFingerprint = Data("first-120-seconds".utf8)
        let tuneClean = try await addFile(artist: "Band", title: "Tune (Clean)", fingerprint: sharedFingerprint)
        let tuneDirty = try await addFile(artist: "Band", title: "Tune (Dirty)", fingerprint: sharedFingerprint)
        _ = try await addFile(artist: "Band", title: "Tune (Acapella)")

        let found = try await suggester.suggestions()

        XCTAssertEqual(found.suggestions, [])
        XCTAssertEqual(found.sameAudio.map { cluster in cluster.map(\.id) }, [[clean, dirty], [tuneClean, tuneDirty]])
    }

    func testAppliesChosenSuggestionsAsOneUndoableBatch() async throws {
        let main = try await addFile(artist: "Artist", title: "Song")
        let instrumental = try await addFile(artist: "Artist", title: "Song (Instrumental)")
        let created = try await families.create([.file(main), .file(instrumental)])
        let existing = try XCTUnwrap(created.familyId)
        let acapella = try await addFile(artist: "Artist", title: "Song (Acapella)")
        let clean = try await addFile(artist: "Artist", title: "Song (Clean)")
        let tunes = try await [addFile(artist: "Band", title: "Tune (Clean)"), addFile(artist: "Band", title: "Tune (Dirty)")]

        let found = try await suggester.suggestions().suggestions
        let song = try XCTUnwrap(found.first { suggestion in suggestion.target == .family(existing) })
        XCTAssertEqual(song.existingFiles.map(\.id), [main, instrumental])
        let tune = try XCTUnwrap(found.first { suggestion in suggestion.target == .newFamily })
        let acapellaRecording = try XCTUnwrap(song.recordings.first { recording in recording.files.map(\.id) == [acapella] })
        let batch = try await suggester.apply([
            SongFamilySuggestionChoice(suggestion: song, recordingIds: [acapellaRecording.id]),
            SongFamilySuggestionChoice(suggestion: tune, recordingIds: Set(tune.recordings.map(\.id))),
        ])
        let batchID = try XCTUnwrap(batch)

        let grown = try await families.family(id: existing)
        XCTAssertEqual(grown?.members.flatMap(\.fileIds).sorted(), [main, instrumental, acapella])
        let tuneTrack = try await trackID(ofFile: tunes[0])
        let tuneFamily = try await families.family(containingTrack: XCTUnwrap(tuneTrack))
        XCTAssertEqual(tuneFamily?.members.flatMap(\.fileIds).sorted(), tunes)
        let remaining = try await suggester.suggestions().suggestions
        XCTAssertEqual(remaining.map { suggestion in suggestion.recordings.flatMap(\.files).map(\.id) }, [[clean]])

        try await engine.undoBatch(batchID)
        let restored = try await families.family(id: existing)
        XCTAssertEqual(restored?.members.flatMap(\.fileIds).sorted(), [main, instrumental])
        let unlinkedTune = try await trackID(ofFile: tunes[0])
        XCTAssertNil(unlinkedTune)
    }

    @discardableResult
    private func addFile(artist: String, title: String, fingerprinted: Bool = true, fingerprint: Data? = nil) async throws -> Int64 {
        nextInode += 1
        let inode = nextInode
        let chromaprint = fingerprinted ? fingerprint ?? Data("fingerprint-\(inode)".utf8) : nil
        return try await database.writer.write { connection in
            var file = FileRecord(path: self.audioFixture.path("/Music/\(inode).mp3"), volumeUuid: "volume", inode: inode, fileSize: 10, mtime: 10,
                                  chromaprintFingerprint: chromaprint, fingerprintStatus: chromaprint == nil ? .pending : .done,
                                  artist: artist, title: title)
            file.libraryMembership = .active
            file.fileAvailability = .available
            try self.audioFixture.prepare(&file)
            try file.insert(connection)
            return try XCTUnwrap(file.id)
        }
    }

    private func recordAudioDigest(_ digest: Data, for fileIDs: [Int64]) async throws {
        try await database.writer.write { connection in
            for fileID in fileIDs {
                try connection.execute(sql: """
                INSERT INTO file_audio_digests (file_id, file_size, mtime, inode, modified_nanoseconds, changed_seconds, changed_nanoseconds,
                                                format, pcm_sha256, full_fingerprint_sha256, duration_seconds)
                SELECT id, file_size, mtime, inode, 0, 0, 0, 'mp3', ?, ?, 200 FROM files WHERE id = ?
                """, arguments: [digest, digest, fileID])
            }
        }
    }

    private func trackID(ofFile fileID: Int64) async throws -> Int64? {
        try await database.writer.read { connection in try FileRecord.fetchOne(connection, key: fileID)?.trackId }
    }
}
