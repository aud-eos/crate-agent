import Foundation
import GRDB

/// One recording in a song family, with the display values of its files.
public struct SongFamilyMemberSummary: Equatable, Sendable {
    public let trackId: Int64
    public let title: String?
    public let artist: String?
    public let musicBrainzRecordingId: String?
    /// Every file encoding this recording; several encodings are one version.
    public let fileIds: [Int64]
    /// Whether any of its files is active in the library and present on disk.
    public let isAvailable: Bool

    public var isMusicBrainzMatched: Bool {
        musicBrainzRecordingId != nil
    }

    /// Recordings that share a MusicBrainz recording are one version.
    var versionKey: String {
        musicBrainzRecordingId ?? "track:\(trackId)"
    }
}

public struct SongFamily: Equatable, Sendable, Identifiable {
    public let id: Int64
    /// The user's manual main-version choice, kept even while it is unavailable.
    public let savedRepresentativeTrackId: Int64?
    /// The member shown for the family right now (`SongFamilyRepresentative`).
    public let representativeTrackId: Int64
    /// The representative first, then the alternates by recording id, with
    /// the recordings of one version kept together.
    public let members: [SongFamilyMemberSummary]

    /// Different versions: members sharing a MusicBrainz recording count once.
    public var versionCount: Int {
        Set(members.map(\.versionKey)).count
    }
}

public struct SongFamilyResult: Equatable, Sendable {
    /// History batch that undoes the change.
    public let batchId: String
    /// The family created or changed; nil when the change dissolved it.
    public let familyId: Int64?
}

/// The API every song-family client uses. Changes go through
/// `OperationEngine` as `.songFamily` mutations; undo is History's
/// `undoBatch(batchId)`. Grouping never writes tags, Serato files, or
/// recording identifiers.
public struct SongFamilyService: Sendable {
    private let engine: OperationEngine
    private let database: LibraryDatabase

    public init(engine: OperationEngine, database: LibraryDatabase) {
        self.engine = engine
        self.database = database
    }

    /// Groups at least two distinct recordings, first linking any unlinked
    /// file to the recording its fingerprint identifies. A recording whose
    /// family has fewer than two live versions is taken over, dissolving that
    /// family until undo. Throws `SongFamilyError.memberAlreadyInFamily`
    /// instead of reassigning a member of a live family (offer `merge`), and
    /// `fingerprintCollision` instead of sharing a recording another file or
    /// MusicBrainz already claims.
    public func create(_ members: [SongFamilyMember], representative: SongFamilyMember? = nil) async throws -> SongFamilyResult {
        try await apply(.create(members: members, representative: representative), linking: members, familyId: nil)
    }

    /// Adds recordings; ones already in this family are left as they are.
    public func attach(_ members: [SongFamilyMember], to familyId: Int64) async throws -> SongFamilyResult {
        try await apply(.attach(familyId: familyId, members: members), linking: members, familyId: familyId)
    }

    /// Removing members that leaves fewer than two recordings dissolves the family.
    public func detach(_ trackIds: [Int64], from familyId: Int64) async throws -> SongFamilyResult {
        try await apply(.detach(familyId: familyId, trackIds: trackIds), familyId: familyId)
    }

    /// Moves every member of `familyIds` into `familyId`, keeping its main version.
    public func merge(_ familyIds: [Int64], into familyId: Int64) async throws -> SongFamilyResult {
        try await apply(.merge(familyId: familyId, mergedFamilyIds: familyIds), familyId: familyId)
    }

    /// Moves at least two members into a new family; the result names the new family.
    public func split(_ trackIds: [Int64], from familyId: Int64) async throws -> SongFamilyResult {
        try await apply(.split(familyId: familyId, trackIds: trackIds), familyId: nil)
    }

    /// Saves a manual main version, or clears it with nil to use the automatic choice.
    public func setRepresentative(_ trackId: Int64?, of familyId: Int64) async throws -> SongFamilyResult {
        try await apply(.setRepresentative(familyId: familyId, trackId: trackId), familyId: familyId)
    }

    /// Nil for a family with fewer than two live versions: it is dissolved
    /// as far as the user can tell, though it keeps its members so returning
    /// files restore it.
    public func family(id: Int64) async throws -> SongFamily? {
        try await database.writer.read { database in try Self.fetchFamily(id: id, in: database) }
    }

    public func family(containingTrack trackId: Int64) async throws -> SongFamily? {
        try await database.writer.read { database in
            guard let familyID = try TrackRecord.fetchOne(database, key: trackId)?.workId else { return nil }
            return try Self.fetchFamily(id: familyID, in: database)
        }
    }

    /// Runs the file links and the membership change as one batch, so one
    /// undo reverses both and a refused change leaves no link behind.
    private func apply(_ operation: SongFamilyOperation, linking members: [SongFamilyMember] = [], familyId: Int64?) async throws -> SongFamilyResult {
        let batchID = UUID().uuidString
        let links = members.compactMap { member -> TrackMutation? in
            guard case let .file(fileID) = member else { return nil }
            return .songFamily(.linkRecording(fileId: fileID))
        }
        _ = try await engine.applyBatch(links + [.songFamily(operation)], batchId: batchID)
        let change = try await database.writer.read { database in
            try EventRecord.filter(Column("batch_id") == batchID && Column("event_type") == operation.eventType.rawValue).fetchOne(database)
                .map { event in try JSONDecoder().decode(SongFamilyChange.self, from: Data(event.payloadJson.utf8)) }
        }
        return SongFamilyResult(batchId: batchID, familyId: change.map(\.familyId) ?? familyId)
    }

    static func fetchFamily(id: Int64, in database: GRDB.Database) throws -> SongFamily? {
        guard let record = try SongFamilyRecord.fetchOne(database, key: id) else { return nil }
        let tracks = try TrackRecord.filter(Column("work_id") == id).filter(sql: SongFamilyMutation.liveTrackSQL).order(Column("id")).fetchAll(database)
        let files = try Row.fetchAll(database, sql: """
        SELECT id, track_id, artist, title, (\(FileProcessingEligibility.processableSQL)) AS available
        FROM files WHERE track_id IN (SELECT id FROM tracks WHERE work_id = ?) AND \(FileProcessingEligibility.activeSQL)
        ORDER BY available DESC, id
        """, arguments: [id])
        let filesByTrack = Dictionary(grouping: files) { row in row["track_id"] as Int64 }
        let members = tracks.compactMap { track -> SongFamilyMemberSummary? in
            guard let trackID = track.id else { return nil }
            let trackFiles = filesByTrack[trackID] ?? []
            return SongFamilyMemberSummary(
                trackId: trackID,
                title: trackFiles.lazy.compactMap { row in row["title"] as String? }.first ?? track.title,
                artist: trackFiles.lazy.compactMap { row in row["artist"] as String? }.first ?? track.artist,
                musicBrainzRecordingId: track.musicbrainzRecordingId,
                fileIds: trackFiles.map { row in row["id"] as Int64 }.sorted(),
                isAvailable: trackFiles.contains { row in row["available"] as Bool }
            )
        }
        guard Set(members.map(\.versionKey)).count >= 2, let representative = SongFamilyRepresentative.choose(from: members, saved: record.representativeTrackId) else { return nil }
        let first = members.filter { member in member.trackId == representative } + members.filter { member in member.trackId != representative }
        let versionOrder = first.map(\.versionKey).reduce(into: [String]()) { order, version in
            if !order.contains(version) {
                order.append(version)
            }
        }
        let ordered = versionOrder.flatMap { version in first.filter { member in member.versionKey == version } }
        return SongFamily(id: id, savedRepresentativeTrackId: record.representativeTrackId, representativeTrackId: representative, members: ordered)
    }
}

/// Chooses the member a family displays. Available members win over
/// unavailable ones, so a retired or missing saved choice is passed over for
/// now without being replaced. Among the candidates: the saved choice, then
/// by tier — a title marked Main, Original or Album Version; a bare title;
/// a Dirty or Explicit edit with no other qualifier; anything else — with a
/// MusicBrainz match first within a tier, and finally the lowest recording id.
enum SongFamilyRepresentative {
    static func choose(from members: [SongFamilyMemberSummary], saved: Int64?) -> Int64? {
        let available = members.filter(\.isAvailable)
        let candidates = available.isEmpty ? members : available
        if let saved, candidates.contains(where: { member in member.trackId == saved }) {
            return saved
        }
        return candidates.min { first, second in
            (rank(first), first.trackId) < (rank(second), second.trackId)
        }?.trackId
    }

    private static func rank(_ member: SongFamilyMemberSummary) -> Int {
        rank(title: member.title, isMusicBrainzMatched: member.isMusicBrainzMatched)
    }

    static func rank(title: String?, isMusicBrainzMatched: Bool) -> Int {
        let annotations = (title.map(TitleMatcher.annotationSegments) ?? []).map { segment in
            ListSearch.normalized(segment).trimmingCharacters(in: .whitespaces)
        }
        let tier = if annotations.contains(where: isMainVersionLabel) {
            0
        } else if annotations.isEmpty {
            1
        } else if annotations.allSatisfy(explicitEditLabels.contains) {
            2
        } else {
            3
        }
        return tier * 2 + (isMusicBrainzMatched ? 0 : 1)
    }

    private static let explicitEditLabels: Set<String> = ["dirty", "explicit", "dirty version", "explicit version"]

    private static func isMainVersionLabel(_ annotation: String) -> Bool {
        let firstWord = annotation.split(whereSeparator: { character in character.isWhitespace }).first
        return firstWord == "main" || firstWord == "original" || annotation == "album version"
    }
}
