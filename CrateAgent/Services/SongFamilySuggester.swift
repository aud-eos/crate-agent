import Foundation
import GRDB

/// One file in a suggested song family, with what the checklist shows.
public struct SongFamilySuggestedFile: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let title: String
    public let artist: String?
    public let length: String?
    public let labels: Set<VersionLabel>
    let membershipRevision: Int64

    public var versionLabel: String {
        VersionLabel.describe(labels)
    }

    var token: FileMembershipToken {
        FileMembershipToken(fileId: id, revision: membershipRevision)
    }
}

/// A recording a suggestion would group: the unit the checklist checks.
/// Most have one file; encodings already linked to one recording share it.
public struct SongFamilySuggestedRecording: Identifiable, Sendable, Equatable {
    public let id: String
    public let files: [SongFamilySuggestedFile]
}

/// Files that look like versions of one song. Nothing is grouped until the
/// user applies it.
public struct SongFamilySuggestion: Identifiable, Sendable, Equatable {
    public enum Confidence: Sendable, Equatable {
        /// Every two versions perform one MusicBrainz work or name different
        /// labels. Pre-checked.
        case high
        /// A near match: versions that repeat a label, or one that needs
        /// existing families merged. Unchecked.
        case medium
    }

    public enum Target: Sendable, Equatable {
        case newFamily
        /// Adds the recordings to an existing song family.
        case family(Int64)
        /// Merges `merged` into `family`, then adds the recordings.
        case merge(into: Int64, merged: [Int64])
    }

    /// The normalized artist and title stem the files share, or their
    /// artist and MusicBrainz work when no file has a stem.
    public let id: String
    public let title: String
    public let artist: String?
    public let confidence: Confidence
    public let target: Target
    /// What the suggestion adds, each checkable on its own.
    public let recordings: [SongFamilySuggestedRecording]
    /// Matching files already in the target families, shown for context.
    public let existingFiles: [SongFamilySuggestedFile]
}

/// The scan's result. `sameAudio` holds clusters of candidates left out
/// because they hold the same audio as each other: they are duplicates, not
/// versions, and the Duplicates review handles them.
public struct SongFamilySuggestions: Sendable, Equatable {
    public let suggestions: [SongFamilySuggestion]
    public let sameAudio: [[SongFamilySuggestedFile]]
    /// Candidates left out until fingerprinting identifies their recording.
    public let awaitingFingerprint: Int
}

/// The recordings the user kept checked in one suggestion.
public struct SongFamilySuggestionChoice: Sendable, Equatable {
    public let suggestion: SongFamilySuggestion
    public let recordingIds: Set<String>

    public init(suggestion: SongFamilySuggestion, recordingIds: Set<String>) {
        self.suggestion = suggestion
        self.recordingIds = recordingIds
    }
}

public enum SongFamilySuggestionError: LocalizedError, Equatable {
    case tooManyFamilies(limit: Int)

    public var errorDescription: String? {
        switch self {
        case let .tooManyFamilies(limit): FindVersionsMessages.batchLimit(limit)
        }
    }
}

/// Library's "Find Versions…": suggests song families across the library
/// and applies the confirmed ones through `SongFamilyService`, so every
/// family follows the normal grouping rules. See docs/song-families.md.
public struct SongFamilySuggester: Sendable {
    private let database: LibraryDatabase
    private let families: SongFamilyService

    public init(database: LibraryDatabase, families: SongFamilyService) {
        self.database = database
        self.families = families
    }

    /// The most families one apply groups. Grouping holds the writer for
    /// about 2 ms per family on the 30,000-file fixture, so this keeps one
    /// apply well within the 500 ms writer budget; group again for the rest.
    public static let maximumFamiliesPerApply = 100

    /// Reads the library once, off the main actor; WAL keeps Library browsable meanwhile.
    public func suggestions() async throws -> SongFamilySuggestions {
        try await database.writer.read { database in try Self.scan(in: database) }
    }

    /// Applies every choice as one History batch, undone in one step. A
    /// refused family refuses the batch, naming the file or recording.
    /// Returns the batch id, or nil when nothing was chosen.
    public func apply(_ choices: [SongFamilySuggestionChoice]) async throws -> String? {
        guard choices.count <= Self.maximumFamiliesPerApply else {
            throw SongFamilySuggestionError.tooManyFamilies(limit: Self.maximumFamiliesPerApply)
        }
        var requests: [SongFamilyChangeRequest] = []
        var authority: [FileMembershipToken] = []
        for choice in choices {
            let chosen = choice.suggestion.recordings.filter { recording in choice.recordingIds.contains(recording.id) }
            let members = chosen.compactMap { recording in recording.files.first.map { file in SongFamilyMember.file(file.id) } }
            authority += chosen.flatMap(\.files).map(\.token)
            switch choice.suggestion.target {
            case .newFamily:
                guard !members.isEmpty else { continue }
                requests.append(.create(members))
            case let .family(familyID):
                guard !members.isEmpty else { continue }
                requests.append(.attach(members, to: familyID))
            case let .merge(familyID, merged):
                requests.append(.merge(merged, into: familyID))
                if !members.isEmpty {
                    requests.append(.attach(members, to: familyID))
                }
            }
        }
        guard !requests.isEmpty else { return nil }
        return try await families.apply(requests, authority: authority)
    }

    // MARK: - Scan

    /// A processable file as the scan first reads it: no labels or
    /// fingerprint yet, so files that share no key cost only their key.
    private struct IndexedFile {
        let id: Int64
        let membershipRevision: Int64
        let path: String
        let title: String?
        let artist: String?
        let length: String?
        let trackID: Int64?
        let musicBrainzRecordingID: String?
        let musicBrainzWorkID: String?
        let familyID: Int64?
        let audioDigest: Data?
        let contentDigest: Data?
        let isFingerprinted: Bool
        let key: String?
        /// The normalized artist and the work, joining one artist's versions
        /// of a work whose titles differ.
        let workKey: String?
    }

    private struct Candidate {
        let file: SongFamilySuggestedFile
        let trackID: Int64?
        let musicBrainzRecordingID: String?
        let musicBrainzWorkID: String?
        let familyID: Int64?
        let audioDigest: Data?
        let contentDigest: Data?
        let isFingerprinted: Bool

        init(_ indexed: IndexedFile) {
            file = SongFamilySuggestedFile(id: indexed.id, title: indexed.title.flatMap { title in title.isEmpty ? nil : title }
                ?? (indexed.path as NSString).lastPathComponent, artist: indexed.artist, length: indexed.length,
                labels: VersionLabel.labels(in: indexed.title ?? ""), membershipRevision: indexed.membershipRevision)
            trackID = indexed.trackID
            musicBrainzRecordingID = indexed.musicBrainzRecordingID
            musicBrainzWorkID = indexed.musicBrainzWorkID
            familyID = indexed.familyID
            audioDigest = indexed.audioDigest
            contentDigest = indexed.contentDigest
            isFingerprinted = indexed.isFingerprinted
        }
    }

    /// A candidate placed on the recording grouping would resolve it to.
    private struct Placed {
        let candidate: Candidate
        let recordingKey: String
        let familyID: Int64?
        let versionKey: String
    }

    private static func scan(in database: GRDB.Database) throws -> SongFamilySuggestions {
        let groups = try candidateGroups(indexedFiles(in: database))
        let unlinked = groups.values.joined().filter { candidate in candidate.trackID == nil && candidate.isFingerprinted }.map(\.file.id)
        let fingerprints = try fingerprintHashes(of: unlinked, in: database)
        let fingerprintTracks = try tracks(matching: Set(fingerprints.values), in: database)
        var suggestions: [SongFamilySuggestion] = []
        var sameAudio: [[SongFamilySuggestedFile]] = []
        var awaitingFingerprint = 0
        for (key, members) in groups {
            var placed: [Placed] = []
            var unplaced: [Data: [Candidate]] = [:]
            for candidate in members {
                if let trackID = candidate.trackID {
                    placed.append(Placed(candidate: candidate, recordingKey: "track:\(trackID)", familyID: candidate.familyID,
                                         versionKey: candidate.musicBrainzRecordingID ?? "track:\(trackID)"))
                } else if let hash = fingerprints[candidate.file.id] {
                    unplaced[hash, default: []].append(candidate)
                } else {
                    awaitingFingerprint += 1
                }
            }
            var excluded: [[Candidate]] = []
            for (hash, sharing) in unplaced {
                let track = fingerprintTracks[hash]
                // Grouping links each unlinked file to the recording its
                // fingerprint names, and refuses one another file claims.
                if sharing.count > 1 || track?.isClaimed == true {
                    let claimants = track.map { track in placed.filter { member in member.recordingKey == "track:\(track.id)" }.map(\.candidate) } ?? []
                    excluded.append(sharing + claimants)
                } else if let track {
                    placed.append(Placed(candidate: sharing[0], recordingKey: "track:\(track.id)", familyID: track.familyID,
                                         versionKey: track.musicBrainzRecordingID ?? "track:\(track.id)"))
                } else {
                    placed.append(Placed(candidate: sharing[0], recordingKey: "fingerprint:\(hash.base64EncodedString())", familyID: nil,
                                         versionKey: "fingerprint:\(hash.base64EncodedString())"))
                }
            }
            let excludedIDs = Set(excluded.joined().map(\.file.id))
            let (kept, identical) = separatingSameAudio(placed.filter { member in !excludedIDs.contains(member.candidate.file.id) })
            sameAudio += (excluded + identical).map { cluster in cluster.map(\.file).sorted { lhs, rhs in lhs.id < rhs.id } }
            if let suggestion = suggestion(key: key, members: kept) {
                suggestions.append(suggestion)
            }
        }
        suggestions.sort { lhs, rhs in
            (lhs.confidence == .high ? 0 : 1, lhs.artist ?? "", lhs.title, lhs.id) < (rhs.confidence == .high ? 0 : 1, rhs.artist ?? "", rhs.title, rhs.id)
        }
        sameAudio.sort { lhs, rhs in (lhs.first?.id ?? 0) < (rhs.first?.id ?? 0) }
        return SongFamilySuggestions(suggestions: suggestions, sameAudio: sameAudio, awaitingFingerprint: awaitingFingerprint)
    }

    /// Files sharing an artist and title stem, or an artist and a
    /// MusicBrainz work, joined transitively. A file without work data still
    /// joins by its stem. Groups are keyed by their smallest stem key, or by
    /// a work key when no member has a stem.
    private static func candidateGroups(_ files: [IndexedFile]) -> [String: [Candidate]] {
        var groups: [String: [IndexedFile]] = [:]
        for file in files {
            if let key = file.key ?? file.workKey {
                groups[key, default: []].append(file)
            }
        }
        // Only the few groups holding works are joined, so the scan stays one
        // pass over a library without work data.
        var joinedInto: [String: String] = [:]
        func root(of key: String) -> String {
            var current = key
            while let next = joinedInto[current] {
                current = next
            }
            return current
        }
        var groupByWork: [String: String] = [:]
        for file in files {
            guard let workKey = file.workKey, let groupKey = file.key ?? file.workKey else { continue }
            guard let earlier = groupByWork[workKey] else {
                groupByWork[workKey] = groupKey
                continue
            }
            let (first, second) = (root(of: groupKey), root(of: earlier))
            guard first != second else { continue }
            let ordered = [first, second].sorted { lhs, rhs in
                (lhs.hasPrefix(workKeyPrefix) ? 1 : 0, lhs) < (rhs.hasPrefix(workKeyPrefix) ? 1 : 0, rhs)
            }
            joinedInto[ordered[1]] = ordered[0]
        }
        for joined in joinedInto.keys {
            groups[root(of: joined), default: []] += groups.removeValue(forKey: joined) ?? []
        }
        return groups.filter { _, members in members.count > 1 }.mapValues { members in members.map(Candidate.init) }
    }

    /// Normalized words hold only letters and digits, so no stem key has it.
    private static let workKeyPrefix = "work:"

    private static func indexedFiles(in database: GRDB.Database) throws -> [IndexedFile] {
        try Row.fetchAll(database, sql: """
        WITH live_families AS (\(SongFamilyMutation.liveFamiliesSQL))
        SELECT files.id, files.path, files.membership_revision, COALESCE(files.title, tracks.title) AS title,
               COALESCE(files.artist, tracks.artist) AS artist, files.length, files.track_id,
               tracks.musicbrainz_recording_id AS recording_mbid, tracks.musicbrainz_work_id AS work_mbid, live_families.family_id,
               files.fingerprint_status = '\(FingerprintStatus.done.rawValue)' AND files.chromaprint_fingerprint IS NOT NULL AS fingerprinted,
               \(DuplicateDigestStore.confirmingDigestColumn(.audio, of: "audio_cache")) AS audio_digest,
               \(DuplicateDigestStore.confirmingDigestColumn(.content, of: "content_cache")) AS content_digest
        FROM files LEFT JOIN tracks ON tracks.id = files.track_id
        LEFT JOIN live_families ON live_families.family_id = tracks.work_id
        \(DuplicateDigestStore.freshJoinSQL(.audio, as: "audio_cache"))
        \(DuplicateDigestStore.freshJoinSQL(.content, as: "content_cache"))
        WHERE \(FileProcessingEligibility.processableSQL)
        """).map { row in
            let title: String? = row["title"]
            let artist: String? = row["artist"]
            let workID: String? = row["work_mbid"]
            let workKey = workID.flatMap { workID in artist.flatMap(normalizedArtist).map { normalized in workKeyPrefix + normalized + "\n" + workID } }
            return IndexedFile(id: row["id"], membershipRevision: row["membership_revision"], path: row["path"], title: title, artist: artist,
                               length: row["length"], trackID: row["track_id"], musicBrainzRecordingID: row["recording_mbid"],
                               musicBrainzWorkID: workID, familyID: row["family_id"], audioDigest: row["audio_digest"],
                               contentDigest: row["content_digest"], isFingerprinted: row["fingerprinted"], key: key(artist: artist, title: title),
                               workKey: workKey)
        }
    }

    /// The current recording key of each unlinked candidate that has one,
    /// by the rule grouping links with. Reads fingerprints of candidates only.
    private static func fingerprintHashes(of fileIDs: [Int64], in database: GRDB.Database) throws -> [Int64: Data] {
        try RecordingIdentity.keys(ofFiles: fileIDs, in: database)
    }

    private struct FingerprintTrack {
        let id: Int64
        let musicBrainzRecordingID: String?
        let familyID: Int64?
        /// An identity source or a file in the library already claims it.
        let isClaimed: Bool
    }

    private static func tracks(matching hashes: Set<Data>, in database: GRDB.Database) throws -> [Data: FingerprintTrack] {
        guard !hashes.isEmpty else { return [:] }
        let tracks = try TrackRecord.filter(hashes.contains(Column("fingerprint_hash"))).fetchAll(database)
        let liveFamilies = try Set(Int64.fetchAll(database, sql: "SELECT family_id FROM (\(SongFamilyMutation.liveFamiliesSQL))"))
        return try tracks.reduce(into: [:]) { byHash, track in
            guard let trackID = track.id else { return }
            let referenced = try FileRecord.filter(Column("track_id") == trackID).filter(sql: FileProcessingEligibility.activeSQL).fetchCount(database) > 0
            byHash[track.fingerprintHash] = FingerprintTrack(id: trackID, musicBrainzRecordingID: track.musicbrainzRecordingId,
                                                             familyID: track.workId.flatMap { familyID in liveFamilies.contains(familyID) ? familyID : nil },
                                                             isClaimed: track.hasRecordingIdentity || referenced)
        }
    }

    /// Splits off recordings holding identical decoded audio or bytes as
    /// another recording (by the duplicate digest cache), and recordings whose
    /// own files disagree on their labels: both are duplicates, not versions.
    private static func separatingSameAudio(_ members: [Placed]) -> (kept: [Placed], sameAudio: [[Candidate]]) {
        var root: [String: String] = [:]
        func find(_ key: String) -> String {
            var current = key
            while let parent = root[current], parent != current {
                current = parent
            }
            return current
        }
        for member in members {
            root[member.recordingKey] = root[member.recordingKey] ?? member.recordingKey
        }
        var owners: [Data: String] = [:]
        for member in members {
            for digest in [member.candidate.audioDigest, member.candidate.contentDigest].compactMap(\.self) {
                if let owner = owners[digest] {
                    root[find(member.recordingKey)] = find(owner)
                } else {
                    owners[digest] = member.recordingKey
                }
            }
        }
        let clusters = Dictionary(grouping: members) { member in find(member.recordingKey) }
        var kept: [Placed] = []
        var sameAudio: [[Candidate]] = []
        for cluster in clusters.values {
            let recordings = Set(cluster.map(\.recordingKey))
            if recordings.count > 1 || Set(cluster.map(\.candidate.file.labels)).count > 1 {
                sameAudio.append(cluster.map(\.candidate))
            } else {
                kept += cluster
            }
        }
        return (kept, sameAudio)
    }

    private static func suggestion(key: String, members: [Placed]) -> SongFamilySuggestion? {
        let familyIDs = Set(members.compactMap(\.familyID))
        guard Set(members.map(\.versionKey)).count >= 2 else { return nil }
        let target: SongFamilySuggestion.Target
        if familyIDs.isEmpty {
            target = .newFamily
        } else if familyIDs.count == 1, let familyID = familyIDs.first {
            target = .family(familyID)
        } else {
            let sizes = Dictionary(grouping: members.compactMap(\.familyID)) { familyID in familyID }.mapValues(\.count)
            guard let into = familyIDs.min(by: { lhs, rhs in (-(sizes[lhs] ?? 0), lhs) < (-(sizes[rhs] ?? 0), rhs) }) else { return nil }
            target = .merge(into: into, merged: familyIDs.subtracting([into]).sorted())
        }
        let adding = members.filter { member in member.familyID == nil }
        if case .family = target, adding.isEmpty {
            return nil
        }
        let recordings = Dictionary(grouping: adding, by: \.recordingKey).map { recordingKey, files in
            SongFamilySuggestedRecording(id: recordingKey, files: files.map(\.candidate.file).sorted { lhs, rhs in lhs.id < rhs.id })
        }.sorted { lhs, rhs in (lhs.files.first?.id ?? 0) < (rhs.files.first?.id ?? 0) }
        let versions = Dictionary(grouping: members, by: \.versionKey).values.map { version in
            (labels: Set(version.map(\.candidate.file.labels)), workID: version.lazy.compactMap(\.candidate.musicBrainzWorkID).first)
        }
        let versionsDistinct = versions.allSatisfy { version in version.labels.count == 1 } && versions.indices.allSatisfy { first in
            versions.indices.filter { second in second > first }.allSatisfy { second in
                versions[first].workID.map { workID in workID == versions[second].workID } == true || versions[first].labels != versions[second].labels
            }
        }
        let shown = members.map(\.candidate.file).min { lhs, rhs in
            (SongFamilyRepresentative.rank(title: lhs.title, isMusicBrainzMatched: false), lhs.id)
                < (SongFamilyRepresentative.rank(title: rhs.title, isMusicBrainzMatched: false), rhs.id)
        }
        guard let shown else { return nil }
        let isMerge = if case .merge = target {
            true
        } else {
            false
        }
        return SongFamilySuggestion(
            id: key, title: shown.title, artist: shown.artist, confidence: versionsDistinct && !isMerge ? .high : .medium, target: target,
            recordings: recordings,
            existingFiles: members.filter { member in member.familyID != nil }.map(\.candidate.file).sorted { lhs, rhs in lhs.id < rhs.id }
        )
    }

    // MARK: - Normalization

    /// A featured credit and everything after it. Artists also treat "&" as
    /// one; titles don't ("Rock & Roll").
    private static let featuredArtistCredit = try? NSRegularExpression(pattern: #"\s(feat\.?|ft\.?|featuring|&)\s.*$"#, options: .caseInsensitive)
    private static let featuredTitleCredit = try? NSRegularExpression(pattern: #"\s(feat\.?|ft\.?|featuring)\s.*$"#, options: .caseInsensitive)
    private static let featuredCreditWords: Set<String> = ["feat", "ft", "featuring"]

    /// The normalized artist and title stem files of one song share, or nil
    /// without both. The stem drops every annotation naming a version
    /// (`VersionLabel`) or a featured artist; both sides drop featured
    /// artists, punctuation, case and diacritics.
    static func key(artist: String?, title: String?) -> String? {
        guard let artist, let title, let normalizedArtist = normalizedArtist(artist) else { return nil }
        let stem = TitleMatcher.removingAnnotations(from: title) { segment in
            VersionLabel.namesVersion(segment) || featuredCreditWords.contains(words(segment).first ?? "")
        }
        let normalizedStem = words(removing(featuredTitleCredit, from: stem))
        guard !normalizedStem.isEmpty else { return nil }
        return normalizedArtist + "\n" + normalizedStem.joined(separator: " ")
    }

    private static func normalizedArtist(_ artist: String) -> String? {
        let normalized = words(removing(featuredArtistCredit, from: artist))
        return normalized.isEmpty ? nil : normalized.joined(separator: " ")
    }

    private static func removing(_ pattern: NSRegularExpression?, from text: String) -> String {
        pattern?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "") ?? text
    }

    private static func words(_ text: String) -> [String] {
        ListSearch.normalized(text).split { character in !(character.isLetter || character.isNumber) }.map(String.init)
    }
}
