@testable import CrateAgent
import XCTest

final class MusicBrainzModelsTests: XCTestCase {
    /// Loads a fixture file from `CrateAgentTests/Fixtures`, which
    /// xcodegen wires into the test bundle as a resource.
    private func fixture(_ name: String) -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            XCTFail("Missing fixture: \(name)")
            return Data()
        }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    // MARK: - MBRecording

    func testParsesMultiReleaseRecording() throws {
        let data = fixture("mb_recording.json")
        let recording = try JSONDecoder().decode(MBRecording.self, from: data)

        XCTAssertEqual(recording.title, "Voodoo Ray")
        XCTAssertGreaterThan(recording.releases.count, 1)
        XCTAssertNotNil(recording.releaseGroup?.firstReleaseDate)
        XCTAssertFalse(recording.isrcs.isEmpty)
    }

    func testRecordingArtistCreditAndReleaseDetails() throws {
        let recording = try JSONDecoder().decode(MBRecording.self, from: fixture("mb_recording.json"))

        XCTAssertEqual(recording.artistCredit.first?.name, "A Guy Called Gerald")
        XCTAssertEqual(recording.artistCredit.first?.artist.id, "3d232476-51f7-4c30-8b1b-3f2f6f4d1a2c")

        // The fixture lists the 2011 remaster before the 1988 original —
        // MusicBrainz does not return releases date-ordered.
        let remaster = try XCTUnwrap(recording.releases.first)
        XCTAssertEqual(remaster.id, "e2f3a4b5-2222-3333-4444-555566667777")
        XCTAssertEqual(remaster.date, "2011-03-01")
        XCTAssertEqual(remaster.country, "GB")
        XCTAssertEqual(remaster.status, "Official")

        XCTAssertEqual(recording.isrcs, ["GBAAA8800001", "GBAAA8800002"])
    }

    func testEachReleaseCarriesItsOwnReleaseGroup() throws {
        let recording = try JSONDecoder().decode(MBRecording.self, from: fixture("mb_recording.json"))

        XCTAssertEqual(recording.releases[0].releaseGroup?.id, "9f8e7d6c-9999-8888-7777-666655554444")
        XCTAssertEqual(recording.releases[0].releaseGroup?.firstReleaseDate, "2011-03-01")
        XCTAssertEqual(recording.releases[1].releaseGroup?.id, "c7d8e9f0-aaaa-bbbb-cccc-ddddeeeeffff")
        XCTAssertEqual(recording.releases[1].releaseGroup?.firstReleaseDate, "1988-05-09")
    }

    func testRecordingReleaseGroupIsEarliestAcrossReleasesNotFirstInArray() throws {
        let recording = try JSONDecoder().decode(MBRecording.self, from: fixture("mb_recording.json"))

        // The 1988 original's release-group must win even though the 2011
        // remaster is listed first in "releases" — the original release
        // year, not a reissue's, is what downstream tagging needs.
        XCTAssertEqual(recording.releaseGroup?.id, "c7d8e9f0-aaaa-bbbb-cccc-ddddeeeeffff")
        XCTAssertEqual(recording.releaseGroup?.firstReleaseDate, "1988-05-09")
    }

    func testRecordingWithNoISRC() throws {
        let recording = try JSONDecoder().decode(MBRecording.self, from: fixture("mb_recording_no_isrc.json"))

        XCTAssertTrue(recording.isrcs.isEmpty)
        XCTAssertEqual(recording.releases.count, 1)
        XCTAssertEqual(recording.releaseGroup?.firstReleaseDate, "1995-01-01")
    }

    // MARK: - B4: full artist credit

    func testCreditedArtistNameJoinsMultipleCreditsInOrder() {
        let recording = MBRecording(
            title: "Collab Track",
            artistCredit: [
                MBArtistCredit(name: "A", artist: MBArtist(id: "artist-a", name: "A"), joinPhrase: " feat. "),
                MBArtistCredit(name: "B", artist: MBArtist(id: "artist-b", name: "B"), joinPhrase: ""),
            ],
            releases: [],
            releaseGroup: nil,
            isrcs: []
        )

        XCTAssertEqual(recording.creditedArtistName, "A feat. B")
    }

    func testCreditedArtistNameWithSingleCreditIsJustTheName() {
        let recording = MBRecording(
            title: "Solo Track",
            artistCredit: [MBArtistCredit(name: "Solo Artist", artist: MBArtist(id: "artist-1", name: "Solo Artist"))],
            releases: [],
            releaseGroup: nil,
            isrcs: []
        )

        XCTAssertEqual(recording.creditedArtistName, "Solo Artist")
    }

    func testCreditedArtistNameWithNoCreditsIsEmpty() {
        let recording = MBRecording(
            title: "Untitled",
            artistCredit: [],
            releases: [],
            releaseGroup: nil,
            isrcs: []
        )

        XCTAssertEqual(recording.creditedArtistName, "")
    }

    func testDecodesJoinPhraseFromArtistCreditJSON() throws {
        let recording = try JSONDecoder().decode(MBRecording.self, from: fixture("mb_recording_multi_artist.json"))

        XCTAssertEqual(recording.artistCredit.count, 2)
        XCTAssertEqual(recording.artistCredit[0].joinPhrase, " feat. ")
        XCTAssertEqual(recording.artistCredit[1].joinPhrase, "")
        XCTAssertEqual(recording.creditedArtistName, "Artist One feat. Artist Two")
    }

    func testJoinPhraseDefaultsToEmptyWhenAbsentFromJSON() throws {
        // mb_recording.json's single-element artist-credit has no
        // "joinphrase" key at all — decoding must default to "", not throw.
        let recording = try JSONDecoder().decode(MBRecording.self, from: fixture("mb_recording.json"))

        XCTAssertEqual(recording.artistCredit.first?.joinPhrase, "")
    }

    // MARK: - AcoustIDResponse

    func testEmptyAcoustIDResults() throws {
        let response = try JSONDecoder().decode(AcoustIDResponse.self, from: fixture("acoustid_empty.json"))

        XCTAssertEqual(response.status, "ok")
        XCTAssertTrue(response.results.isEmpty)
    }

    func testParsesMultipleAcoustIDResults() throws {
        // Deliberately NOT in score-descending order in the fixture —
        // `AcoustIDResponse` decoding preserves raw JSON array order
        // as-is; sorting is `AcoustIDClient`'s job, not the model's.
        let response = try JSONDecoder().decode(AcoustIDResponse.self, from: fixture("acoustid_multi.json"))

        XCTAssertEqual(response.results.count, 2)

        let first = try XCTUnwrap(response.results.first)
        XCTAssertEqual(first.id, "1cbano2a-04a6-4b12-9a12-1234567890ab")
        XCTAssertEqual(first.score, 0.71)
        XCTAssertEqual(first.recordingIDs, ["b2c3d4e5-2345-4b5c-9d0e-1f2a3b4c5d6e"])

        let second = response.results[1]
        XCTAssertEqual(second.id, "9ff43b6a-4f16-427c-93c2-92307ca505e0")
        XCTAssertEqual(second.score, 0.93)
        XCTAssertEqual(second.recordingIDs, [
            "f3d1e2a0-5b2b-4b8e-9b8a-7a3e2f8c9d10",
            "a1b2c3d4-1234-4a5b-8c9d-0e1f2a3b4c5d",
        ])
    }

    // MARK: - MatchCandidate

    func testMatchCandidateHoldsResolvedFieldsAndSupportsReleasePicking() {
        let releaseA = MBRelease(id: "release-a", title: "Album A", date: "1988", country: "GB", status: "Official")
        let releaseB = MBRelease(id: "release-b", title: "Album B", date: "1988-06", country: "GB", status: "Official")

        var candidate = MatchCandidate(
            fileID: 42,
            evidence: .fingerprint(acoustID: "9ff43b6a-4f16-427c-93c2-92307ca505e0", score: 0.93),
            recordingMBID: "f3d1e2a0-5b2b-4b8e-9b8a-7a3e2f8c9d10",
            artistMBID: "3d232476-51f7-4c30-8b1b-3f2f6f4d1a2c",
            fingerprintHash: Data([0x01, 0x02, 0x03, 0x04]),
            expectedFileSize: 5_000_000,
            expectedMtime: 1_700_000_000,
            chosenRelease: releaseA,
            availableReleases: [releaseA, releaseB],
            isrc: "GBAAA8800001",
            proposedArtist: "A Guy Called Gerald",
            proposedTitle: "Voodoo Ray",
            proposedAlbum: releaseA.title,
            proposedYear: 1988,
            currentFileYear: nil,
            currentFileArtist: nil,
            currentFileTitle: nil,
            currentFileAlbum: nil
        )

        XCTAssertEqual(candidate.availableReleases.count, 2)

        // Picking a different release updates the mutable fields that
        // follow it; the resolved identity fields stay fixed.
        candidate.chosenRelease = releaseB
        candidate.proposedAlbum = releaseB.title

        XCTAssertEqual(candidate.chosenRelease.id, "release-b")
        XCTAssertEqual(candidate.proposedAlbum, "Album B")
        XCTAssertEqual(candidate.recordingMBID, "f3d1e2a0-5b2b-4b8e-9b8a-7a3e2f8c9d10")
    }

    // MARK: - E-A: unavailable artist credit is nil, never blank

    func testMatchCandidateAllowsNilProposedArtistForSparseCredit() {
        let release = MBRelease(id: "release-a", title: "Album A", date: "1988", country: "GB", status: "Official")

        let candidate = MatchCandidate(
            fileID: 42,
            evidence: .fingerprint(acoustID: "acoustid-1", score: 0.93),
            recordingMBID: "recording-1",
            artistMBID: nil,
            fingerprintHash: Data([0x01, 0x02, 0x03, 0x04]),
            expectedFileSize: 5_000_000,
            expectedMtime: 1_700_000_000,
            chosenRelease: release,
            availableReleases: [release],
            isrc: nil,
            proposedArtist: nil,
            proposedTitle: "Untitled",
            proposedAlbum: release.title,
            proposedYear: nil,
            currentFileYear: nil,
            currentFileArtist: nil,
            currentFileTitle: nil,
            currentFileAlbum: nil
        )

        XCTAssertNil(candidate.proposedArtist)
        XCTAssertNil(candidate.artistMBID)
    }
}
