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

extension SeratoMetadata {
    /// The fields this update sets, over `original` for the rest.
    func overlaid(on original: SeratoMetadata) -> SeratoMetadata {
        SeratoMetadata(artist: artist ?? original.artist, title: title ?? original.title,
                       album: album ?? original.album, genre: genre ?? original.genre,
                       bpm: bpm ?? original.bpm, musicalKey: musicalKey ?? original.musicalKey,
                       comment: comment ?? original.comment, length: length ?? original.length,
                       label: label ?? original.label)
    }
}

struct SeratoQueuedWritePayload: Codable, Equatable, Sendable {
    let write: SeratoPendingWrite
    let originalIdentity: FileMetadata
    let originalReferencePaths: [String]
    let externalBaseline: SeratoMetadata?
    let baselineKnownFields: [String]?
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
    private static let columns = "queue_id, event_id, kind, file_id, membership_revision, payload, cleanup_target_file_id, attempts, last_error, may_have_landed, io_started"

    @discardableResult
    static func insert(_ write: GuardedSeratoWrite, cleanupTargetFileID: Int64? = nil, locator: SeratoLibraryLocator,
                       ignoringExisting: Bool = false, in database: Database) throws -> GuardedSeratoWrite
    {
        var stored = write
        stored.originalReferencePaths = write.originalReferencePaths.isEmpty ? write.write.referencePaths : write.originalReferencePaths
        if case let .metadataUpdate(update) = write.write, stored.externalBaseline == nil {
            if let loaded = try SeratoExternalBaselines.load(token: write.token, identity: write.originalIdentity, locator: locator, in: database) {
                stored.externalBaseline = loaded
            } else if let previous = try OperationEngine.journaledV2Previous(eventID: write.eventId, in: database) {
                (stored.externalBaseline, stored.baselineKnownFields) = try journaledBaseline(previous, for: update, token: write.token, in: database)
            }
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

    /// With no observed baseline, the producing event's pre-edit values stand
    /// in for what Serato holds. A field an earlier queued edit of ours still
    /// owes was never written, so it takes that edit's baseline, or stays
    /// unknown when that edit's baseline is unknown too.
    private static func journaledBaseline(_ previous: SeratoMetadata, for update: SeratoPendingMetadataUpdate, token: FileMembershipToken,
                                          in database: Database) throws -> (SeratoMetadata, Set<String>)
    {
        var baseline = previous
        var known = Set(OperationEngine.metadataFieldMap(update.metadata).keys)
        var resolved = Set<String>()
        for earlier in try fetch(fileID: token.fileId, in: database) where earlier.token == token {
            guard case let .metadataUpdate(owed) = earlier.write else { continue }
            let shared = Set(OperationEngine.metadataFieldMap(owed.metadata).keys).intersection(known).subtracting(resolved)
            resolved.formUnion(shared)
            let carried = shared.filter { field in earlier.knowsBaseline(of: field) }
            if let earlierBaseline = earlier.externalBaseline {
                baseline = OperationEngine.merging(carried, from: earlierBaseline, into: baseline)
            }
            known.subtract(shared.subtracting(carried))
        }
        return (baseline, known)
    }

    static func fetchOrdered(in database: Database) throws -> [GuardedSeratoWrite] {
        try Row.fetchAll(database, sql: "SELECT \(columns) FROM serato_write_queue ORDER BY queue_id").map(decode)
    }

    static func fetch(fileID: Int64, in database: Database) throws -> [GuardedSeratoWrite] {
        try Row.fetchAll(database, sql: "SELECT \(columns) FROM serato_write_queue WHERE file_id = ? ORDER BY queue_id", arguments: [fileID]).map(decode)
    }

    static func fetch(queueID: Int64, in database: Database) throws -> GuardedSeratoWrite? {
        try Row.fetchOne(database, sql: "SELECT \(columns) FROM serato_write_queue WHERE queue_id = ?", arguments: [queueID]).map(decode)
    }

    /// Later queued V2 edits for the same file revision captured their
    /// baseline before `completed` was written. Its written fields are now
    /// the saved values those edits replace.
    static func rebaseMetadata(after completed: GuardedSeratoWrite, in database: Database) throws {
        guard case let .metadataUpdate(update) = completed.write, let queueID = completed.queueID else { return }
        let later = try Row.fetchAll(database, sql: """
        SELECT \(columns) FROM serato_write_queue
        WHERE file_id = ? AND membership_revision = ? AND kind = ? AND queue_id > ? ORDER BY queue_id
        """, arguments: [completed.token.fileId, completed.token.revision, SeratoWriteKind.metadataUpdate.rawValue, queueID]).map(decode)
        let written = Set(OperationEngine.metadataFieldMap(update.metadata).keys)
        for var write in later {
            if let baseline = write.externalBaseline {
                write.externalBaseline = update.metadata.overlaid(on: baseline)
                write.baselineKnownFields = write.baselineKnownFields?.union(written)
            } else {
                write.externalBaseline = update.metadata
                write.baselineKnownFields = written
            }
            _ = try replace(write, in: database)
        }
    }

    /// Moves rows whose stored payload no longer decodes out of the queue,
    /// recording each one, so one damaged row cannot stop every other write.
    static func quarantineMalformed(in database: Database) throws {
        let rows = try Row.fetchAll(database, sql: "SELECT \(columns) FROM serato_write_queue ORDER BY queue_id")
        for row in rows {
            do { _ = try decode(row) }
            catch let SeratoWriteQueueError.malformedRow(queueID) {
                try database.execute(sql: "DELETE FROM serato_write_queue WHERE queue_id = ?", arguments: [queueID])
                try SeratoWriteDispositions.record(eventID: row["event_id"], kind: SeratoWriteKind(rawValue: row["kind"]), disposition: .malformed,
                                                   detail: "Queued change \(queueID) (\(row["kind"] as String)) was unreadable and was not applied.",
                                                   reported: false, in: database)
            }
        }
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

    /// A new attempt keeps whether the previous one may have landed before
    /// it starts its own I/O marker over.
    static func recordAttempt(_ writes: [GuardedSeratoWrite], in database: Database) throws {
        for queueID in writes.compactMap(\.queueID) {
            try database.execute(sql: """
                                 UPDATE serato_write_queue SET may_have_landed = may_have_landed OR io_started, io_started = 0,
                                   attempts = attempts + 1, last_attempt_at = ?, last_error = NULL WHERE queue_id = ?
                                 """,
                                 arguments: [now(), queueID])
        }
    }

    /// Committed before the transaction that performs external I/O, so a
    /// process that dies during that I/O leaves the rows marked.
    static func markIOStarting(_ queueIDs: [Int64], in database: Database) throws {
        for queueID in queueIDs {
            try database.execute(sql: "UPDATE serato_write_queue SET io_started = 1 WHERE queue_id = ?", arguments: [queueID])
        }
    }

    static func clearIOStarted(_ queueIDs: some Collection<Int64>, in database: Database) throws {
        for queueID in queueIDs {
            try database.execute(sql: "UPDATE serato_write_queue SET io_started = 0 WHERE queue_id = ?", arguments: [queueID])
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
                                                          externalBaseline: write.externalBaseline,
                                                          baselineKnownFields: write.baselineKnownFields.map { fields in fields.sorted() }))
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
        write.baselineKnownFields = payload.baselineKnownFields.map(Set.init)
        write.queueID = queueID
        write.queuedPayload = bytes
        write.attempts = row["attempts"]
        write.lastError = row["last_error"]
        write.earlierAttemptMayHaveLanded = row["may_have_landed"]
        write.ioStarted = row["io_started"]
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

enum SeratoWriteDisposition: String, Sendable, CaseIterable {
    case superseded
    case uncertain
    case interrupted
    case legacyUnrecoverable
    case malformed
    case noSeratoRecord
}

/// Not-applied queued changes by disposition, each counted once per event.
struct SeratoWriteDispositionCounts: Sendable, Equatable {
    var counts: [SeratoWriteDisposition: Int] = [:]
    /// Changes recorded with an outcome this version does not know, such as
    /// one written by a newer build before a downgrade.
    var unrecognized = 0

    subscript(disposition: SeratoWriteDisposition) -> Int {
        counts[disposition] ?? 0
    }

    var total: Int {
        counts.values.reduce(unrecognized, +)
    }
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
        var result = SeratoWriteDispositionCounts()
        for row in try Row.fetchAll(database, sql: "SELECT disposition, COUNT(DISTINCT event_id) AS count FROM serato_write_dispositions WHERE reported = 0 GROUP BY disposition") {
            if let disposition = SeratoWriteDisposition(rawValue: row["disposition"]) {
                result.counts[disposition] = row["count"]
            } else {
                result.unrecognized += row["count"] as Int
            }
        }
        try database.execute(sql: "UPDATE serato_write_dispositions SET reported = 1 WHERE reported = 0")
        return result
    }

    /// Not-applied event counts per History batch.
    static func notAppliedCounts(in database: Database) throws -> [String: Int] {
        try Row.fetchAll(database, sql: "SELECT batch_id, COUNT(DISTINCT event_id) AS count FROM serato_write_dispositions GROUP BY batch_id")
            .reduce(into: [String: Int]()) { counts, row in counts[row["batch_id"]] = row["count"] }
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
        let evidenceRequirement: DuplicateEvidenceRequirement?
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
        let authority = try JSONEncoder().encode(Authority(target: intent.target, keeper: intent.keeper, batchID: intent.batchID,
                                                           evidenceRequirement: intent.evidenceRequirement))
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
        var intent = PendingDuplicateCleanup(target: authority.target, keeper: authority.keeper, batchID: authority.batchID,
                                             evidenceRequirement: authority.evidenceRequirement)
        intent.step = row["step"]
        intent.waitingEventID = row["waiting_event_id"]
        intent.removedV2 = row["removed_v2"]
        intent.failure = row["failure"]
        return intent
    }
}
