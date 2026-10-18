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

/// A file's recording and the family that recording belongs to, if Library
/// shows that family: one with fewer than two live versions reads as none, so
/// Merge never pulls a hidden family in and Add takes its recording over.
public struct SongFamilyFileMembership: Equatable, Sendable {
    public let fileId: Int64
    public let trackId: Int64?
    public let familyId: Int64?
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
    public func create(_ members: [SongFamilyMember], representative: SongFamilyMember? = nil,
                       authority: [FileMembershipToken] = []) async throws -> SongFamilyResult
    {
        try await apply(.create(members: members, representative: representative), linking: members, familyId: nil, authority: authority)
    }

    /// Adds recordings; ones already in this family are left as they are.
    public func attach(_ members: [SongFamilyMember], to familyId: Int64, authority: [FileMembershipToken] = []) async throws -> SongFamilyResult {
        try await apply(.attach(familyId: familyId, members: members), linking: members, familyId: familyId, authority: authority)
    }

    /// `create` for files the user says are different recordings even though
    /// they share one: each file whose recording another library file or a
    /// file grouped with it shares is first given a grouping-owned recording
    /// of its own, in the same batch (#205, docs/recording-identity.md).
    public func createAsDifferentRecordings(_ fileIds: [Int64], authority: [FileMembershipToken] = []) async throws -> SongFamilyResult {
        let members = fileIds.map(SongFamilyMember.file)
        return try await apply(.create(members: members, representative: nil), linking: members,
                               separating: groupingSeparations(of: fileIds), familyId: nil, authority: authority)
    }

    /// `attach` with the separations of `createAsDifferentRecordings`.
    public func attachAsDifferentRecordings(_ fileIds: [Int64], to familyId: Int64, authority: [FileMembershipToken] = []) async throws -> SongFamilyResult {
        let members = fileIds.map(SongFamilyMember.file)
        return try await apply(.attach(familyId: familyId, members: members), linking: members,
                               separating: groupingSeparations(of: fileIds), familyId: familyId, authority: authority)
    }

    private func groupingSeparations(of fileIds: [Int64]) async throws -> [TrackMutation] {
        try await database.writer.read { database in try RecordingIdentity.groupingSeparations(of: fileIds, in: database) }
    }

    /// Removing members that leaves fewer than two recordings dissolves the family.
    public func detach(_ trackIds: [Int64], from familyId: Int64, authority: [FileMembershipToken] = []) async throws -> SongFamilyResult {
        try await apply(.detach(familyId: familyId, trackIds: trackIds), familyId: familyId, authority: authority)
    }

    /// Moves every member of `familyIds` into `familyId`, keeping its main version.
    public func merge(_ familyIds: [Int64], into familyId: Int64, authority: [FileMembershipToken] = []) async throws -> SongFamilyResult {
        try await apply(.merge(familyId: familyId, mergedFamilyIds: familyIds), familyId: familyId, authority: authority)
    }

    /// Moves at least two members into a new family; the result names the new family.
    public func split(_ trackIds: [Int64], from familyId: Int64, authority: [FileMembershipToken] = []) async throws -> SongFamilyResult {
        try await apply(.split(familyId: familyId, trackIds: trackIds), familyId: nil, authority: authority)
    }

    /// Saves a manual main version, or clears it with nil to use the automatic choice.
    public func setRepresentative(_ trackId: Int64?, of familyId: Int64, authority: [FileMembershipToken] = []) async throws -> SongFamilyResult {
        try await apply(.setRepresentative(familyId: familyId, trackId: trackId), familyId: familyId, authority: authority)
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

    public func memberships(ofFiles fileIds: [Int64]) async throws -> [SongFamilyFileMembership] {
        let ids = "[" + fileIds.map(String.init).joined(separator: ",") + "]"
        return try await database.writer.read { database in
            try Row.fetchAll(database, sql: """
            WITH live_families AS (\(SongFamilyMutation.liveFamiliesSQL))
            SELECT files.id, files.track_id, live_families.family_id FROM files LEFT JOIN tracks ON tracks.id = files.track_id
            LEFT JOIN live_families ON live_families.family_id = tracks.work_id
            WHERE files.id IN (SELECT value FROM json_each(?)) ORDER BY files.id
            """, arguments: [ids]).map { row in
                SongFamilyFileMembership(fileId: row["id"], trackId: row["track_id"], familyId: row["family_id"])
            }
        }
    }

    /// Runs the file links and the membership change as one batch, so one
    /// undo reverses both and a refused change leaves no link behind. Every
    /// `authority` token must still be current inside that transaction; a
    /// stale one is refused by the file's name.
    private func apply(_ operation: SongFamilyOperation, linking members: [SongFamilyMember] = [], separating separations: [TrackMutation] = [],
                       familyId: Int64?, authority: [FileMembershipToken]) async throws -> SongFamilyResult
    {
        let batchID = UUID().uuidString
        let links = members.compactMap { member -> TrackMutation? in
            guard case let .file(fileID) = member else { return nil }
            return .songFamily(.linkRecording(fileId: fileID))
        }
        do {
            _ = try await engine.applyBatch(separations + links + [.songFamily(operation)], batchId: batchID, authorizingMembershipTokens: authority)
        } catch let FileProcessingEligibilityError.superseded(fileID) where authority.contains(where: { token in token.fileId == fileID }) {
            let name = try await database.writer.read { database in try FileRecord.fetchOne(database, key: fileID)?.displayName }
            guard let name else { throw FileProcessingEligibilityError.superseded(fileId: fileID) }
            throw SongFamilyError.changedSinceShown(file: name)
        }
        let change = try await database.writer.read { database in
            try EventRecord.filter(Column("batch_id") == batchID && Column("event_type") == operation.eventType.rawValue).fetchOne(database)
                .map { event in try JSONDecoder().decode(SongFamilyChange.self, from: Data(event.payloadJson.utf8)) }
        }
        return SongFamilyResult(batchId: batchID, familyId: change.map(\.familyId) ?? familyId)
    }

    static func fetchFamily(id: Int64, in database: GRDB.Database) throws -> SongFamily? {
        guard let record = try SongFamilyRecord.fetchOne(database, key: id) else { return nil }
        let order = SongFamilyRepresentative.orderSQL(available: "available", saved: "saved", title: "COALESCE(files.title, tracks.title)",
                                                      musicBrainzID: "tracks.musicbrainz_recording_id", recording: "tracks.id", file: "files.id")
        let rows = try Row.fetchAll(database, sql: """
        SELECT tracks.id AS track_id, tracks.musicbrainz_recording_id AS recording_mbid, files.id AS file_id,
               COALESCE(files.title, tracks.title) AS title, COALESCE(files.artist, tracks.artist) AS artist,
               COALESCE(\(FileProcessingEligibility.processableSQL), 0) AS available, tracks.id IS ? AS saved
        FROM tracks LEFT JOIN files ON files.track_id = tracks.id AND \(FileProcessingEligibility.activeSQL)
        WHERE tracks.work_id = ? AND \(SongFamilyMutation.liveTrackSQL)
        ORDER BY \(order)
        """, arguments: [record.representativeTrackId, id])
        var members: [SongFamilyMemberSummary] = []
        for (trackID, trackRows) in Dictionary(grouping: rows, by: { row in row["track_id"] as Int64 }) {
            guard let best = trackRows.first else { continue }
            members.append(SongFamilyMemberSummary(
                trackId: trackID, title: best["title"], artist: best["artist"],
                musicBrainzRecordingId: best["recording_mbid"],
                fileIds: trackRows.compactMap { row in row["file_id"] as Int64? }.sorted(),
                isAvailable: trackRows.contains { row in row["available"] as Bool }
            ))
        }
        guard Set(members.map(\.versionKey)).count >= 2, let representative = rows.first.map({ row in row["track_id"] as Int64 }) else { return nil }
        members.sort { first, second in (first.trackId == representative ? 0 : 1, first.trackId) < (second.trackId == representative ? 0 : 1, second.trackId) }
        let versionOrder = members.map(\.versionKey).reduce(into: [String]()) { order, version in
            if !order.contains(version) {
                order.append(version)
            }
        }
        let ordered = versionOrder.flatMap { version in members.filter { member in member.versionKey == version } }
        return SongFamily(id: id, savedRepresentativeTrackId: record.representativeTrackId, representativeTrackId: representative, members: ordered)
    }
}

/// Chooses the file, and so the recording, a family displays, as SQL ordering
/// terms so Library sorting and the service share one rule. Available files
/// win, so a retired or missing saved choice is passed over without being
/// replaced. Then the saved choice, then by tier — a title marked Main,
/// Original or Album Version; a bare title; a Dirty or Explicit edit with no
/// other qualifier; anything else — with a MusicBrainz match first within a
/// tier, then the lowest recording id and the lowest file id.
enum SongFamilyRepresentative {
    static let rankFunction = "song_family_rank"

    static func register(in database: GRDB.Database) {
        database.add(function: DatabaseFunction(rankFunction, argumentCount: 2, pure: true) { values in
            rank(title: String.fromDatabaseValue(values[0]), isMusicBrainzMatched: !values[1].isNull)
        })
    }

    static func orderSQL(available: String, saved: String, title: String, musicBrainzID: String, recording: String, file: String) -> String {
        "\(available) DESC, \(saved) DESC, \(rankFunction)(\(title), \(musicBrainzID)), \(recording), \(file)"
    }

    static func rank(title: String?, isMusicBrainzMatched: Bool) -> Int {
        let annotations = (title.map(TitleMatcher.annotationSegments) ?? []).map { segment in
            ListSearch.normalized(segment).trimmingCharacters(in: .whitespaces)
        }.filter { annotation in !isNonVersionAnnotation(annotation) }
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
    private static let mainVersionTerms: Set<String> = ["main", "original mix", "album version"]
    private static let creditWords: Set<String> = ["feat", "feat.", "ft", "ft.", "featuring", "with"]

    /// A featured-artist credit, a remaster note, or a bare year names the
    /// same version as the bare title.
    private static func isNonVersionAnnotation(_ annotation: String) -> Bool {
        let firstWord = annotation.split(whereSeparator: { character in character.isWhitespace }).first.map(String.init)
        if let firstWord, creditWords.contains(firstWord) {
            return true
        }
        return annotation.range(of: #"^((19|20)\d{2}\s+)?(digital(ly)?\s+)?(remaster(ed)?(\s+(version|edition))?(\s+(19|20)\d{2})?|(19|20)\d{2})$"#,
                                options: .regularExpression) != nil
    }

    private static func isMainVersionLabel(_ annotation: String) -> Bool {
        let firstWord = annotation.split(whereSeparator: { character in character.isWhitespace }).first
        let isMainLabel = firstWord == "main" || firstWord == "original" || annotation == "album version"
        return isMainLabel && !TitleMatcher.containsVersionTerm(annotation, excluding: mainVersionTerms)
    }
}
