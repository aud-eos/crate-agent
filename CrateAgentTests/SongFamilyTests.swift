@testable import CrateAgent
import CryptoKit
import GRDB
import XCTest

final class SongFamilyTests: XCTestCase {
    private var database: LibraryDatabase!
    private var engine: OperationEngine!
    private var service: SongFamilyService!
    @MainActor private var seratoState: ProcessingTestSeratoState?

    @MainActor
    override func setUp() async throws {
        database = try LibraryDatabase.openInMemory()
        let state = ProcessingTestSeratoState(isRunning: false)
        seratoState = state
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { state.isRunning ? ["com.serato.djpro"] : [] })
        engine = OperationEngine(database: database, seratoWatchdog: watchdog,
                                 seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")),
                                 fileTagWriter: { _, _ in XCTFail("Grouping wrote audio tags") })
        service = SongFamilyService(engine: engine, database: database)
    }

    func testFilesSharingARecordingCountOnceAndUndoRedoRestoresGroupingLinks() async throws {
        let matched = try await addTrack(title: "Song", musicBrainzMatched: true, withFile: false)
        let flac = try await addFile(title: "Song", trackID: matched)
        let mp3 = try await addFile(title: "Song", trackID: matched)
        let unmatched = try await addFile(title: "Song (Instrumental)", fingerprint: Data("instrumental".utf8))

        let created = try await service.create([.file(flac), .file(mp3), .file(unmatched)])
        let familyID = try XCTUnwrap(created.familyId)
        let family = try await service.family(id: familyID)
        XCTAssertEqual(family?.versionCount, 2)
        XCTAssertEqual(family?.members.first?.fileIds, [flac, mp3])
        let materialized = try await trackID(ofFile: unmatched)
        XCTAssertNotNil(materialized)

        let linkHistory = try await database.writer.read { connection in
            try EventRecord.filter(Column("file_id") == unmatched).fetchCount(connection)
        }
        XCTAssertEqual(linkHistory, 1)

        let undo = try await engine.undoBatch(created.batchId)
        let undoneFamily = try await service.family(id: familyID)
        let undoneLink = try await trackID(ofFile: unmatched)
        let undoneMatched = try await membership(ofTrack: matched)
        XCTAssertNil(undoneFamily)
        XCTAssertNil(undoneLink)
        XCTAssertNil(undoneMatched)

        try await engine.undoBatch(undo)
        let redone = try await service.family(id: familyID)
        let redoneLink = try await trackID(ofFile: unmatched)
        XCTAssertEqual(redone?.versionCount, 2)
        XCTAssertEqual(redoneLink, materialized)
    }

    func testGroupingRefusesAFingerprintAnotherFileClaimedAndLeavesNoLink() async throws {
        let fingerprint = Data("shared-first-120-seconds".utf8)
        let dirtyTrack = try await addTrack(title: "Song (Dirty)", musicBrainzMatched: true, fingerprintHash: Data(SHA256.hash(data: fingerprint)),
                                            withFile: false)
        let dirty = try await addFile(title: "Song (Dirty)", trackID: dirtyTrack)
        let clean = try await addFile(title: "Song (Clean)", fingerprint: fingerprint)

        await XCTAssertThrowsErrorAsync(try await service.create([.file(dirty), .file(clean)])) { error in
            XCTAssertEqual(error as? SongFamilyError, .fingerprintCollision(fileId: clean, trackId: dirtyTrack, otherFileId: dirty))
        }
        let cleanLink = try await trackID(ofFile: clean)
        let dirtyMembership = try await membership(ofTrack: dirtyTrack)
        XCTAssertNil(cleanLink)
        XCTAssertNil(dirtyMembership)
    }

    func testAMemberThatLosesItsFileStopsCountingUntilTheFileReturns() async throws {
        let tracks = try await addTracks(count: 2)
        let created = try await service.create(tracks.map(SongFamilyMember.track))
        let familyID = try XCTUnwrap(created.familyId)
        let movedFile = try await file(ofTrack: tracks[1])
        let rematch = try await engine.apply(.applyMusicBrainzMatch(matchPayload(fileID: movedFile, fingerprintHash: Data("re-fingerprinted".utf8))),
                                             batchId: "rematch")
        XCTAssertNotNil(rematch)
        let withoutFile = try await service.family(id: familyID)
        XCTAssertEqual(withoutFile?.versionCount, 1)

        _ = try await service.attach([.file(movedFile)], to: familyID)
        _ = try await service.attach([.file(movedFile)], to: familyID)
        let reattached = try await service.family(id: familyID)
        XCTAssertEqual(reattached?.versionCount, 2)

        try await engine.undoBatch("rematch")
        let restored = try await service.family(id: familyID)
        XCTAssertEqual(restored?.members.map(\.trackId), [tracks[0], tracks[1]])
    }

    func testUndoingAGroupKeepsTheLinkALaterMatchClaimed() async throws {
        let fingerprint = Data("clean-edit".utf8)
        let main = try await addTracks(count: 1)
        let clean = try await addFile(title: "Song (Clean)", fingerprint: fingerprint)
        let created = try await service.create([.track(main[0]), .file(clean)])
        let groupedLink = try await trackID(ofFile: clean)
        let groupedRecording = try XCTUnwrap(groupedLink)
        _ = try await engine.apply(.applyMusicBrainzMatch(matchPayload(fileID: clean, fingerprintHash: Data(SHA256.hash(data: fingerprint)),
                                                                       currentFileTitle: "Song (Clean)")), batchId: "match")

        try await engine.undoBatch(created.batchId)
        let link = try await trackID(ofFile: clean)
        let recording = try await database.writer.read { connection in try TrackRecord.fetchOne(connection, key: groupedRecording) }
        XCTAssertEqual(link, groupedRecording)
        XCTAssertNil(recording?.workId)
        XCTAssertEqual(recording?.title, "Song (Clean)")
        XCTAssertNotNil(recording?.musicbrainzRecordingId)
    }

    func testMemberOfAnotherFamilyIsRejectedUntilMergedAndUndoSeparatesThem() async throws {
        let tracks = try await addTracks(count: 4)
        let target = try await service.create([.track(tracks[0]), .track(tracks[1])], representative: .track(tracks[1]))
        let other = try await service.create([.track(tracks[2]), .track(tracks[3])])
        let targetID = try XCTUnwrap(target.familyId)
        let otherID = try XCTUnwrap(other.familyId)

        await XCTAssertThrowsErrorAsync(try await service.attach([.track(tracks[2])], to: targetID)) { error in
            XCTAssertEqual(error as? SongFamilyError, .memberAlreadyInFamily(trackId: tracks[2], familyId: otherID))
        }
        let merged = try await service.merge([otherID], into: targetID)
        let mergedFamily = try await service.family(id: targetID)
        let mergedOther = try await service.family(id: otherID)
        XCTAssertEqual(mergedFamily?.versionCount, 4)
        XCTAssertEqual(mergedFamily?.savedRepresentativeTrackId, tracks[1])
        XCTAssertNil(mergedOther)

        try await engine.undoBatch(merged.batchId)
        let restoredTarget = try await service.family(id: targetID)
        let restoredOther = try await service.family(id: otherID)
        XCTAssertEqual(restoredTarget?.members.map(\.trackId).sorted(), [tracks[0], tracks[1]])
        XCTAssertEqual(restoredTarget?.savedRepresentativeTrackId, tracks[1])
        XCTAssertEqual(restoredOther?.members.map(\.trackId).sorted(), [tracks[2], tracks[3]])
    }

    func testRemovingTheLastAlternateDissolvesAndUndoRestoresPreference() async throws {
        let tracks = try await addTracks(count: 2)
        let created = try await service.create([.track(tracks[0]), .track(tracks[1])], representative: .track(tracks[1]))
        let familyID = try XCTUnwrap(created.familyId)

        let detached = try await service.detach([tracks[0]], from: familyID)
        let dissolved = try await service.family(id: familyID)
        let remaining = try await membership(ofTrack: tracks[1])
        XCTAssertNil(detached.familyId)
        XCTAssertNil(dissolved)
        XCTAssertNil(remaining)

        try await engine.undoBatch(detached.batchId)
        let restored = try await service.family(id: familyID)
        XCTAssertEqual(restored?.versionCount, 2)
        XCTAssertEqual(restored?.savedRepresentativeTrackId, tracks[1])
    }

    func testSplitCarriesTheSavedMainVersionWithItsMembers() async throws {
        let tracks = try await addTracks(count: 4)
        let created = try await service.create(tracks.map(SongFamilyMember.track), representative: .track(tracks[2]))
        let familyID = try XCTUnwrap(created.familyId)

        let split = try await service.split([tracks[2], tracks[3]], from: familyID)
        let splitFamily = try await service.family(id: XCTUnwrap(split.familyId))
        let original = try await service.family(id: familyID)
        XCTAssertEqual(splitFamily?.members.map(\.trackId).sorted(), [tracks[2], tracks[3]])
        XCTAssertEqual(splitFamily?.savedRepresentativeTrackId, tracks[2])
        XCTAssertEqual(original?.members.map(\.trackId).sorted(), [tracks[0], tracks[1]])
        XCTAssertNil(original?.savedRepresentativeTrackId)
    }

    func testUndoIsRefusedAfterALaterChangeToTheSameFamily() async throws {
        let tracks = try await addTracks(count: 3)
        let created = try await service.create([.track(tracks[0]), .track(tracks[1])])
        let familyID = try XCTUnwrap(created.familyId)
        _ = try await service.attach([.track(tracks[2])], to: familyID)

        await XCTAssertThrowsErrorAsync(try await engine.undoBatch(created.batchId)) { error in
            XCTAssertEqual(error as? SongFamilyError, .changedSinceRecorded)
        }
        let family = try await service.family(id: familyID)
        XCTAssertEqual(family?.versionCount, 3)
    }

    func testDisplayedMainVersionPrefersAvailableSavedChoiceThenMainLabelThenMusicBrainz() async throws {
        let remix = try await addTrack(title: "Song (Remix)", musicBrainzMatched: true)
        let original = try await addTrack(title: "Song (Original Mix)", musicBrainzMatched: false)
        let plain = try await addTrack(title: "Song", musicBrainzMatched: true)
        let remixFile = try await file(ofTrack: remix)
        let created = try await service.create([.track(remix), .track(original), .track(plain)])
        let familyID = try XCTUnwrap(created.familyId)
        let automatic = try await service.family(id: familyID)
        XCTAssertEqual(automatic?.representativeTrackId, original)

        _ = try await service.detach([original], from: familyID)
        let withoutMainLabel = try await service.family(id: familyID)
        XCTAssertEqual(withoutMainLabel?.representativeTrackId, plain)

        _ = try await service.setRepresentative(remix, of: familyID)
        let saved = try await service.family(id: familyID)
        XCTAssertEqual(saved?.representativeTrackId, remix)

        try await database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET file_availability = ? WHERE id = ?", arguments: [FileAvailability.missing.rawValue, remixFile])
        }
        let missing = try await service.family(id: familyID)
        XCTAssertEqual(missing?.representativeTrackId, plain)
        XCTAssertEqual(missing?.savedRepresentativeTrackId, remix)
    }

    // MARK: - Fixture

    private var nextFingerprint = 0

    private func addTracks(count: Int) async throws -> [Int64] {
        var tracks: [Int64] = []
        for index in 0 ..< count {
            try await tracks.append(addTrack(title: "Version \(index)", musicBrainzMatched: false))
        }
        return tracks
    }

    private func addTrack(title: String, musicBrainzMatched: Bool, fingerprintHash: Data? = nil, withFile: Bool = true) async throws -> Int64 {
        nextFingerprint += 1
        let hash = fingerprintHash ?? Data("track-\(nextFingerprint)".utf8)
        let trackID = try await database.writer.write { connection in
            var track = TrackRecord(fingerprintHash: hash, musicbrainzRecordingId: musicBrainzMatched ? UUID().uuidString : nil, title: title)
            try track.insert(connection)
            return try XCTUnwrap(track.id)
        }
        if withFile {
            _ = try await addFile(title: title, trackID: trackID)
        }
        return trackID
    }

    private func file(ofTrack trackID: Int64) async throws -> Int64 {
        try await database.writer.read { connection in
            try XCTUnwrap(Int64.fetchOne(connection, sql: "SELECT id FROM files WHERE track_id = ? ORDER BY id", arguments: [trackID]))
        }
    }

    private func matchPayload(fileID: Int64, fingerprintHash: Data, currentFileTitle: String? = nil) -> ApplyMusicBrainzMatchPayload {
        ApplyMusicBrainzMatchPayload(fileID: fileID, acoustID: nil, recordingMBID: UUID().uuidString, releaseMBID: nil, artistMBID: nil, isrc: nil,
                                     fingerprintHash: fingerprintHash, artist: nil, title: nil, album: nil, year: nil,
                                     currentFileTitle: currentFileTitle)
    }

    private func addFile(title: String, trackID: Int64? = nil, fingerprint: Data? = nil) async throws -> Int64 {
        nextFingerprint += 1
        let inode = Int64(nextFingerprint)
        return try await database.writer.write { connection in
            var file = FileRecord(path: "/Music/S/\(inode).mp3", volumeUuid: "volume", inode: inode, fileSize: 10, mtime: 10,
                                  chromaprintFingerprint: fingerprint, fingerprintStatus: fingerprint == nil ? .pending : .done,
                                  trackId: trackID, title: title)
            file.libraryMembership = .active
            file.fileAvailability = .available
            try file.insert(connection)
            return try XCTUnwrap(file.id)
        }
    }

    private func trackID(ofFile fileID: Int64) async throws -> Int64? {
        try await database.writer.read { connection in try FileRecord.fetchOne(connection, key: fileID)?.trackId }
    }

    private func membership(ofTrack trackID: Int64) async throws -> Int64? {
        try await database.writer.read { connection in try TrackRecord.fetchOne(connection, key: trackID)?.workId }
    }
}
