import Foundation
import GRDB

/// One recording in a song family, with the display values of its files.
public struct SongFamilyMemberSummary: Equatable, Sendable {
    public let trackId: Int64
    public let title: String?
    public let artist: String?
    public let isMusicBrainzMatched: Bool
    /// Every file encoding this recording; several encodings are one version.
    public let fileIds: [Int64]
    /// Whether any of its files is active in the library and present on disk.
    public let isAvailable: Bool
}

public struct SongFamily: Equatable, Sendable, Identifiable {
    public let id: Int64
    /// The user's manual main-version choice, kept even while it is unavailable.
    public let savedRepresentativeTrackId: Int64?
    /// The member shown for the family right now (`SongFamilyRepresentative`).
    public let representativeTrackId: Int64
    /// The representative first, then the alternates by recording id.
    public let members: [SongFamilyMemberSummary]

    public var versionCount: Int {
        members.count
    }
}

/// A file's recording and the family that recording belongs to, if any.
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

    /// Groups at least two distinct recordings. Throws
    /// `SongFamilyError.memberAlreadyInFamily` instead of reassigning a member;
    /// offer `merge` for that conflict.
    public func create(_ members: [SongFamilyMember], representative: SongFamilyMember? = nil) async throws -> SongFamilyResult {
        try await apply(.create(members: members, representative: representative), familyId: nil)
    }

    public func attach(_ members: [SongFamilyMember], to familyId: Int64) async throws -> SongFamilyResult {
        try await apply(.attach(familyId: familyId, members: members), familyId: familyId)
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
            SELECT files.id, files.track_id, tracks.work_id FROM files LEFT JOIN tracks ON tracks.id = files.track_id
            WHERE files.id IN (SELECT value FROM json_each(?)) ORDER BY files.id
            """, arguments: [ids]).map { row in
                SongFamilyFileMembership(fileId: row["id"], trackId: row["track_id"], familyId: row["work_id"])
            }
        }
    }

    private func apply(_ operation: SongFamilyOperation, familyId: Int64?) async throws -> SongFamilyResult {
        let batchID = UUID().uuidString
        guard let eventID = try await engine.apply(.songFamily(operation), batchId: batchID) else {
            return SongFamilyResult(batchId: batchID, familyId: familyId)
        }
        let change = try await database.writer.read { database in
            guard let event = try EventRecord.fetchOne(database, key: eventID) else {
                throw OperationEngineError.batchNotFound(batchId: batchID)
            }
            return try JSONDecoder().decode(SongFamilyChange.self, from: Data(event.payloadJson.utf8))
        }
        return SongFamilyResult(batchId: batchID, familyId: change.familyId)
    }

    static func fetchFamily(id: Int64, in database: GRDB.Database) throws -> SongFamily? {
        guard let record = try SongFamilyRecord.fetchOne(database, key: id) else { return nil }
        let order = SongFamilyRepresentative.orderSQL(available: "available", saved: "saved", title: "COALESCE(files.title, tracks.title)",
                                                      musicBrainzID: "tracks.musicbrainz_recording_id", recording: "tracks.id", file: "files.id")
        let rows = try Row.fetchAll(database, sql: """
        SELECT tracks.id AS track_id, tracks.musicbrainz_recording_id AS recording_mbid, files.id AS file_id,
               COALESCE(files.title, tracks.title) AS title, COALESCE(files.artist, tracks.artist) AS artist,
               COALESCE(\(FileProcessingEligibility.processableSQL), 0) AS available, tracks.id IS ? AS saved
        FROM tracks LEFT JOIN files ON files.track_id = tracks.id
        WHERE tracks.work_id = ?
        ORDER BY \(order)
        """, arguments: [record.representativeTrackId, id])
        var members: [SongFamilyMemberSummary] = []
        for (trackID, trackRows) in Dictionary(grouping: rows, by: { row in row["track_id"] as Int64 }) {
            guard let best = trackRows.first else { continue }
            members.append(SongFamilyMemberSummary(
                trackId: trackID, title: best["title"], artist: best["artist"],
                isMusicBrainzMatched: best["recording_mbid"] as String? != nil,
                fileIds: trackRows.compactMap { row in row["file_id"] as Int64? }.sorted(),
                isAvailable: trackRows.contains { row in row["available"] as Bool }
            ))
        }
        guard let representative = rows.first.map({ row in row["track_id"] as Int64 }) else { return nil }
        members.sort { first, second in (first.trackId == representative ? 0 : 1, first.trackId) < (second.trackId == representative ? 0 : 1, second.trackId) }
        return SongFamily(id: id, savedRepresentativeTrackId: record.representativeTrackId, representativeTrackId: representative, members: members)
    }
}

/// Chooses the file, and so the recording, a family displays, as SQL ordering
/// terms so Library sorting and the service share one rule. Available files
/// win, so a retired or missing saved choice is passed over without being
/// replaced. Then: the saved choice, a title marked Main/Original, a
/// MusicBrainz-matched unannotated recording, any MusicBrainz match, any
/// unannotated title, the lowest recording id, and the lowest file id.
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
        let annotations = title.map(TitleMatcher.annotationSegments) ?? []
        if annotations.contains(where: isMainVersionLabel) {
            return 0
        }
        switch (isMusicBrainzMatched, annotations.isEmpty) {
        case (true, true): return 1
        case (true, false): return 2
        case (false, true): return 3
        case (false, false): return 4
        }
    }

    private static func isMainVersionLabel(_ annotation: String) -> Bool {
        let firstWord = ListSearch.normalized(annotation).split(whereSeparator: { character in character.isWhitespace }).first
        return firstWord == "main" || firstWord == "original"
    }
}
