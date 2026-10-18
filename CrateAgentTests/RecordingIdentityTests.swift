@testable import CrateAgent
import GRDB
import XCTest

/// Recording identity for files whose 120 s fingerprints collide (#205), on
/// real decoded audio: tone sequences that share their first 120 seconds.
final class RecordingIdentityTests: XCTestCase {
    private var database: LibraryDatabase!
    private var engine: OperationEngine!
    private var families: SongFamilyService!
    private var identities: RecordingIdentityService!
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recording-identity-\(UUID().uuidString)")
    private static let opening = (0 ..< 120).map { second in 220 + Double(second % 12) * 55 }

    @MainActor
    override func setUp() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        engine = OperationEngine(database: database, seratoWatchdog: watchdog,
                                 seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")),
                                 fileTagWriter: { _, _ in XCTFail("Recording identity wrote audio tags") }, fileTagReader: { _ in AudioTags.none })
        families = SongFamilyService(engine: engine, database: database)
        identities = RecordingIdentityService(engine: engine, database: database, verifier: DuplicateEvidenceVerifier(database: database))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSplittingACollisionWhoseFullLengthAudioDiffersMovesOnlyTheOtherVersionAndUndoRejoinsIt() async throws {
        let dirty = try await addFile("Song (Dirty)", tail: [330, 370, 415, 440, 495])
        let clean = try await addFile("Song (Clean)", tail: [1760, 1980, 2200, 2420, 2640])
        let cleanCopy = try await addFile("Song (Clean) copy", tail: [1760, 1980, 2200, 2420, 2640])
        let shared = try await recordingKey(of: clean)
        let sharedKeys = try await [recordingKey(of: cleanCopy), recordingKey(of: dirty)]
        XCTAssertEqual(sharedKeys, [shared, shared], "The fixture's files must collide on their 120 s fingerprint")
        try await engine.apply(.applyMusicBrainzMatch(match(clean, key: shared)), batchId: "match-clean")
        try await engine.apply(.applyMusicBrainzMatch(match(cleanCopy, key: shared)), batchId: "match-clean-copy")
        try await engine.apply(.applyMusicBrainzMatch(match(dirty, key: shared)), batchId: "match-dirty")
        let staleLookup = match(dirty, key: shared)
        let sharedTrack = try await trackID(of: clean)

        try await identities.checkCollidingFiles()
        let scan = try await identities.scan()
        let candidate = try XCTUnwrap(scan.candidates.first)
        XCTAssertEqual(scan.candidates.count, 1)
        XCTAssertEqual(candidate.keeps.files.map(\.id), [clean, cleanCopy])
        XCTAssertEqual(candidate.separates.map { version in version.files.map(\.id) }, [[dirty]])
        XCTAssertEqual(candidate.movedFiles.map(\.sharedRecording), try [.init(trackId: XCTUnwrap(sharedTrack), hasMusicBrainzMatch: true,
                                                                               isInSongFamily: false)])

        let split = try await identities.separate(candidate)
        let dirtyTrack = try await trackID(of: dirty)
        let cleanTrack = try await trackID(of: clean)
        let cleanCopyKey = try await recordingKey(of: cleanCopy)
        XCTAssertEqual(cleanTrack, sharedTrack)
        XCTAssertNotEqual(dirtyTrack, sharedTrack)
        XCTAssertEqual(cleanCopyKey, shared)
        let separated = try await database.writer.read { connection in try TrackRecord.fetchOne(connection, key: XCTUnwrap(dirtyTrack)) }
        XCTAssertNil(separated?.musicbrainzRecordingId)
        let remaining = try await identities.scan()
        XCTAssertTrue(remaining.candidates.isEmpty)

        await XCTAssertThrowsErrorAsync(try await engine.apply(.applyMusicBrainzMatch(staleLookup), batchId: "stale-lookup")) { error in
            XCTAssertEqual(error as? RecordingIdentityError, .identityChangedSinceLookup(file: "Song (Dirty)"))
        }
        await XCTAssertThrowsErrorAsync(try await engine.undoBatch("match-dirty")) { error in
            guard case OperationEngineError.undoSupersededByLaterMatch = error else { return XCTFail("Unexpected error \(error)") }
        }
        try await engine.undoBatch(split)
        let rejoinedTrack = try await trackID(of: dirty)
        let rejoinedKey = try await recordingKey(of: dirty)
        let reopened = try await identities.scan()
        XCTAssertEqual(rejoinedTrack, sharedTrack)
        XCTAssertEqual(rejoinedKey, shared)
        XCTAssertEqual(reopened.candidates.map(\.id), [candidate.id])
    }

    func testAnUnlinkedFileSeparatedByItsFullLengthFingerprintGroupsAsItsOwnVersion() async throws {
        let clean = try await addFile("Song (Clean)", tail: [1760, 1980, 2200])
        let dirty = try await addFile("Song (Dirty)", tail: [330, 370, 415])
        try await engine.apply(.applyMusicBrainzMatch(match(clean, key: recordingKey(of: clean))), batchId: "match-clean")
        try await identities.checkCollidingFiles()
        let scan = try await identities.scan()
        try await identities.separate(XCTUnwrap(scan.candidates.first))

        let grouped = try await families.create([.file(clean), .file(dirty)])
        let family = try await families.family(id: XCTUnwrap(grouped.familyId))
        XCTAssertEqual(family?.versionCount, 2)
    }

    func testGroupingIdenticalAudioAsDifferentRecordingsKeepsTheMatchedFileOnItsRecordingAndUndoRedoRestoresTheSplit() async throws {
        let tail: [Double] = [880, 990, 1100]
        let explicit = try await addFile("Song (Dirty)", tail: tail)
        let clean = try await addFile("Song (Clean)", tail: tail)
        let shared = try await recordingKey(of: explicit)
        try await engine.apply(.applyMusicBrainzMatch(match(explicit, key: shared)), batchId: "match")
        let matchedTrack = try await trackID(of: explicit)

        let grouped = try await families.createAsDifferentRecordings([explicit, clean])
        let familyID = try XCTUnwrap(grouped.familyId)
        let family = try await families.family(id: familyID)
        let explicitTrack = try await trackID(of: explicit)
        let separatedTrack = try await trackID(of: clean)
        let cleanTrack = try XCTUnwrap(separatedTrack)
        XCTAssertEqual(family?.versionCount, 2)
        XCTAssertEqual(explicitTrack, matchedTrack)
        XCTAssertNotEqual(cleanTrack, matchedTrack)

        let undo = try await engine.undoBatch(grouped.batchId)
        let undoneFamily = try await families.family(id: familyID)
        let undoneTrack = try await trackID(of: clean)
        let undoneKey = try await recordingKey(of: clean)
        XCTAssertNil(undoneFamily)
        XCTAssertNil(undoneTrack)
        XCTAssertEqual(undoneKey, shared)

        try await engine.undoBatch(undo)
        let redone = try await families.family(id: familyID)
        let redoneTrack = try await trackID(of: clean)
        XCTAssertEqual(redone?.versionCount, 2)
        XCTAssertEqual(redoneTrack, cleanTrack)
    }

    // MARK: - Fixture

    /// Indexes a real WAV of the shared 120 s opening followed by `tail`,
    /// with its real 120 s fingerprint.
    private func addFile(_ title: String, tail: [Double]) async throws -> Int64 {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        try TestAudio.tones(Self.opening + tail, title: title).write(to: url)
        let identity = try FileMetadataCollector.collectVerified(at: url.path)
        let fingerprint = try FingerprintEncoder.serialize(fingerprintAudioFile(filePath: url.path))
        return try await database.writer.write { connection in
            var file = FileRecord(path: url.path, volumeUuid: identity.volumeUuid, inode: identity.inode, fileSize: identity.fileSize,
                                  mtime: identity.mtime, mtimeNanoseconds: identity.mtimeNanoseconds, lightweightHash: identity.lightweightHash,
                                  chromaprintFingerprint: fingerprint, fingerprintStatus: .done, title: title)
            file.libraryMembership = .active
            file.fileAvailability = .available
            try file.insert(connection)
            return try XCTUnwrap(file.id)
        }
    }

    private func match(_ fileID: Int64, key: Data) -> ApplyMusicBrainzMatchPayload {
        ApplyMusicBrainzMatchPayload(fileID: fileID, acoustID: nil, recordingMBID: "song-recording", releaseMBID: nil, artistMBID: nil, isrc: nil,
                                     fingerprintHash: key, artist: nil, title: nil, album: nil, year: nil)
    }

    private func recordingKey(of fileID: Int64) async throws -> Data {
        try await database.writer.read { connection in
            try XCTUnwrap(RecordingIdentity.key(of: XCTUnwrap(FileRecord.fetchOne(connection, key: fileID)), in: connection))
        }
    }

    private func trackID(of fileID: Int64) async throws -> Int64? {
        try await database.writer.read { connection in try FileRecord.fetchOne(connection, key: fileID)?.trackId }
    }
}
