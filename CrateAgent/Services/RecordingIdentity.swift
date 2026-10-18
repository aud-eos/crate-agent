import CryptoKit
import Foundation
import GRDB

/// Which `tracks` row a file's audio identifies (Invariant 4). The key is the
/// SHA-256 of the file's current 120 s fingerprint, unless the file was given
/// a recording of its own while it still has that fingerprint (#205). Its key
/// is then the SHA-256 of that hash followed by a discriminator: its
/// full-length fingerprint digest, or a per-file token when the user grouped
/// it as a different recording. AcoustID still looks up the 120 s fingerprint.
enum RecordingIdentity {
    static let table = "recording_discriminators"

    /// The SHA-256 of the file's stored 120 s fingerprint, while that
    /// fingerprint still describes the file's indexed size and mtime.
    static func fingerprintHash(of file: FileRecord) -> Data? {
        fingerprintHash(file.chromaprintFingerprint, status: file.fingerprintStatus, fingerprintedSize: file.fingerprintedSize,
                        fingerprintedMtime: file.fingerprintedMtime, fileSize: file.fileSize, mtime: file.mtime)
    }

    static func fingerprintHash(_ fingerprint: Data?, status: FingerprintStatus, fingerprintedSize: Int64?, fingerprintedMtime: Int64?,
                                fileSize: Int64, mtime: Int64) -> Data?
    {
        guard status == .done, let fingerprint, (fingerprintedSize ?? fileSize) == fileSize, (fingerprintedMtime ?? mtime) == mtime else {
            return nil
        }
        return Data(SHA256.hash(data: fingerprint))
    }

    /// The `tracks.fingerprint_hash` the file's current audio identifies, or
    /// nil while it has no current fingerprint.
    static func key(of file: FileRecord, in database: Database) throws -> Data? {
        guard let fileID = file.id, let hash = fingerprintHash(of: file) else { return nil }
        return try key(fingerprintHash: hash, fileID: fileID, in: database)
    }

    static func key(fingerprintHash: Data, fileID: Int64, in database: Database) throws -> Data {
        try key(fingerprintHash: fingerprintHash, stored: discriminator(ofFile: fileID, in: database))
    }

    /// `key(of:in:)` for many files in one query, reading only the columns
    /// the key needs. Files without a current fingerprint are left out.
    static func keys(ofFiles fileIDs: [Int64], in database: Database) throws -> [Int64: Data] {
        guard !fileIDs.isEmpty else { return [:] }
        let statement = try database.cachedStatement(sql: """
        SELECT files.id, files.chromaprint_fingerprint, files.fingerprint_status, files.fingerprinted_size, files.fingerprinted_mtime,
               files.file_size, files.mtime, \(discriminatorColumns(of: "separation"))
        FROM files LEFT JOIN \(table) AS separation ON separation.file_id = files.id
        WHERE files.id IN (SELECT value FROM json_each(?))
        """)
        let rows = try Row.fetchCursor(statement, arguments: ["[" + fileIDs.map(String.init).joined(separator: ",") + "]"])
        var keys: [Int64: Data] = [:]
        while let row = try rows.next() {
            let fileID: Int64 = row["id"]
            guard let status = FingerprintStatus(rawValue: row["fingerprint_status"]),
                  let hash = fingerprintHash(row["chromaprint_fingerprint"], status: status, fingerprintedSize: row["fingerprinted_size"],
                                             fingerprintedMtime: row["fingerprinted_mtime"], fileSize: row["file_size"], mtime: row["mtime"])
            else { continue }
            let stored = try (row["source"] as String?) == nil ? nil : discriminator(of: row, fileID: fileID)
            keys[fileID] = key(fingerprintHash: hash, stored: stored)
        }
        return keys
    }

    private static func key(fingerprintHash: Data, stored: RecordingDiscriminator?) -> Data {
        guard let stored, stored.fingerprintHash == fingerprintHash else { return fingerprintHash }
        return stored.key
    }

    static func discriminator(ofFile fileID: Int64, in database: Database) throws -> RecordingDiscriminator? {
        let statement = try database.cachedStatement(sql: "SELECT \(discriminatorColumns(of: table)) FROM \(table) WHERE file_id = ?")
        guard let row = try Row.fetchOne(statement, arguments: [fileID]) else { return nil }
        return try discriminator(of: row, fileID: fileID)
    }

    private static func discriminatorColumns(of alias: String) -> String {
        "\(alias).fingerprint_sha256, \(alias).discriminator, \(alias).source"
    }

    private static func discriminator(of row: Row, fileID: Int64) throws -> RecordingDiscriminator {
        guard let source = RecordingSeparationSource(rawValue: row["source"]) else {
            throw RecordingIdentityError.unreadableDiscriminator(fileId: fileID)
        }
        return RecordingDiscriminator(fingerprintHash: row["fingerprint_sha256"], discriminator: row["discriminator"], source: source)
    }

    static func store(_ discriminator: RecordingDiscriminator?, ofFile fileID: Int64, in database: Database) throws {
        guard let discriminator else {
            try database.execute(sql: "DELETE FROM \(table) WHERE file_id = ?", arguments: [fileID])
            return
        }
        try database.execute(sql: """
        INSERT OR REPLACE INTO \(table) (file_id, fingerprint_sha256, discriminator, source) VALUES (?, ?, ?, ?)
        """, arguments: [fileID, discriminator.fingerprintHash, discriminator.discriminator, discriminator.source.rawValue])
    }

    /// The grouping separations `SongFamilyService.createAsDifferentRecordings`
    /// runs before its links. Unlinked files go first, so a file already
    /// linked to the shared recording is the one that keeps it.
    static func groupingSeparations(of fileIDs: [Int64], in database: Database) throws -> [TrackMutation] {
        let files = try FileRecord.fetchAll(database, keys: fileIDs)
        let linked = Set(files.filter { file in file.trackId != nil }.compactMap(\.id))
        let ordered = fileIDs.filter { fileID in !linked.contains(fileID) } + fileIDs.filter(linked.contains)
        return ordered.map { fileID in .recordingIdentity(.separate(.grouping(fileId: fileID, groupedWith: fileIDs))) }
    }
}

public enum RecordingSeparationSource: String, Codable, Sendable {
    /// Its full-length fingerprint differs from files that share its 120 s one.
    case fullFingerprint = "full_fingerprint"
    /// The user grouped it as a different recording.
    case grouping
}

/// A file's own recording identity while its 120 s fingerprint hash is
/// `fingerprintHash`.
public struct RecordingDiscriminator: Codable, Sendable, Equatable {
    public let fingerprintHash: Data
    public let discriminator: Data
    public let source: RecordingSeparationSource

    var key: Data {
        Data(SHA256.hash(data: fingerprintHash + discriminator))
    }

    static func grouping(fileID: Int64, fingerprintHash: Data) -> Self {
        Self(fingerprintHash: fingerprintHash, discriminator: Data("grouping:\(fileID)".utf8), source: .grouping)
    }
}

public enum RecordingSeparationRequest: Codable, Sendable, Equatable {
    /// From a reviewed split preview (`RecordingSplitCandidate`): the file's
    /// full-length fingerprint digest, which must still differ from another
    /// file that shares its 120 s fingerprint.
    case fullFingerprint(fileId: Int64, membershipRevision: Int64, fingerprintHash: Data, fullFingerprintDigest: Data)
    /// Grouping as different recordings: separates the file only while it
    /// shares its recording with another library file or with a file grouped
    /// alongside it, and links it to its own recording.
    case grouping(fileId: Int64, groupedWith: [Int64])

    var fileId: Int64 {
        switch self {
        case let .fullFingerprint(fileId, _, _, _), let .grouping(fileId, _): fileId
        }
    }

    /// The discriminator this request gives the file while its 120 s
    /// fingerprint hash is `fingerprintHash`.
    func discriminator(fingerprintHash: Data) -> RecordingDiscriminator {
        switch self {
        case let .fullFingerprint(_, _, _, digest):
            RecordingDiscriminator(fingerprintHash: fingerprintHash, discriminator: digest, source: .fullFingerprint)
        case let .grouping(fileID, _):
            .grouping(fileID: fileID, fingerprintHash: fingerprintHash)
        }
    }
}

/// One file's separation as it was applied: the payload of both directions.
public struct RecordingSeparation: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let membershipRevision: Int64
    public let discriminator: RecordingDiscriminator
    /// A row for an earlier fingerprint, or an earlier separation the
    /// grouping one replaced.
    public let previousDiscriminator: RecordingDiscriminator?
    public let previousTrackId: Int64?
    public let trackId: Int64?
}

public enum RecordingIdentityOperation: Codable, Sendable, Equatable {
    case separate(RecordingSeparationRequest)
    /// Undo of a separation.
    case rejoin(RecordingSeparation)
    /// Redo of a separation.
    case reseparate(RecordingSeparation)

    var processingFileID: Int64? {
        if case let .separate(.fullFingerprint(fileId, _, _, _)) = self {
            return fileId
        }
        return nil
    }
}

public enum RecordingIdentityError: LocalizedError, Equatable {
    case alreadySeparated(file: String)
    case changedSincePreview(file: String)
    case changedSinceRecorded(file: String)
    case identityChangedSinceLookup(file: String)
    case unreadableDiscriminator(fileId: Int64)

    public var errorDescription: String? {
        switch self {
        case let .alreadySeparated(file):
            "“\(file)” already has a recording of its own."
        case let .changedSincePreview(file):
            "“\(file)” changed after it was checked, so it was not separated. Check shared openings again."
        case let .changedSinceRecorded(file):
            "“\(file)” changed recording after this was recorded. Undo the later change first."
        case let .identityChangedSinceLookup(file):
            "“\(file)” was given a different recording after it was looked up. Look it up again in Auto-Tag."
        case let .unreadableDiscriminator(fileID):
            "The recording identity stored for file \(fileID) is unreadable."
        }
    }
}

enum RecordingIdentityMutation {
    static func apply(_ operation: RecordingIdentityOperation, batchId: String, timestamp: Int64, in database: Database) throws -> Int64? {
        let separation: RecordingSeparation
        let eventType: EventType
        switch operation {
        case let .separate(request):
            guard let separated = try separate(request, in: database) else { return nil }
            separation = separated
            eventType = separationEventType(of: separated)
        case let .reseparate(recorded):
            separation = try reseparate(recorded, in: database)
            eventType = separationEventType(of: separation)
        case let .rejoin(recorded):
            guard let rejoined = try rejoin(recorded, in: database) else { return nil }
            separation = rejoined
            eventType = .recordingRejoined
        }
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: separation.fileId,
                                               trackId: separation.trackId ?? separation.previousTrackId, eventType: eventType,
                                               forwardPayload: separation, inversePayload: separation, in: database)
    }

    private static func separationEventType(of separation: RecordingSeparation) -> EventType {
        switch separation.discriminator.source {
        case .fullFingerprint: .recordingSeparated
        case .grouping: .recordingSeparatedForGrouping
        }
    }

    private static func separate(_ request: RecordingSeparationRequest, in database: Database) throws -> RecordingSeparation? {
        let file = try fileRecord(request.fileId, in: database)
        let previous = try RecordingIdentity.discriminator(ofFile: request.fileId, in: database)
        switch request {
        case let .fullFingerprint(fileID, revision, hash, digest):
            guard file.libraryMembership != .retired, file.membershipRevision == revision, RecordingIdentity.fingerprintHash(of: file) == hash else {
                throw FileProcessingEligibilityError.superseded(fileId: fileID)
            }
            guard previous?.fingerprintHash != hash else { throw RecordingIdentityError.alreadySeparated(file: file.displayName) }
            guard try RecordingSplitFinder.fullFingerprintDigest(of: file, in: database) == digest,
                  try RecordingSplitFinder.sharesFingerprintWithDifferentAudio(file, fingerprintHash: hash, fullFingerprintDigest: digest, in: database)
            else { throw RecordingIdentityError.changedSincePreview(file: file.displayName) }
            let sharedTrackID = try TrackRecord.filter(Column("fingerprint_hash") == hash).fetchOne(database)?.id
            let movesLink = file.trackId != nil && file.trackId == sharedTrackID
            return try commit(request.discriminator(fingerprintHash: hash), to: file, replacing: previous, linking: movesLink, in: database)
        case let .grouping(fileID, groupedWith):
            guard file.libraryMembership != .retired else { throw SongFamilyError.fileRetired(file: file.displayName) }
            guard let hash = RecordingIdentity.fingerprintHash(of: file) else { throw SongFamilyError.recordingUnidentified(file: file.displayName) }
            let key = try RecordingIdentity.key(fingerprintHash: hash, fileID: fileID, in: database)
            guard try sharesRecording(file, key: key, groupedWith: groupedWith, in: database) else { return nil }
            return try commit(request.discriminator(fingerprintHash: hash), to: file, replacing: previous, linking: true, in: database)
        }
    }

    /// Whether grouping would make `file` one recording with another file:
    /// another library file is linked to its recording, MusicBrainz already
    /// identifies the recording it would link to, or an unlinked file grouped
    /// with it has the same key.
    private static func sharesRecording(_ file: FileRecord, key: Data, groupedWith: [Int64], in database: Database) throws -> Bool {
        guard let fileID = file.id else { return false }
        let track = try file.trackId.flatMap { trackID in try TrackRecord.fetchOne(database, key: trackID) }
            ?? TrackRecord.filter(Column("fingerprint_hash") == key).fetchOne(database)
        if let track, let trackID = track.id {
            if try FileRecord.otherActiveFileReferencingTrack(trackID, excluding: fileID, in: database) != nil {
                return true
            }
            if file.trackId == nil, track.hasRecordingIdentity {
                return true
            }
        }
        for sibling in try FileRecord.fetchAll(database, keys: groupedWith.filter { siblingID in siblingID != fileID }) {
            guard sibling.libraryMembership != .retired, sibling.trackId == nil else { continue }
            if try RecordingIdentity.key(of: sibling, in: database) == key {
                return true
            }
        }
        return false
    }

    private static func commit(_ discriminator: RecordingDiscriminator, to file: FileRecord, replacing previous: RecordingDiscriminator?,
                               linking: Bool, expectedTrackID: Int64? = nil, in database: Database) throws -> RecordingSeparation
    {
        guard let fileID = file.id else { throw OperationEngineError.insertDidNotReturnRowId }
        try RecordingIdentity.store(discriminator, ofFile: fileID, in: database)
        var trackID = file.trackId
        if linking {
            let linked = try recording(keyed: discriminator.key, in: database)
            if let expectedTrackID, linked != expectedTrackID {
                throw RecordingIdentityError.changedSinceRecorded(file: file.displayName)
            }
            try database.execute(sql: "UPDATE files SET track_id = ? WHERE id = ?", arguments: [linked, fileID])
            trackID = linked
        }
        return RecordingSeparation(fileId: fileID, membershipRevision: file.membershipRevision, discriminator: discriminator,
                                   previousDiscriminator: previous, previousTrackId: file.trackId, trackId: trackID)
    }

    /// The recording row for `key`; a separation creates it bare, and undo
    /// leaves it in place, as grouping and match undo do.
    private static func recording(keyed key: Data, in database: Database) throws -> Int64 {
        if let existing = try TrackRecord.filter(Column("fingerprint_hash") == key).fetchOne(database)?.id {
            return existing
        }
        var track = TrackRecord(fingerprintHash: key)
        try track.insert(database)
        guard let trackID = track.id else { throw OperationEngineError.insertDidNotReturnRowId }
        return trackID
    }

    /// Redo: the file must be where undo left it, and a full-length split
    /// must still be supported by its fresh digest.
    private static func reseparate(_ recorded: RecordingSeparation, in database: Database) throws -> RecordingSeparation {
        let file = try fileRecord(recorded.fileId, in: database)
        let hash = recorded.discriminator.fingerprintHash
        guard file.libraryMembership != .retired, file.membershipRevision == recorded.membershipRevision,
              RecordingIdentity.fingerprintHash(of: file) == hash,
              try RecordingIdentity.discriminator(ofFile: recorded.fileId, in: database) == recorded.previousDiscriminator,
              file.trackId == recorded.previousTrackId
        else { throw RecordingIdentityError.changedSinceRecorded(file: file.displayName) }
        if recorded.discriminator.source == .fullFingerprint {
            guard try RecordingSplitFinder.fullFingerprintDigest(of: file, in: database) == recorded.discriminator.discriminator else {
                throw RecordingIdentityError.changedSinceRecorded(file: file.displayName)
            }
        }
        let linking = recorded.trackId != recorded.previousTrackId
        return try commit(recorded.discriminator, to: file, replacing: recorded.previousDiscriminator, linking: linking,
                          expectedTrackID: linking ? recorded.trackId : nil, in: database)
    }

    /// Undo restores the shared recording only while the separation still
    /// stands and no later live match of the file relies on it. A grouping
    /// separation follows the grouping-link rule instead of refusing: it is
    /// kept once a match claims it or the file retires, so undoing a group
    /// never waits on either.
    private static func rejoin(_ recorded: RecordingSeparation, in database: Database) throws -> RecordingSeparation? {
        let file = try fileRecord(recorded.fileId, in: database)
        let keepsSeparation = recorded.discriminator.source == .grouping
        if keepsSeparation, file.libraryMembership == .retired {
            return nil
        }
        guard try RecordingIdentity.discriminator(ofFile: recorded.fileId, in: database) == recorded.discriminator,
              file.trackId == recorded.trackId, try !hasLiveMatchSinceSeparation(of: recorded.fileId, in: database)
        else {
            if keepsSeparation {
                return nil
            }
            throw RecordingIdentityError.changedSinceRecorded(file: file.displayName)
        }
        try RecordingIdentity.store(recorded.previousDiscriminator, ofFile: recorded.fileId, in: database)
        if recorded.trackId != recorded.previousTrackId {
            try database.execute(sql: "UPDATE files SET track_id = ? WHERE id = ?", arguments: [recorded.previousTrackId, recorded.fileId])
        }
        return recorded
    }

    private static func hasLiveMatchSinceSeparation(of fileID: Int64, in database: Database) throws -> Bool {
        let separationTypes = [EventType.recordingSeparated, .recordingSeparatedForGrouping].map(\.rawValue)
        guard let separatedAt = try Int64.fetchOne(database, sql: """
        SELECT MAX(event_id) FROM events WHERE file_id = ? AND event_type IN (?, ?)
        """, arguments: [fileID] + StatementArguments(separationTypes)) else { return false }
        let history = try EventRecord.filter(Column("file_id") == fileID)
            .filter([EventType.musicBrainzMatchApplied.rawValue, EventType.musicBrainzMatchReverted.rawValue].contains(Column("event_type")))
            .order(Column("event_id"))
            .fetchAll(database)
        let live = MatchHistoryStacks.liveApplies(in: history) { event in event.fileId }
        return live[fileID]?.contains { eventID in eventID > separatedAt } ?? false
    }

    private static func fileRecord(_ fileID: Int64, in database: Database) throws -> FileRecord {
        guard let file = try FileRecord.fetchOne(database, key: fileID) else { throw OperationEngineError.fileNotFound(fileId: fileID) }
        return file
    }
}
