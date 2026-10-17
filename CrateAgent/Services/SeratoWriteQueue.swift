import Foundation
import GRDB

enum SeratoWriteKind: String, Codable, Sendable {
    case rename
    case metadataUpdate
    case addTrack
    case fileTagWrite
    case removeFromDatabase
    case removeFromCrates
    case trashFile
}

extension SeratoPendingWrite: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    var kind: SeratoWriteKind {
        switch self {
        case .rename: .rename
        case .metadataUpdate: .metadataUpdate
        case .addTrack: .addTrack
        case .fileTagWrite: .fileTagWrite
        case .removeFromDatabase: .removeFromDatabase
        case .removeFromCrates: .removeFromCrates
        case .trashFile: .trashFile
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(SeratoWriteKind.self, forKey: .kind) {
        case .rename: self = try .rename(container.decode(SeratoPendingRename.self, forKey: .value))
        case .metadataUpdate: self = try .metadataUpdate(container.decode(SeratoPendingMetadataUpdate.self, forKey: .value))
        case .addTrack: self = try .addTrack(container.decode(SeratoPendingAddTrack.self, forKey: .value))
        case .fileTagWrite: self = try .fileTagWrite(container.decode(SeratoPendingFileTagWrite.self, forKey: .value))
        case .removeFromDatabase: self = try .removeFromDatabase(container.decode(SeratoPendingRemoval.self, forKey: .value))
        case .removeFromCrates: self = try .removeFromCrates(container.decode(SeratoPendingRemoval.self, forKey: .value))
        case .trashFile: self = try .trashFile(container.decode(SeratoPendingTrash.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case let .rename(value): try container.encode(value, forKey: .value)
        case let .metadataUpdate(value): try container.encode(value, forKey: .value)
        case let .addTrack(value): try container.encode(value, forKey: .value)
        case let .fileTagWrite(value): try container.encode(value, forKey: .value)
        case let .removeFromDatabase(value), let .removeFromCrates(value): try container.encode(value, forKey: .value)
        case let .trashFile(value): try container.encode(value, forKey: .value)
        }
    }
}

struct SeratoQueuedWritePayload: Codable, Equatable, Sendable {
    let write: SeratoPendingWrite
    let originalIdentity: FileMetadata
    let originalReferencePaths: [String]
    let externalBaseline: SeratoMetadata?
}

enum SeratoWriteQueueError: LocalizedError {
    case malformedRow(queueID: Int64)

    var errorDescription: String? {
        switch self {
        case let .malformedRow(queueID): "Queued Serato change \(queueID) is unreadable. Review History before retrying sync."
        }
    }
}

/// The durable queue of Serato-side effects. A row is inserted in the same
/// transaction as the mutation that produced it and deleted in the writer
/// transaction that performs (or supersedes) its I/O.
enum SeratoWriteQueue {
    private static let columns = "queue_id, event_id, kind, file_id, membership_revision, payload, cleanup_target_file_id, attempts, last_error"

    @discardableResult
    static func insert(_ write: GuardedSeratoWrite, cleanupTargetFileID: Int64? = nil, locator: SeratoLibraryLocator,
                       ignoringExisting: Bool = false, in database: Database) throws -> GuardedSeratoWrite
    {
        var stored = write
        stored.originalReferencePaths = write.originalReferencePaths.isEmpty ? write.write.referencePaths : write.originalReferencePaths
        if case .metadataUpdate = write.write, stored.externalBaseline == nil {
            stored.externalBaseline = try SeratoExternalBaselines.load(token: write.token, identity: write.originalIdentity, locator: locator, in: database)
        }
        let payload = try encode(stored)
        let verb = ignoringExisting ? "INSERT OR IGNORE" : "INSERT"
        try database.execute(sql: """
        \(verb) INTO serato_write_queue (event_id, kind, file_id, membership_revision, payload, cleanup_target_file_id, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, arguments: [write.eventId, write.write.kind.rawValue, write.token.fileId, write.token.revision, payload,
                         cleanupTargetFileID, Self.now()])
        if database.changesCount > 0 {
            stored.queueID = database.lastInsertedRowID
            stored.queuedPayload = payload
            stored.cleanupTargetFileID = cleanupTargetFileID
            return stored
        }
        guard let existing = try Row.fetchOne(database, sql: "SELECT \(columns) FROM serato_write_queue WHERE event_id = ? AND kind = ?",
                                              arguments: [write.eventId, write.write.kind.rawValue])
        else {
            throw OperationEngineError.insertDidNotReturnRowId
        }
        return try decode(existing)
    }

    static func fetchOrdered(in database: Database) throws -> [GuardedSeratoWrite] {
        try Row.fetchAll(database, sql: "SELECT \(columns) FROM serato_write_queue ORDER BY queue_id").map(decode)
    }

    static func fetch(fileID: Int64, in database: Database) throws -> [GuardedSeratoWrite] {
        try Row.fetchAll(database, sql: "SELECT \(columns) FROM serato_write_queue WHERE file_id = ? ORDER BY queue_id", arguments: [fileID]).map(decode)
    }

    static func fetch(cleanupTargetFileID: Int64, in database: Database) throws -> [GuardedSeratoWrite] {
        try Row.fetchAll(database, sql: "SELECT \(columns) FROM serato_write_queue WHERE cleanup_target_file_id = ? ORDER BY queue_id",
                         arguments: [cleanupTargetFileID]).map(decode)
    }

    static func exists(eventID: Int64, in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM serato_write_queue WHERE event_id = ?)", arguments: [eventID]) ?? false
    }

    /// Whether the row still holds exactly the payload a pass loaded. A missing
    /// row was completed or superseded by another pass; a changed row was
    /// reduced by a newer observation and must be reloaded before any I/O.
    static func state(of write: GuardedSeratoWrite, in database: Database) throws -> RowState {
        guard let queueID = write.queueID, let payload = try Data.fetchOne(database, sql: "SELECT payload FROM serato_write_queue WHERE queue_id = ?", arguments: [queueID]) else {
            return .missing
        }
        return payload == write.queuedPayload ? .current : .changed
    }

    enum RowState {
        case current
        case changed
        case missing
    }

    static func replace(_ write: GuardedSeratoWrite, in database: Database) throws -> GuardedSeratoWrite {
        guard let queueID = write.queueID else { throw OperationEngineError.insertDidNotReturnRowId }
        var stored = write
        let payload = try encode(write)
        try database.execute(sql: "UPDATE serato_write_queue SET payload = ? WHERE queue_id = ?", arguments: [payload, queueID])
        stored.queuedPayload = payload
        return stored
    }

    @discardableResult
    static func delete(_ write: GuardedSeratoWrite, in database: Database) throws -> Bool {
        guard let queueID = write.queueID else { return false }
        try database.execute(sql: "DELETE FROM serato_write_queue WHERE queue_id = ?", arguments: [queueID])
        return database.changesCount > 0
    }

    static func count(in database: Database) throws -> Int {
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM serato_write_queue") ?? 0
    }

    static func pendingEventCount(in database: Database) throws -> Int {
        try Int.fetchOne(database, sql: "SELECT COUNT(DISTINCT event_id) FROM serato_write_queue") ?? 0
    }

    static func recordAttempt(_ writes: [GuardedSeratoWrite], in database: Database) throws {
        for queueID in writes.compactMap(\.queueID) {
            try database.execute(sql: "UPDATE serato_write_queue SET attempts = attempts + 1, last_attempt_at = ? WHERE queue_id = ?",
                                 arguments: [now(), queueID])
        }
    }

    static func recordFailure(_ writes: [GuardedSeratoWrite], message: String, in database: Database) throws {
        for queueID in writes.compactMap(\.queueID) {
            try database.execute(sql: "UPDATE serato_write_queue SET last_error = ? WHERE queue_id = ?", arguments: [message, queueID])
        }
    }

    static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func encode(_ write: GuardedSeratoWrite) throws -> Data {
        try JSONEncoder().encode(SeratoQueuedWritePayload(write: write.write, originalIdentity: write.originalIdentity,
                                                          originalReferencePaths: write.originalReferencePaths,
                                                          externalBaseline: write.externalBaseline))
    }

    private static func decode(_ row: Row) throws -> GuardedSeratoWrite {
        let queueID: Int64 = row["queue_id"]
        let bytes: Data = row["payload"]
        let payload: SeratoQueuedWritePayload
        do { payload = try SyncCheckpointStore.decodeCanonical(SeratoQueuedWritePayload.self, from: bytes) }
        catch { throw SeratoWriteQueueError.malformedRow(queueID: queueID) }
        guard payload.write.kind.rawValue == row["kind"] as String else { throw SeratoWriteQueueError.malformedRow(queueID: queueID) }
        var write = GuardedSeratoWrite(token: FileMembershipToken(fileId: row["file_id"], revision: row["membership_revision"]),
                                       write: payload.write, eventId: row["event_id"], originalIdentity: payload.originalIdentity,
                                       originalReferencePaths: payload.originalReferencePaths, externalBaseline: payload.externalBaseline)
        write.queueID = queueID
        write.queuedPayload = bytes
        write.attempts = row["attempts"]
        write.lastError = row["last_error"]
        write.cleanupTargetFileID = row["cleanup_target_file_id"]
        return write
    }
}

/// The last authorized external `database V2` metadata per file revision.
/// Successful own V2 writes and strict observations update it in the same
/// transaction, so a later queued edit captures a baseline that reflects them.
enum SeratoExternalBaselines {
    static func load(token: FileMembershipToken, identity: FileMetadata, locator: SeratoLibraryLocator, in database: Database) throws -> SeratoMetadata? {
        if let row = try Row.fetchOne(database, sql: "SELECT membership_revision, metadata FROM serato_external_baselines WHERE file_id = ?",
                                      arguments: [token.fileId]),
            row["membership_revision"] as Int64 == token.revision
        {
            let bytes: Data = row["metadata"]
            return try SyncCheckpointStore.decodeCanonical(SeratoMetadata.self, from: bytes)
        }
        return try SyncCheckpointStore.checkpointBaseline(token: token, identity: identity, locator: locator, in: database)
    }

    static func save(_ metadata: SeratoMetadata, token: FileMembershipToken, in database: Database) throws {
        try database.execute(sql: "INSERT OR REPLACE INTO serato_external_baselines (file_id, membership_revision, metadata) VALUES (?, ?, ?)",
                             arguments: [token.fileId, token.revision, JSONEncoder().encode(metadata)])
    }
}

enum SeratoWriteDisposition: String, Sendable {
    case superseded
    case uncertain
    case interrupted
    case legacyUnrecoverable
}

struct SeratoWriteDispositionCounts: Sendable, Equatable {
    var notApplied = 0
    var interrupted = 0
}

/// Durable record of queued work that will not be applied, so a restart cannot
/// hide a dropped write behind an in-memory count.
enum SeratoWriteDispositions {
    static func record(eventID: Int64, kind: SeratoWriteKind?, disposition: SeratoWriteDisposition, detail: String?,
                       reported: Bool, in database: Database) throws
    {
        try database.execute(sql: """
        INSERT INTO serato_write_dispositions (event_id, batch_id, kind, disposition, detail, created_at, reported)
        VALUES (?, COALESCE((SELECT batch_id FROM events WHERE event_id = ?), ''), ?, ?, ?, ?, ?)
        """, arguments: [eventID, eventID, kind?.rawValue ?? "unknown", disposition.rawValue, detail, SeratoWriteQueue.now(), reported])
    }

    static func hasUnreported(in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM serato_write_dispositions WHERE reported = 0)") ?? false
    }

    static func takeUnreported(in database: Database) throws -> SeratoWriteDispositionCounts {
        let interrupted = try Int.fetchOne(database, sql: "SELECT COUNT(DISTINCT event_id) FROM serato_write_dispositions WHERE reported = 0 AND disposition = ?",
                                           arguments: [SeratoWriteDisposition.interrupted.rawValue]) ?? 0
        let notApplied = try Int.fetchOne(database, sql: "SELECT COUNT(DISTINCT event_id) FROM serato_write_dispositions WHERE reported = 0 AND disposition != ?",
                                          arguments: [SeratoWriteDisposition.interrupted.rawValue]) ?? 0
        try database.execute(sql: "UPDATE serato_write_dispositions SET reported = 1 WHERE reported = 0")
        return SeratoWriteDispositionCounts(notApplied: notApplied, interrupted: interrupted)
    }
}

/// Duplicate cleanup is a durable state machine: the intent row is created in
/// the transaction of its first step and advanced in the transactions that
/// complete each step's external effects.
enum DuplicateCleanupStore {
    private struct Authority: Codable {
        let target: FileActionAuthority
        let keeper: FileActionAuthority
        let batchID: String
    }

    static func fetch(targetFileID: Int64, in database: Database) throws -> PendingDuplicateCleanup? {
        try Row.fetchOne(database, sql: "SELECT * FROM duplicate_cleanup_intents WHERE target_file_id = ?", arguments: [targetFileID]).map(decode)
    }

    static func fetchAll(in database: Database) throws -> [PendingDuplicateCleanup] {
        try Row.fetchAll(database, sql: "SELECT * FROM duplicate_cleanup_intents ORDER BY target_file_id").map(decode)
    }

    static func exists(in database: Database) throws -> Bool {
        try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM duplicate_cleanup_intents)") ?? false
    }

    static func save(_ intent: PendingDuplicateCleanup, in database: Database) throws {
        let authority = try JSONEncoder().encode(Authority(target: intent.target, keeper: intent.keeper, batchID: intent.batchID))
        try database.execute(sql: """
        INSERT OR REPLACE INTO duplicate_cleanup_intents (target_file_id, payload, step, waiting_event_id, removed_v2, failure)
        VALUES (?, ?, ?, ?, ?, ?)
        """, arguments: [intent.target.token.fileId, authority, intent.step, intent.waitingEventID, intent.removedV2, intent.failure])
    }

    static func delete(targetFileID: Int64, in database: Database) throws {
        try database.execute(sql: "DELETE FROM duplicate_cleanup_intents WHERE target_file_id = ?", arguments: [targetFileID])
    }

    static func confirmDatabaseRemoval(targetFileID: Int64, in database: Database) throws {
        try database.execute(sql: "UPDATE duplicate_cleanup_intents SET removed_v2 = 1 WHERE target_file_id = ?", arguments: [targetFileID])
    }

    static func recordFailure(targetFileID: Int64, message: String, in database: Database) throws {
        try database.execute(sql: "UPDATE duplicate_cleanup_intents SET failure = ? WHERE target_file_id = ?", arguments: [message, targetFileID])
    }

    static func clearFailures(in database: Database) throws {
        try database.execute(sql: "UPDATE duplicate_cleanup_intents SET failure = NULL")
    }

    /// Advances the waiting step once its last queued effect is gone. Runs in the
    /// transaction that deletes that effect's row.
    static func completeEffect(of write: GuardedSeratoWrite, in database: Database) throws {
        guard let targetFileID = write.cleanupTargetFileID, var intent = try fetch(targetFileID: targetFileID, in: database),
              intent.waitingEventID == write.eventId,
              try !SeratoWriteQueue.exists(eventID: write.eventId, in: database) else { return }
        intent.step += 1
        intent.waitingEventID = nil
        intent.failure = nil
        try save(intent, in: database)
    }

    private static func decode(_ row: Row) throws -> PendingDuplicateCleanup {
        let bytes: Data = row["payload"]
        let authority = try SyncCheckpointStore.decodeCanonical(Authority.self, from: bytes)
        var intent = PendingDuplicateCleanup(target: authority.target, keeper: authority.keeper, batchID: authority.batchID)
        intent.step = row["step"]
        intent.waitingEventID = row["waiting_event_id"]
        intent.removedV2 = row["removed_v2"]
        intent.failure = row["failure"]
        return intent
    }
}
