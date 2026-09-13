import Foundation

// MARK: - AcoustID

/// Top-level payload from AcoustID's `/v2/lookup` endpoint.
public struct AcoustIDResponse: Codable, Equatable {
    let status: String
    let results: [AcoustIDResult]
}

/// One fingerprint match candidate from AcoustID, with the MusicBrainz
/// recording MBIDs it points to.
///
/// AcoustID nests recordings as `{ "id": <mbid> }` objects; we flatten
/// that to plain MBID strings on decode since nothing downstream needs
/// anything else AcoustID reports per recording.
public struct AcoustIDResult: Codable, Equatable {
    let id: String
    let score: Double
    let recordingIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case id, score, recordings
    }

    private struct RecordingRef: Codable {
        let id: String
    }

    public init(id: String, score: Double, recordingIDs: [String]) {
        self.id = id
        self.score = score
        self.recordingIDs = recordingIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        score = try container.decode(Double.self, forKey: .score)
        let recordings = try container.decodeIfPresent([RecordingRef].self, forKey: .recordings) ?? []
        recordingIDs = recordings.map(\.id)
    }

    public func encode(to encoder: Encoder) throws {
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
public struct MBRecording: Codable, Equatable {
    let title: String
    let artistCredit: [MBArtistCredit]
    let releases: [MBRelease]
    /// The earliest `firstReleaseDate` across every release's
    /// release-group — i.e. the *original* release year, not a
    /// reissue's or compilation's. There is no top-level `release-group`
    /// on a MusicBrainz recording resource (a recording can appear on
    /// releases from different release-groups); MusicBrainz nests
    /// `release-group` under each release instead, and does not return
    /// releases in date order, so this is computed as the minimum across
    /// `releases`, not decoded from any single JSON key or "first
    /// found". See `MBReleaseGroup.sortableFirstReleaseDate`.
    let releaseGroup: MBReleaseGroup?
    let isrcs: [String]

    public init(
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        artistCredit = try container.decodeIfPresent([MBArtistCredit].self, forKey: .artistCredit) ?? []
        releases = try container.decodeIfPresent([MBRelease].self, forKey: .releases) ?? []
        releaseGroup = releases
            .compactMap(\.releaseGroup)
            .min { $0.sortableFirstReleaseDate < $1.sortableFirstReleaseDate }
        isrcs = try container.decodeIfPresent([String].self, forKey: .isrcs) ?? []
    }
}

public struct MBArtistCredit: Codable, Equatable {
    let name: String
    let artist: MBArtist

    public init(name: String, artist: MBArtist) {
        self.name = name
        self.artist = artist
    }
}

public struct MBArtist: Codable, Equatable {
    let id: String
    let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One release a recording appears on. Detail fields are all optional —
/// MusicBrainz omits them for sparsely-cataloged releases.
public struct MBRelease: Codable, Equatable {
    let id: String
    let title: String
    let date: String?
    let country: String?
    let status: String?
    /// This release's own release-group, exactly as MusicBrainz nests
    /// it. Kept on every release (not collapsed into a single
    /// recording-level pick) so a consumer can compute the true
    /// "original year" — see `MBRecording.releaseGroup`, which is the
    /// earliest `firstReleaseDate` across all of these.
    let releaseGroup: MBReleaseGroup?

    public init(
        id: String,
        title: String,
        date: String? = nil,
        country: String? = nil,
        status: String? = nil,
        releaseGroup: MBReleaseGroup? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.country = country
        self.status = status
        self.releaseGroup = releaseGroup
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, date, country, status
        case releaseGroup = "release-group"
    }
}

/// A release-group's identity plus its `first-release-date`, the source
/// of `MatchCandidate.proposedYear`.
public struct MBReleaseGroup: Codable, Equatable {
    let id: String
    let firstReleaseDate: String?

    public init(id: String, firstReleaseDate: String?) {
        self.id = id
        self.firstReleaseDate = firstReleaseDate
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case firstReleaseDate = "first-release-date"
    }
}

private extension MBReleaseGroup {
    /// `firstReleaseDate` as a sortable `yyyymmdd`-shaped integer,
    /// tolerant of `YYYY`, `YYYY-MM`, and `YYYY-MM-DD` precision (a
    /// missing month or day defaults to `01`). A missing or unparsable
    /// date sorts last (`.max`), so it never wins a "find the earliest"
    /// comparison against a release-group that has a real date.
    var sortableFirstReleaseDate: Int {
        firstReleaseDate.flatMap(Self.parsedDateValue) ?? .max
    }

    static func parsedDateValue(_ dateString: String) -> Int? {
        let components = dateString.split(separator: "-")
        guard let year = components.first.flatMap({ Int($0) }) else { return nil }
        let month = components.count > 1 ? (Int(components[1]) ?? 1) : 1
        let day = components.count > 2 ? (Int(components[2]) ?? 1) : 1
        return year * 10000 + month * 100 + day
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
    /// Year from the earliest release-group's `first-release-date`
    /// (the original release, not a reissue); fixed once resolved,
    /// independent of which release is chosen.
    let proposedYear: Int?
}
