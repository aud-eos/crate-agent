@testable import CrateAgent
import CryptoKit
import GRDB
import XCTest

final class SongFamilyTests: XCTestCase {
    private var database: LibraryDatabase!
    private var engine: OperationEngine!
    private var service: SongFamilyService!
    @MainActor private var seratoState: ProcessingTestSeratoState?
    private let audioFixture = OwnedProcessingAudioFixture()

    override func tearDownWithError() throws {
        try audioFixture.remove()
    }

    @MainActor
    override func setUp() async throws {
        database = try LibraryDatabase.openInMemory()
        let state = ProcessingTestSeratoState(isRunning: false)
        seratoState = state
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { state.isRunning ? ["com.serato.djpro"] : [] })
        engine = OperationEngine(database: database, seratoWatchdog: watchdog,
                                 seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")),
                                 fileTagWriter: { _, _ in XCTFail("Grouping wrote audio tags") }, fileTagReader: { _ in AudioTags.none })
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
            XCTAssertEqual(error as? SongFamilyError, .fingerprintCollision(file: "Song (Clean)", otherFile: "Song (Dirty)"))
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
        XCTAssertNil(withoutFile)

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
            XCTAssertEqual(error as? SongFamilyError, .memberAlreadyInFamily(recording: "Version 2", familyVersions: ["Version 3"]))
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

    func testRecordingsSharingAMusicBrainzRecordingAreOneVersion() async throws {
        let recording = UUID().uuidString
        let flac = try await addTrack(title: "Song", musicBrainzMatched: true, recordingMBID: recording)
        let instrumental = try await addTrack(title: "Song (Instrumental)", musicBrainzMatched: false)
        let mp3 = try await addTrack(title: "Song", musicBrainzMatched: true, recordingMBID: recording)
        let created = try await service.create([.track(flac), .track(instrumental), .track(mp3)])
        let familyID = try XCTUnwrap(created.familyId)
        let family = try await service.family(id: familyID)
        XCTAssertEqual(family?.versionCount, 2)
        XCTAssertEqual(family?.members.map(\.trackId), [flac, mp3, instrumental])

        _ = try await service.detach([instrumental], from: familyID)
        let oneVersion = try await service.family(id: familyID)
        XCTAssertNil(oneVersion)
    }

    func testAutomaticMainVersionTiersAMainLabelThenABareTitleThenADirtyOnlyEditAboveAMusicBrainzMatch() async throws {
        let remix = try await addTrack(title: "Song (Remix)", musicBrainzMatched: true)
        let dirty = try await addTrack(title: "Song (Dirty)", musicBrainzMatched: false)
        let plain = try await addTrack(title: "Song", musicBrainzMatched: false)
        let album = try await addTrack(title: "Song (Album Version)", musicBrainzMatched: false)
        let created = try await service.create([.track(remix), .track(dirty), .track(plain), .track(album)])
        let familyID = try XCTUnwrap(created.familyId)
        var chosen: [Int64?] = []
        for detached in [album, plain] {
            try await chosen.append(service.family(id: familyID)?.representativeTrackId)
            _ = try await service.detach([detached], from: familyID)
        }
        try await chosen.append(service.family(id: familyID)?.representativeTrackId)
        XCTAssertEqual(chosen, [album, plain, dirty])

        let featuredInstrumental = try await addTrack(title: "One Dance (feat. Wizkid) (Instrumental)", musicBrainzMatched: true)
        let originalInstrumental = try await addTrack(title: "One Dance (Original Instrumental)", musicBrainzMatched: true)
        let remaster = try await addTrack(title: "One Dance (feat. Wizkid) - 2011 Remaster", musicBrainzMatched: false)
        let credited = try await service.create([.track(featuredInstrumental), .track(originalInstrumental), .track(remaster)])
        let creditedFamily = try await service.family(id: XCTUnwrap(credited.familyId))
        XCTAssertEqual(creditedFamily?.representativeTrackId, remaster)
    }

    func testAFamilyNoLongerShownIsRefusedRatherThanRevivedByAnAttach() async throws {
        let tracks = try await addTracks(count: 3)
        let created = try await service.create([.track(tracks[0]), .track(tracks[1])])
        let familyID = try XCTUnwrap(created.familyId)
        try await retire(file(ofTrack: tracks[1]))

        await XCTAssertThrowsErrorAsync(try await service.attach([.track(tracks[2])], to: familyID)) { error in
            XCTAssertEqual(error as? SongFamilyError, .familyNoLongerShown(family: "Version 0"))
        }
        let attached = try await membership(ofTrack: tracks[2])
        XCTAssertNil(attached)
    }

    func testARecordingLeftAloneInItsFamilyCanBeRegroupedAndUndoRestoresThatFamily() async throws {
        let tracks = try await addTracks(count: 3)
        let first = try await service.create([.track(tracks[0]), .track(tracks[1])])
        let firstID = try XCTUnwrap(first.familyId)
        try await retire(file(ofTrack: tracks[1]))

        let regrouped = try await service.create([.track(tracks[0]), .track(tracks[2])])
        let regroupedMembership = try await membership(ofTrack: tracks[0])
        XCTAssertEqual(regroupedMembership, regrouped.familyId)

        try await engine.undoBatch(regrouped.batchId)
        let restored = try await [membership(ofTrack: tracks[0]), membership(ofTrack: tracks[1])]
        XCTAssertEqual(restored, [firstID, firstID])
    }

    func testRedoRefusesToRelinkAFileReplacedSinceTheUndo() async throws {
        let main = try await addTracks(count: 1)
        let clean = try await addFile(title: "Song (Clean)", fingerprint: Data("replaced-clean".utf8))
        let created = try await service.create([.track(main[0]), .file(clean)])
        let undo = try await engine.undoBatch(created.batchId)
        try await replaceOnDisk(clean)

        await XCTAssertThrowsErrorAsync(try await engine.undoBatch(undo))
        let link = try await trackID(ofFile: clean)
        let mainMembership = try await membership(ofTrack: main[0])
        XCTAssertNil(link)
        XCTAssertNil(mainMembership)
    }

    func testRegroupingOutOfAFamilyThatOnlyTheBatchsOwnLinkWouldReviveTakesItOver() async throws {
        let fingerprint = Data("flac-copy".utf8)
        let tracks = try await addTracks(count: 2)
        let copied = try await addTrack(title: "Song", musicBrainzMatched: false, fingerprintHash: Data(SHA256.hash(data: fingerprint)))
        let old = try await service.create([.track(tracks[0]), .track(copied)])
        let oldID = try XCTUnwrap(old.familyId)
        _ = try await engine.apply(.applyMusicBrainzMatch(matchPayload(fileID: file(ofTrack: copied), fingerprintHash: Data("re-fingerprinted".utf8))))
        let copy = try await addFile(title: "Song", fingerprint: fingerprint)

        let regrouped = try await service.create([.file(copy), .track(tracks[1])])
        let memberships = try await [membership(ofTrack: tracks[0]), membership(ofTrack: copied)]
        XCTAssertEqual(memberships, [nil, regrouped.familyId])

        try await engine.undoBatch(regrouped.batchId)
        let restored = try await [membership(ofTrack: tracks[0]), membership(ofTrack: copied)]
        let copyLink = try await trackID(ofFile: copy)
        XCTAssertEqual(restored, [oldID, oldID])
        XCTAssertNil(copyLink)
    }

    func testAMatchOfANewCopyOfARetiredGroupedFileSeedsTheKeptTitle() async throws {
        let fingerprint = Data("reimported".utf8)
        let main = try await addTracks(count: 1)
        let original = try await addFile(title: "Song (Clean)", fingerprint: fingerprint)
        _ = try await service.create([.track(main[0]), .file(original)])
        let groupedLink = try await trackID(ofFile: original)
        let recording = try XCTUnwrap(groupedLink)
        try await retire(original)
        let copy = try await addFile(title: "Song (Clean)", fingerprint: fingerprint)

        _ = try await engine.apply(.applyMusicBrainzMatch(matchPayload(fileID: copy, fingerprintHash: Data(SHA256.hash(data: fingerprint)),
                                                                       currentFileTitle: "Song (Clean)")))
        let title = try await database.writer.read { connection in try TrackRecord.fetchOne(connection, key: recording)?.title }
        XCTAssertEqual(title, "Song (Clean)")
    }

    func testUndoingAGroupKeepsTheLinkOfAFileRetiredSince() async throws {
        let main = try await addTracks(count: 1)
        let clean = try await addFile(title: "Song (Clean)", fingerprint: Data("later-retired".utf8))
        let created = try await service.create([.track(main[0]), .file(clean)])
        let groupedLink = try await trackID(ofFile: clean)
        try await retire(clean)

        try await engine.undoBatch(created.batchId)
        let link = try await trackID(ofFile: clean)
        let mainMembership = try await membership(ofTrack: main[0])
        XCTAssertEqual(link, groupedLink)
        XCTAssertNil(mainMembership)
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

    private func addTrack(title: String, musicBrainzMatched: Bool, recordingMBID: String? = nil, fingerprintHash: Data? = nil,
                          withFile: Bool = true) async throws -> Int64
    {
        nextFingerprint += 1
        let hash = fingerprintHash ?? Data("track-\(nextFingerprint)".utf8)
        let mbid = recordingMBID ?? (musicBrainzMatched ? UUID().uuidString : nil)
        let trackID = try await database.writer.write { connection in
            var track = TrackRecord(fingerprintHash: hash, musicbrainzRecordingId: mbid, title: title)
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
            var file = FileRecord(path: self.audioFixture.path("/Music/S/\(inode).mp3"), volumeUuid: "volume", inode: inode, fileSize: 10, mtime: 10,
                                  chromaprintFingerprint: fingerprint, fingerprintStatus: fingerprint == nil ? .pending : .done,
                                  trackId: trackID, title: title)
            file.libraryMembership = .active
            file.fileAvailability = .available
            try self.audioFixture.prepare(&file)
            try file.insert(connection)
            return try XCTUnwrap(file.id)
        }
    }

    private func trackID(ofFile fileID: Int64) async throws -> Int64? {
        try await database.writer.read { connection in try FileRecord.fetchOne(connection, key: fileID)?.trackId }
    }

    private func row(_ fileID: Int64) async throws -> FileRecord {
        try await database.writer.read { connection in try XCTUnwrap(FileRecord.fetchOne(connection, key: fileID)) }
    }

    private func retire(_ fileID: Int64) async throws {
        let file = try await row(fileID)
        let retired = FileLibraryState(membership: .retired, availability: .missing, libraryID: nil, retiredAt: 1)
        _ = try await engine.apply(.setFileLibraryState(.init(fileId: fileID, expectedRevision: file.membershipRevision, state: retired)))
    }

    /// Another app rewrites the file in place; the scan observes the new content.
    private func replaceOnDisk(_ fileID: Int64) async throws {
        let file = try await row(fileID)
        try Data(repeating: 42, count: Int(file.fileSize) + 1).write(to: URL(fileURLWithPath: file.path))
        let identity = try FileMetadataCollector.collectVerified(at: file.path)
        _ = try await engine.apply(.observeFileIdentity(.init(fileId: fileID, expectedRevision: file.membershipRevision,
                                                              previousIdentity: file.identity, identity: identity)))
    }

    private func membership(ofTrack trackID: Int64) async throws -> Int64? {
        try await database.writer.read { connection in try TrackRecord.fetchOne(connection, key: trackID)?.workId }
    }
}
