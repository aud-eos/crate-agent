import Foundation
import GRDB

/// The "apply track mutation" primitive — every state-changing
/// operation in crate-agent routes through this actor. Holding the
/// chokepoint here guarantees:
///   1. mutations apply atomically (SQLite transaction)
///   2. every mutation produces a journal event with both forward
///      payload and inverse payload (enables undo + per-file history)
///   3. mutations that touch Serato library files can be gated on
///      SeratoWatchdog (added when Serato file rewrites land)
///
/// SP-1 v1 implements indexNewFile and renameFile as database-only
/// operations. The Serato library rewrite path (FFI calls to
/// rewriteCratePath / rewriteDatabasePath, deferred while
/// `seratoWatchdog.isSeratoRunning`) lands in the next iteration.
/// The watchdog is wired in now so callers can already pass it and
/// the integration point is reserved.
public actor OperationEngine {

    private let database: LibraryDatabase
    private let seratoWatchdog: SeratoWatchdog

    public init(database: LibraryDatabase, seratoWatchdog: SeratoWatchdog) {
        self.database = database
        self.seratoWatchdog = seratoWatchdog
    }

    /// Apply a mutation with an auto-generated batch identifier. Use
    /// `apply(_:batchId:)` when grouping multiple mutations into a
    /// single user-initiated operation (so undo can replay them all).
    @discardableResult
    public func apply(_ mutation: TrackMutation) async throws -> Int64 {
        try await apply(mutation, batchId: UUID().uuidString)
    }

    /// Apply a mutation under a caller-supplied batch identifier. All
    /// mutations sharing a batch_id are treated as a single
    /// transaction for undo purposes.
    @discardableResult
    public func apply(_ mutation: TrackMutation, batchId: String) async throws -> Int64 {
        try await database.writer.write { db in
            try Self.executeAndLog(mutation: mutation, batchId: batchId, in: db)
        }
    }

    /// Synchronous core of the engine — runs inside the GRDB write
    /// transaction. Static so the actor's self capture stays out of
    /// the closure body (which would force the closure to await
    /// reentrantly).
    private static func executeAndLog(
        mutation: TrackMutation,
        batchId: String,
        in db: GRDB.Database
    ) throws -> Int64 {
        let timestampMillis = Int64(Date().timeIntervalSince1970 * 1000)
        switch mutation {
        case .indexNewFile(let payload):
            return try applyIndexNewFile(payload, batchId: batchId, timestamp: timestampMillis, in: db)
        case .renameFile(let payload):
            return try applyRenameFile(payload, batchId: batchId, timestamp: timestampMillis, in: db)
        }
    }

    private static func applyIndexNewFile(
        _ payload: IndexNewFilePayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> Int64 {
        var fileRecord = FileRecord(
            path: payload.path,
            volumeUuid: payload.volumeUuid,
            inode: payload.inode,
            fileSize: payload.fileSize,
            mtime: payload.mtime,
            lightweightHash: payload.lightweightHash,
            fingerprintStatus: .pending
        )
        try fileRecord.insert(db)
        guard let fileId = fileRecord.id else {
            throw OperationEngineError.insertDidNotReturnRowId
        }

        let forwardPayload = IndexNewFilePayload(
            path: payload.path,
            volumeUuid: payload.volumeUuid,
            inode: payload.inode,
            fileSize: payload.fileSize,
            mtime: payload.mtime,
            lightweightHash: payload.lightweightHash
        )
        let inversePayload = RemoveFilePayload(fileId: fileId)

        return try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: fileId,
            eventType: .trackImported,
            forwardPayload: forwardPayload,
            inversePayload: inversePayload,
            in: db
        )
    }

    private static func applyRenameFile(
        _ payload: RenameFilePayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> Int64 {
        guard var fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        let originalPath = fileRecord.path
        fileRecord.path = payload.newPath
        try fileRecord.update(db)

        let forwardPayload = RenameFilePayload(
            fileId: payload.fileId,
            newPath: payload.newPath,
            previousPath: originalPath
        )
        let inversePayload = RenameFilePayload(
            fileId: payload.fileId,
            newPath: originalPath,
            previousPath: payload.newPath
        )

        return try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileRenamed,
            forwardPayload: forwardPayload,
            inversePayload: inversePayload,
            in: db
        )
    }

    private static func insertEvent<ForwardPayload: Encodable, InversePayload: Encodable>(
        batchId: String,
        timestamp: Int64,
        fileId: Int64?,
        eventType: EventType,
        forwardPayload: ForwardPayload,
        inversePayload: InversePayload,
        in db: GRDB.Database
    ) throws -> Int64 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let forwardJsonData = try encoder.encode(forwardPayload)
        let inverseJsonData = try encoder.encode(inversePayload)

        guard let forwardJsonString = String(data: forwardJsonData, encoding: .utf8),
              let inverseJsonString = String(data: inverseJsonData, encoding: .utf8) else {
            throw OperationEngineError.payloadEncodingFailed
        }

        var event = EventRecord(
            batchId: batchId,
            timestamp: timestamp,
            fileId: fileId,
            trackId: nil,
            eventType: eventType,
            payloadJson: forwardJsonString,
            inversePayloadJson: inverseJsonString
        )
        try event.insert(db)
        guard let eventId = event.eventId else {
            throw OperationEngineError.insertDidNotReturnRowId
        }
        return eventId
    }
}

// MARK: - Mutation types

/// Every state-changing operation in crate-agent is one of these
/// cases. SP-1 v1 covers indexing new files and renaming files; later
/// sub-projects add setTagField (SP-1.5), applyMusicBrainzMatch (SP-2),
/// replaceFile (Pillar F), etc.
public enum TrackMutation: Sendable {
    case indexNewFile(IndexNewFilePayload)
    case renameFile(RenameFilePayload)
}

/// Payload for indexing a newly-discovered file. `lightweightHash` is
/// the first-1MB + last-1MB SHA-256 used for cross-volume move
/// detection; the full Chromaprint fingerprint lands later from the
/// background fingerprinting worker.
public struct IndexNewFilePayload: Codable, Sendable, Equatable {
    public let path: String
    public let volumeUuid: String
    public let inode: Int64
    public let fileSize: Int64
    public let mtime: Int64
    public let lightweightHash: Data?

    public init(
        path: String,
        volumeUuid: String,
        inode: Int64,
        fileSize: Int64,
        mtime: Int64,
        lightweightHash: Data? = nil
    ) {
        self.path = path
        self.volumeUuid = volumeUuid
        self.inode = inode
        self.fileSize = fileSize
        self.mtime = mtime
        self.lightweightHash = lightweightHash
    }
}

/// Payload for renaming/moving a known file. `previousPath` is set to
/// the file's current path at apply time so the journal entry is
/// self-contained (history rendering doesn't need a back-reference to
/// the row at journal-write time). Callers pass `previousPath = ""`
/// for forward invocation; the engine populates it before journaling.
public struct RenameFilePayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let newPath: String
    public let previousPath: String

    public init(fileId: Int64, newPath: String, previousPath: String = "") {
        self.fileId = fileId
        self.newPath = newPath
        self.previousPath = previousPath
    }
}

/// Inverse-only payload used by IndexNewFile's journal entry. Not yet
/// exposed as a public mutation in SP-1 v1 — added when the FSEvents
/// watcher needs to handle real delete events.
public struct RemoveFilePayload: Codable, Sendable, Equatable {
    public let fileId: Int64

    public init(fileId: Int64) {
        self.fileId = fileId
    }
}

// MARK: - Errors

public enum OperationEngineError: LocalizedError, Equatable {
    case fileNotFound(fileId: Int64)
    case insertDidNotReturnRowId
    case payloadEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let fileId):
            return "Mutation referenced file id \(fileId), which is not in the database."
        case .insertDidNotReturnRowId:
            return "Database insert did not produce a row id — schema or driver invariant broken."
        case .payloadEncodingFailed:
            return "Could not encode mutation payload as UTF-8 JSON."
        }
    }
}
