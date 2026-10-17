@testable import CrateAgent
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

    func testEncodingsCountOnceAndUndoRedoRestoresMaterializedLinks() async throws {
        let matched = try await addTrack(title: "Song", musicBrainzMatched: true)
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
        let remixFile = try await addFile(title: "Song (Remix)", trackID: remix)
        _ = try await addFile(title: "Song (Original Mix)", trackID: original)
        _ = try await addFile(title: "Song", trackID: plain)
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
            try connection.execute(sql: "UPDATE files SET library_membership = ? WHERE id = ?", arguments: [LibraryMembership.retired.rawValue, remixFile])
        }
        let retired = try await service.family(id: familyID)
        XCTAssertEqual(retired?.representativeTrackId, plain)
        XCTAssertEqual(retired?.savedRepresentativeTrackId, remix)
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

    private func addTrack(title: String, musicBrainzMatched: Bool) async throws -> Int64 {
        nextFingerprint += 1
        let hash = Data("track-\(nextFingerprint)".utf8)
        return try await database.writer.write { connection in
            var track = TrackRecord(fingerprintHash: hash, musicbrainzRecordingId: musicBrainzMatched ? UUID().uuidString : nil, title: title)
            try track.insert(connection)
            return try XCTUnwrap(track.id)
        }
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
