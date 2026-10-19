import Foundation
import GRDB

/// A file the user marked as the keeper of its recording.
public struct KeeperMark: Codable, Sendable, Hashable {
    public let fileId: Int64
    /// The file's membership revision when it was marked. Replaced content
    /// or retirement invalidates projections past it, which drops the mark.
    public let markedRevision: Int64
    public let markedAt: Int64

    public init(fileId: Int64, markedRevision: Int64, markedAt: Int64) {
        self.fileId = fileId
        self.markedRevision = markedRevision
        self.markedAt = markedAt
    }
}

/// The file a keeper change was asked for, as the user saw it.
public struct KeeperTarget: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let expectedRevision: Int64

    public init(fileId: Int64, expectedRevision: Int64) {
        self.fileId = fileId
        self.expectedRevision = expectedRevision
    }
}

public enum KeeperOperation: Sendable {
    /// Marks the target as its recording's keeper.
    case mark(KeeperTarget)
    /// Clears every mark on the target's recording.
    case clear(KeeperTarget)
    /// Puts cleared marks back; produced only by `decodeInverseMutation`.
    case restore([KeeperMark])
    /// Deletes marks; produced only by `decodeInverseMutation`.
    case remove([KeeperMark])

    var fileIDs: [Int64] {
        switch self {
        case let .mark(target), let .clear(target): [target.fileId]
        case let .restore(marks), let .remove(marks): marks.map(\.fileId)
        }
    }
}

public enum KeeperError: LocalizedError, Equatable {
    case alreadyKept
    case notKept
    case superseded

    public var errorDescription: String? {
        switch self {
        case .alreadyKept: "This recording already has a keeper."
        case .notKept: "This recording no longer has a keeper."
        case .superseded: "This file changed since it was shown. Refresh the library and try again."
        }
    }
}

/// Keeper protection is keyed on the recording's version key, so every
/// encoding sharing a MusicBrainz recording shares its keeper (Invariant 4).
enum KeeperMarks {
    static let table = "keeper_marks"

    /// Over `files LEFT JOIN tracks ON tracks.id = files.track_id`: MBID, else 'track:' || id, else 'file:' || files.id.
    static let recordingKeySQL = "COALESCE(\(SongFamilyMutation.versionKeySQL), 'file:' || files.id)"

    /// A valid mark: marked_revision >= COALESCE(files.last_projection_invalidation_revision, 0).
    static let validMarkSQL = "\(table).marked_revision >= COALESCE(files.last_projection_invalidation_revision, 0)"

    private static let recordingJoinSQL = "LEFT JOIN tracks ON tracks.id = files.track_id"
    private static let validMarksSQL = "FROM \(table) JOIN files ON files.id = \(table).file_id \(recordingJoinSQL) WHERE \(validMarkSQL)"
    private static let keptRecordingKeysSQL = "SELECT \(recordingKeySQL) \(validMarksSQL)"

    /// CTE body selecting every protected file id: a valid own mark, or a recording key shared with a validly marked file.
    static let protectedFilesSQL = "SELECT files.id AS file_id FROM files \(recordingJoinSQL) WHERE \(recordingKeySQL) IN (\(keptRecordingKeysSQL))"

    /// CTE body selecting files with a valid mark of their own (suppresses the duplicate item).
    static let ownMarkFilesSQL = "SELECT \(table).file_id AS file_id FROM \(table) JOIN files ON files.id = \(table).file_id WHERE \(validMarkSQL)"

    static func isProtected(fileID: Int64, in database: GRDB.Database) throws -> Bool {
        try Bool.fetchOne(database, sql: """
        SELECT EXISTS (SELECT 1 FROM files \(recordingJoinSQL) WHERE files.id = ? AND \(recordingKeySQL) IN (\(keptRecordingKeysSQL)))
        """, arguments: [fileID]) ?? false
    }

    /// Every file sharing a recording key with one of `fileIDs`, those included.
    static func filesSharingRecording(with fileIDs: [Int64], in database: GRDB.Database) throws -> [FileRecord] {
        guard !fileIDs.isEmpty else { return [] }
        return try FileRecord.fetchAll(database, sql: """
        SELECT files.* FROM files \(recordingJoinSQL) WHERE \(recordingKeySQL) IN (
            SELECT \(recordingKeySQL) FROM files \(recordingJoinSQL) WHERE files.id IN (\(databaseQuestionMarks(count: fileIDs.count))))
        ORDER BY files.id
        """, arguments: StatementArguments(fileIDs))
    }

    fileprivate static func validMarks(sharingRecordingOf fileID: Int64, in database: GRDB.Database) throws -> [KeeperMark] {
        try Row.fetchAll(database, sql: """
        SELECT \(table).file_id, \(table).marked_revision, \(table).marked_at \(validMarksSQL)
        AND \(recordingKeySQL) = (SELECT \(recordingKeySQL) FROM files \(recordingJoinSQL) WHERE files.id = ?)
        ORDER BY \(table).file_id
        """, arguments: [fileID]).map(mark(from:))
    }

    fileprivate static func storedMark(of fileID: Int64, in database: GRDB.Database) throws -> KeeperMark? {
        try Row.fetchOne(database, sql: "SELECT file_id, marked_revision, marked_at FROM \(table) WHERE file_id = ?", arguments: [fileID])
            .map(mark(from:))
    }

    private static func mark(from row: Row) -> KeeperMark {
        KeeperMark(fileId: row["file_id"], markedRevision: row["marked_revision"], markedAt: row["marked_at"])
    }
}

enum KeeperMutation {
    static func apply(_ operation: KeeperOperation, batchId: String, timestamp: Int64, in database: Database) throws -> Int64 {
        switch operation {
        case let .mark(target):
            let file = try requireCurrent(target, in: database)
            guard try !KeeperMarks.isProtected(fileID: target.fileId, in: database) else { throw KeeperError.alreadyKept }
            // Any row left for the file is a mark its replaced content invalidated.
            let mark = KeeperMark(fileId: target.fileId, markedRevision: file.membershipRevision, markedAt: timestamp)
            return try journal([mark], as: .keeperMarked, batchId: batchId, timestamp: timestamp, in: database) { mark in
                try insert(mark, replacingStale: true, in: database)
            }
        case let .clear(target):
            _ = try requireCurrent(target, in: database)
            let marks = try KeeperMarks.validMarks(sharingRecordingOf: target.fileId, in: database)
            guard !marks.isEmpty else { throw KeeperError.notKept }
            return try journal(marks, as: .keeperCleared, batchId: batchId, timestamp: timestamp, in: database) { mark in
                try delete(mark, in: database)
            }
        case let .restore(marks):
            return try journal(marks, as: .keeperMarked, batchId: batchId, timestamp: timestamp, in: database) { mark in
                guard try KeeperMarks.storedMark(of: mark.fileId, in: database) == nil else { throw KeeperError.superseded }
                try insert(mark, replacingStale: false, in: database)
            }
        case let .remove(marks):
            return try journal(marks, as: .keeperCleared, batchId: batchId, timestamp: timestamp, in: database) { mark in
                guard try KeeperMarks.storedMark(of: mark.fileId, in: database) == mark else { throw KeeperError.superseded }
                try delete(mark, in: database)
            }
        }
    }

    private static func requireCurrent(_ target: KeeperTarget, in database: Database) throws -> FileRecord {
        guard let file = try FileRecord.fetchOne(database, key: target.fileId), file.libraryMembership != .retired, file.retiredAt == nil,
              file.membershipRevision == target.expectedRevision
        else { throw KeeperError.superseded }
        return file
    }

    /// Applies `change` to each mark and journals one event per mark, so the
    /// file's own History lists it. Returns the last event's id.
    private static func journal(_ marks: [KeeperMark], as eventType: EventType, batchId: String, timestamp: Int64, in database: Database,
                                change: (KeeperMark) throws -> Void) throws -> Int64
    {
        var lastEventID: Int64?
        for mark in marks {
            guard let file = try FileRecord.fetchOne(database, key: mark.fileId) else { throw KeeperError.superseded }
            try change(mark)
            lastEventID = try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: mark.fileId, trackId: file.trackId,
                                                          eventType: eventType, forwardPayload: mark, inversePayload: mark, in: database)
        }
        guard let lastEventID else { throw KeeperError.superseded }
        return lastEventID
    }

    private static func insert(_ mark: KeeperMark, replacingStale: Bool, in database: Database) throws {
        try database.execute(sql: """
        INSERT \(replacingStale ? "OR REPLACE " : "")INTO \(KeeperMarks.table) (file_id, marked_revision, marked_at) VALUES (?, ?, ?)
        """, arguments: [mark.fileId, mark.markedRevision, mark.markedAt])
    }

    private static func delete(_ mark: KeeperMark, in database: Database) throws {
        try database.execute(sql: "DELETE FROM \(KeeperMarks.table) WHERE file_id = ?", arguments: [mark.fileId])
    }
}

public extension OperationEngine {
    /// Marks or clears the keeper of `token`'s file and its recording; returns the batch id for History.
    func setKeeper(_ isKeeper: Bool, for token: FileMembershipToken) async throws -> String {
        let target = KeeperTarget(fileId: token.fileId, expectedRevision: token.revision)
        let batchId = "keeper-\(UUID().uuidString)"
        try await apply(.keeper(isKeeper ? .mark(target) : .clear(target)), batchId: batchId)
        return batchId
    }
}
