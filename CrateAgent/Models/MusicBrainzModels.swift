import Foundation

// MARK: - AcoustID

/// Top-level payload from AcoustID's `/v2/lookup` endpoint.
struct AcoustIDResponse: Codable, Equatable {
    let status: String
    let results: [AcoustIDResult]
}

/// One fingerprint match candidate from AcoustID, with the MusicBrainz
/// recording MBIDs it points to.
///
/// AcoustID nests recordings as `{ "id": <mbid> }` objects; we flatten
/// that to plain MBID strings on decode since nothing downstream needs
/// anything else AcoustID reports per recording.
struct AcoustIDResult: Codable, Equatable {
    let id: String
    let score: Double
    let recordingIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case id, score, recordings
    }

    private struct RecordingRef: Codable {
        let id: String
    }

    init(id: String, score: Double, recordingIDs: [String]) {
        self.id = id
        self.score = score
        self.recordingIDs = recordingIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        score = try container.decode(Double.self, forKey: .score)
        let recordings = try container.decodeIfPresent([RecordingRef].self, forKey: .recordings) ?? []
        recordingIDs = recordings.map(\.id)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(score, forKey: .score)
        try container.encode(recordingIDs.map(RecordingRef.init), forKey: .recordings)
    }
}

// MARK: - MusicBrainz

/// `GET /ws/2/recording/<mbid>?inc=releases+release-groups+artist-credits+isrcs`.
///
/// Decoding is lenient: a sparse response (no releases, no ISRCs, no
/// artist credit) never throws — every collection defaults to empty
/// and `releaseGroup` to nil.
struct MBRecording: Codable, Equatable {
    let title: String
    let artistCredit: [MBArtistCredit]
    let releases: [MBRelease]
    /// The release-group MusicBrainz treats as this recording's canonical
    /// dating source — see `ReleaseWire` below for why this isn't decoded
    /// directly from a top-level JSON key.
    let releaseGroup: MBReleaseGroup?
    let isrcs: [String]

    init(
        title: String,
        artistCredit: [MBArtistCredit],
        releases: [MBRelease],
        releaseGroup: MBReleaseGroup?,
        isrcs: [String]
    ) {
        self.title = title
        self.artistCredit = artistCredit
        self.releases = releases
        self.releaseGroup = releaseGroup
        self.isrcs = isrcs
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case artistCredit = "artist-credit"
        case releases
        case isrcs
    }

    /// MusicBrainz nests `release-group` under each release, not on the
    /// recording itself — a recording can appear on releases from
    /// different release-groups (original album vs. a compilation). This
    /// wire-only shape captures that nesting so we can derive
    /// `MBRecording.releaseGroup` (the first release's group) while
    /// keeping the public `MBRelease` release-detail-only, matching what
    /// downstream mutation code consumes.
    private struct ReleaseWire: Codable {
        let id: String
        let title: String
        let date: String?
        let country: String?
        let status: String?
        let releaseGroup: MBReleaseGroup?

        private enum CodingKeys: String, CodingKey {
            case id, title, date, country, status
            case releaseGroup = "release-group"
        }

        var release: MBRelease {
            MBRelease(id: id, title: title, date: date, country: country, status: status)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        artistCredit = try container.decodeIfPresent([MBArtistCredit].self, forKey: .artistCredit) ?? []
        let releaseWires = try container.decodeIfPresent([ReleaseWire].self, forKey: .releases) ?? []
        releases = releaseWires.map(\.release)
        releaseGroup = releaseWires.first { $0.releaseGroup != nil }?.releaseGroup
        isrcs = try container.decodeIfPresent([String].self, forKey: .isrcs) ?? []
    }
}

struct MBArtistCredit: Codable, Equatable {
    let name: String
    let artist: MBArtist
}

struct MBArtist: Codable, Equatable {
    let id: String
    let name: String
}

/// One release a recording appears on. Detail fields are all optional —
/// MusicBrainz omits them for sparsely-cataloged releases.
struct MBRelease: Codable, Equatable {
    let id: String
    let title: String
    let date: String?
    let country: String?
    let status: String?
}

/// A release-group's identity plus its `first-release-date`, the source
/// of `MatchCandidate.proposedYear`.
struct MBReleaseGroup: Codable, Equatable {
    let id: String
    let firstReleaseDate: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case firstReleaseDate = "first-release-date"
    }
}

// MARK: - MatchCandidate

/// A resolved, UI-ready MusicBrainz match for one file, assembled from an
/// `AcoustIDResult` plus the `MBRecording` it points to. Consumed by the
/// match-review UI and the mutation that writes tags (Tasks 9-14).
struct MatchCandidate: Equatable {
    let fileID: Int64
    /// AcoustID confidence, 0...1.
    let score: Double
    let acoustID: String?
    let recordingMBID: String
    let artistMBID: String?
    /// Mutable so "pick a different release" can update it without
    /// re-resolving the whole candidate.
    var chosenRelease: MBRelease
    let availableReleases: [MBRelease]
    let releaseMBID: String
    let isrc: String?
    // Proposed tag values shown to the user before applying the mutation.
    let proposedArtist: String
    let proposedTitle: String
    /// Follows `chosenRelease` — update together when the user picks a
    /// different release.
    var proposedAlbum: String
    /// Year from the release-group's `first-release-date`; fixed once
    /// resolved, independent of which release is chosen.
    let proposedYear: Int?
}
