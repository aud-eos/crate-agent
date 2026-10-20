@testable import CrateAgent
import GRDB
import XCTest

final class KeeperMutationTests: XCTestCase {
    private var database: LibraryDatabase!
    private var engine: OperationEngine!
    private let audioFixture = OwnedProcessingAudioFixture()
    private var nextInode: Int64 = 0
    private var flac: Int64 = 0
    private var mp3: Int64 = 0
    private var mp3Track: Int64 = 0
    private var standalone: Int64 = 0

    @MainActor
    override func setUp() async throws {
        database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        engine = OperationEngine(database: database, seratoWatchdog: watchdog,
                                 seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")),
                                 fileTagWriter: { _, _ in XCTFail("A keeper wrote audio tags") }, fileTagReader: { _ in AudioTags.none })
        let flacTrack = try await addTrack(fingerprint: "flac", recordingMBID: "rec-1")
        mp3Track = try await addTrack(fingerprint: "mp3", recordingMBID: "rec-1")
        flac = try await addFile(trackID: flacTrack)
        mp3 = try await addFile(trackID: mp3Track)
        standalone = try await addFile(trackID: nil)
    }

    override func tearDownWithError() throws {
        try audioFixture.remove()
    }

    func testMarkingAKeeperProtectsEveryEncodingOfItsRecordingAndUndoRemovesIt() async throws {
        let batch = try await engine.setKeeper(true, for: token(flac))
        let protectedAfterMark = try await protectedIDs()
        XCTAssertEqual(protectedAfterMark, [flac, mp3])

        try await engine.undoBatch(batch)
        let protectedAfterUndo = try await protectedIDs()
        XCTAssertEqual(protectedAfterUndo, [])
    }

    func testClearingAKeeperRemovesEveryMarkOnTheRecordingAndUndoRestoresThem() async throws {
        try await setRecordingMBID("rec-2", ofTrack: mp3Track)
        _ = try await engine.setKeeper(true, for: token(flac))
        _ = try await engine.setKeeper(true, for: token(mp3))
        try await setRecordingMBID("rec-1", ofTrack: mp3Track)

        let batch = try await engine.setKeeper(false, for: token(mp3))
        let marksAfterClear = try await markedFileIDs()
        XCTAssertEqual(marksAfterClear, [])

        try await engine.undoBatch(batch)
        let marksAfterUndo = try await markedFileIDs()
        XCTAssertEqual(marksAfterUndo, [flac, mp3])

        let reclear = try await engine.setKeeper(false, for: token(mp3))
        let newerEncoding = try await addFile(trackID: addTrack(fingerprint: "wav", recordingMBID: "rec-1"))
        _ = try await engine.setKeeper(true, for: token(newerEncoding))
        await XCTAssertThrowsErrorAsync(try await engine.undoBatch(reclear)) { error in
            XCTAssertEqual(error as? KeeperError, .superseded, "A newer keeper already protects the recording")
        }
    }

    func testKeeperIsRefusedWhenTheFileChangedSinceItWasShown() async throws {
        let shown = try await token(standalone)
        try await replaceOnDisk(standalone)

        await XCTAssertThrowsErrorAsync(try await engine.setKeeper(true, for: shown)) { error in
            XCTAssertEqual(error as? KeeperError, .superseded)
        }
        let marks = try await markedFileIDs()
        XCTAssertEqual(marks, [])
    }

    func testReplacedContentDropsKeeperProtectionAndMarkingAgainReplacesTheStaleRow() async throws {
        _ = try await engine.setKeeper(true, for: token(standalone))
        try await replaceOnDisk(standalone)
        let protectedAfterReplacement = try await protectedIDs()
        XCTAssertEqual(protectedAfterReplacement, [])

        _ = try await engine.setKeeper(true, for: token(standalone))
        let protectedAfterRemark = try await protectedIDs()
        XCTAssertEqual(protectedAfterRemark, [standalone])
    }

    func testProtectionFollowsTheLiveRecordingKeyWhenAnEncodingLosesItsMBID() async throws {
        _ = try await engine.setKeeper(true, for: token(flac))
        // Stands in for undoing the Auto-Tag match that gave this encoding the shared MBID.
        try await setRecordingMBID(nil, ofTrack: mp3Track)

        let protected = try await protectedIDs()
        XCTAssertEqual(protected, [flac])
    }

    // MARK: - Fixture

    private func addTrack(fingerprint: String, recordingMBID: String) async throws -> Int64 {
        try await database.writer.write { connection in
            var track = TrackRecord(fingerprintHash: Data(fingerprint.utf8), musicbrainzRecordingId: recordingMBID, title: "Song")
            try track.insert(connection)
            return try XCTUnwrap(track.id)
        }
    }

    private func addFile(trackID: Int64?) async throws -> Int64 {
        nextInode += 1
        let inode = nextInode
        return try await database.writer.write { connection in
            var file = FileRecord(path: self.audioFixture.path("/Music/S/\(inode).mp3"), volumeUuid: "volume", inode: inode, fileSize: 10, mtime: 10,
                                  fingerprintStatus: .pending, trackId: trackID, title: "Song")
            file.libraryMembership = .active
            file.fileAvailability = .available
            try self.audioFixture.prepare(&file)
            try file.insert(connection)
            return try XCTUnwrap(file.id)
        }
    }

    private func row(_ fileID: Int64) async throws -> FileRecord {
        try await database.writer.read { connection in try XCTUnwrap(FileRecord.fetchOne(connection, key: fileID)) }
    }

    private func token(_ fileID: Int64) async throws -> FileMembershipToken {
        let file = try await row(fileID)
        return FileMembershipToken(fileId: fileID, revision: file.membershipRevision)
    }

    /// Another app rewrites the file in place; the scan observes the new content.
    private func replaceOnDisk(_ fileID: Int64) async throws {
        let file = try await row(fileID)
        try Data(repeating: 42, count: Int(file.fileSize) + 1).write(to: URL(fileURLWithPath: file.path))
        let identity = try FileMetadataCollector.collectVerified(at: file.path)
        _ = try await engine.apply(.observeFileIdentity(.init(fileId: fileID, expectedRevision: file.membershipRevision,
                                                              previousIdentity: file.identity, identity: identity)))
    }

    private func setRecordingMBID(_ recordingMBID: String?, ofTrack trackID: Int64) async throws {
        try await database.writer.write { connection in
            try connection.execute(sql: "UPDATE tracks SET musicbrainz_recording_id = ? WHERE id = ?", arguments: [recordingMBID, trackID])
        }
    }

    private func protectedIDs() async throws -> [Int64] {
        try await database.writer.read { connection in
            try Int64.fetchAll(connection, sql: "WITH protected AS (\(KeeperMarks.protectedFilesSQL)) SELECT file_id FROM protected ORDER BY file_id")
        }
    }

    private func markedFileIDs() async throws -> [Int64] {
        try await database.writer.read { connection in
            try Int64.fetchAll(connection, sql: "SELECT file_id FROM \(KeeperMarks.table) ORDER BY file_id")
        }
    }
}
