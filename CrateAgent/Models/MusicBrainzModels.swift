import Foundation

// MARK: - AcoustID

/// Top-level payload from AcoustID's `/v2/lookup` endpoint.
///
/// A failure response (`status: "error"`) omits `results` entirely and
/// instead carries an `error` object — both are decoded leniently
/// (`results` defaulting to empty) so a failure body decodes cleanly
/// instead of throwing before the caller can inspect `status`/`error`.
public struct AcoustIDResponse: Codable, Equatable {
    let status: String
    let results: [AcoustIDResult]
    let error: AcoustIDErrorPayload?

    public init(status: String, results: [AcoustIDResult], error: AcoustIDErrorPayload? = nil) {
        self.status = status
        self.results = results
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        results = try container.decodeIfPresent([AcoustIDResult].self, forKey: .results) ?? []
        error = try container.decodeIfPresent(AcoustIDErrorPayload.self, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case status, results, error
    }
}

/// The in-body error object AcoustID sends alongside `"status": "error"`.
public struct AcoustIDErrorPayload: Codable, Equatable {
    let code: Int
    let message: String
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

public struct MBRecordingDetails: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let creditedArtistName: String
    let disambiguation: String?
    let durationMilliseconds: Int?

    init(id: String, title: String, creditedArtistName: String, disambiguation: String?, durationMilliseconds: Int?) {
        self.id = id
        self.title = title
        self.creditedArtistName = creditedArtistName
        self.disambiguation = disambiguation
        self.durationMilliseconds = durationMilliseconds
    }

    init(recording: MBRecording, requestedID: String) {
        self.init(id: recording.id ?? requestedID, title: recording.title,
                  creditedArtistName: recording.creditedArtistName, disambiguation: recording.disambiguation,
                  durationMilliseconds: recording.durationMilliseconds)
    }
}

/// `GET /ws/2/recording/<mbid>?inc=releases+release-groups+artist-credits+isrcs`.
///
/// Decoding is lenient: a sparse response (no releases, no ISRCs, no
/// artist credit) never throws — every collection defaults to empty
/// and `releaseGroup` to nil.
public struct MBRecording: Codable, Equatable {
    let id: String?
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
    let disambiguation: String?
    let durationMilliseconds: Int?

    public init(
        title: String,
        artistCredit: [MBArtistCredit],
        releases: [MBRelease],
        releaseGroup: MBReleaseGroup?,
        isrcs: [String],
        id: String? = nil,
        disambiguation: String? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.artistCredit = artistCredit
        self.releases = releases
        self.releaseGroup = releaseGroup
        self.isrcs = isrcs
        self.disambiguation = disambiguation
        self.durationMilliseconds = durationMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, disambiguation
        case durationMilliseconds = "length"
        case artistCredit = "artist-credit"
        case releases
        case isrcs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artistCredit = try container.decodeIfPresent([MBArtistCredit].self, forKey: .artistCredit) ?? []
        releases = try container.decodeIfPresent([MBRelease].self, forKey: .releases) ?? []
        releaseGroup = Self.earliestReleaseGroup(in: releases)
        isrcs = try container.decodeIfPresent([String].self, forKey: .isrcs) ?? []
        disambiguation = try container.decodeIfPresent(String.self, forKey: .disambiguation)
        durationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds)
    }

    func replacingReleases(with releases: [MBRelease]) -> MBRecording {
        MBRecording(title: title, artistCredit: artistCredit, releases: releases,
                    releaseGroup: Self.earliestReleaseGroup(in: releases), isrcs: isrcs, id: id,
                    disambiguation: disambiguation, durationMilliseconds: durationMilliseconds)
    }

    private static func earliestReleaseGroup(in releases: [MBRelease]) -> MBReleaseGroup? {
        releases.compactMap(\.releaseGroup)
            .min { $0.sortableFirstReleaseDate < $1.sortableFirstReleaseDate }
    }

    /// The full, ordered multi-artist credit as MusicBrainz displays it —
    /// e.g. `"Artist A feat. Artist B"` — assembled by concatenating each
    /// credit's `name` with its `joinPhrase` in array order. Empty when
    /// `artistCredit` is empty. Use this (not `artistCredit.first?.name`)
    /// for any user-facing artist display name; `artistCredit.first`
    /// remains the right source for the *lead* artist's MBID.
    var creditedArtistName: String {
        artistCredit.map { $0.name + $0.joinPhrase }.joined()
    }
}

public struct MBArtistCredit: Codable, Equatable {
    let name: String
    let artist: MBArtist
    /// The literal text MusicBrainz inserts after this credit to join it
    /// to the next one in the array (" feat. ", " & ", ", ", …), or `""`
    /// for the last (or only) credit. See `MBRecording.creditedArtistName`,
    /// which concatenates `name + joinPhrase` across the whole array to
    /// assemble the full multi-artist display name.
    let joinPhrase: String

    public init(name: String, artist: MBArtist, joinPhrase: String = "") {
        self.name = name
        self.artist = artist
        self.joinPhrase = joinPhrase
    }

    private enum CodingKeys: String, CodingKey {
        case name, artist
        case joinPhrase = "joinphrase"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        artist = try container.decode(MBArtist.self, forKey: .artist)
        joinPhrase = try container.decodeIfPresent(String.self, forKey: .joinPhrase) ?? ""
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
        firstReleaseDate.flatMap(parsedMusicBrainzDateValue) ?? .max
    }
}

/// Parses a MusicBrainz partial date (`YYYY`, `YYYY-MM`, or `YYYY-MM-DD`)
/// into a sortable `yyyymmdd`-shaped integer (a missing month or day
/// defaults to `01`); returns `nil` for an unparsable string. Shared by
/// every "find the earliest date" comparison in this module —
/// `MBReleaseGroup.sortableFirstReleaseDate` and `ReleaseSelector`'s
/// release-date sort both use it, so date tolerance lives in one place.
func parsedMusicBrainzDateValue(_ dateString: String) -> Int? {
    let components = dateString.split(separator: "-")
    guard let year = components.first.flatMap({ Int($0) }) else { return nil }
    let month = components.count > 1 ? (Int(components[1]) ?? 1) : 1
    let day = components.count > 2 ? (Int(components[2]) ?? 1) : 1
    return year * 10000 + month * 100 + day
}

// MARK: - MatchCandidate

/// A resolved, UI-ready MusicBrainz match for one file, assembled from an
/// `AcoustIDResult` plus the `MBRecording` it points to. Consumed by the
/// match-review UI and the mutation that writes tags (Tasks 9-14).
struct MatchCandidate: Equatable {
    let fileID: Int64
    /// How this recording was found; only fingerprint evidence carries an
    /// AcoustID identifier or confidence.
    let evidence: MatchEvidence
    /// The evidence's own 0...1 score (AcoustID confidence, or text
    /// similarity for a metadata search).
    var score: Double {
        evidence.rankingScore
    }

    var acoustID: String? {
        evidence.acoustID
    }

    let recordingMBID: String
    let artistMBID: String?
    /// SHA-256 of the file's stored Chromaprint fingerprint bytes — the
    /// value `ApplyMusicBrainzMatchPayload.fingerprintHash` needs to key
    /// the canonical `tracks` row (invariant #4). Computed once by
    /// `AutoTaggerService` alongside the rest of the candidate so the
    /// review UI never has to re-derive it.
    let fingerprintHash: Data
    /// The file's on-disk identity as read at lookup time. Threaded into
    /// `ApplyMusicBrainzMatchPayload` so Apply can reject a candidate that went
    /// stale between review and Apply (finding D-A, #118).
    let expectedFreshness: FileFreshnessSnapshot
    /// Mutable so "pick a different release" can update it without
    /// re-resolving the whole candidate.
    var chosenRelease: MBRelease
    let availableReleases: [MBRelease]
    let isrc: String?
    // Proposed tag values shown to the user before applying the mutation.
    /// `nil` when MusicBrainz's recording has an empty `artist-credit` —
    /// there is nothing to propose. Never an empty string: a sparse
    /// recording must never look like a proposal to blank the artist
    /// (see `AutoTagRowModel.includeArtist`, which mirrors `includeYear`'s
    /// "nil proposal never defaults to included" rule).
    let proposedArtist: String?
    let proposedTitle: String
    /// Follows `chosenRelease` — update together when the user picks a
    /// different release.
    var proposedAlbum: String
    /// Year from the earliest release-group's `first-release-date`
    /// (the original release, not a reissue); fixed once resolved,
    /// independent of which release is chosen.
    let proposedYear: Int?
    /// The file's year tag as read directly off disk (`AudioTags.year`,
    /// already fetched by `AutoTaggerService` for the track duration —
    /// no extra I/O). This is the honest "current" year for the review
    /// diff: unlike `tracks.year`, it's populated even on a greenfield
    /// first-pass match, before any `tracks` row exists for this file.
    let currentFileYear: Int?
    /// The file's embedded artist/title/album tags read off disk at lookup
    /// time (`AudioTags`). Threaded into the payload so undo restores the
    /// file's ORIGINAL embedded tags, not the Serato-imported DB snapshot
    /// (finding D-D).
    let currentFileArtist: String?
    let currentFileTitle: String?
    let currentFileAlbum: String?
}
