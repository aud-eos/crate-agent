import Foundation
import GRDB

/// UniFFI emits only immutable UInt32/Data value fields, without Sendable conformance.
extension SeratoRemovedRecord: @unchecked Sendable {}

/// What each landed removal took out of a Serato store, and where a cleaned-up
/// file's audio went in Trash: the inputs an undo needs to put both back.
enum SeratoRemovalCaptureStore {
    /// What one removal attempt found in a store.
    enum Outcome: String, Sendable {
        case removed
        case nothingRemoved = "nothing_removed"
        /// The store held nothing on a retry after an attempt whose I/O may
        /// have landed and whose capture rolled back with its transaction.
        case unrecorded
    }

    struct SeratoRemovalCapture: Sendable {
        let storePath: String
        let trackPath: String
        let records: [SeratoRemovedRecord]
        let outcome: Outcome

        var isUnrecorded: Bool {
            outcome == .unrecorded
        }
    }

    /// The generated `SeratoRemovedRecord` cannot synthesize Codable outside its own file.
    private struct StoredRecord: Codable {
        let index: UInt32
        let record: Data
    }

    /// Every store a removal checks is recorded, so a retry can tell a store an
    /// earlier attempt committed from one whose capture rolled back. A committed
    /// outcome is kept unless this attempt found records it did not.
    static func save(eventID: Int64, storePath: String, trackPath: String, records: [SeratoRemovedRecord],
                     earlierAttemptMayHaveLanded: Bool, in database: Database) throws
    {
        let existing = try String.fetchOne(database, sql: "SELECT outcome FROM serato_removal_captures WHERE event_id = ? AND store_path = ?",
                                           arguments: [eventID, storePath])
        guard existing == nil || (!records.isEmpty && existing != Outcome.removed.rawValue) else { return }
        let outcome: Outcome = !records.isEmpty ? .removed : earlierAttemptMayHaveLanded ? .unrecorded : .nothingRemoved
        let stored = records.map { removed in StoredRecord(index: removed.index, record: removed.record) }
        try database.execute(sql: """
        INSERT OR REPLACE INTO serato_removal_captures (event_id, store_path, track_path, records, outcome, captured_at) VALUES (?, ?, ?, ?, ?, ?)
        """, arguments: [eventID, storePath, trackPath, JSONEncoder().encode(stored), outcome.rawValue, SeratoWriteQueue.now()])
    }

    static func captures(eventID: Int64, in database: Database) throws -> [SeratoRemovalCapture] {
        try Row.fetchAll(database, sql: "SELECT store_path, track_path, records, outcome FROM serato_removal_captures WHERE event_id = ? ORDER BY store_path",
                         arguments: [eventID]).map { row in
            let stored = try JSONDecoder().decode([StoredRecord].self, from: row["records"])
            let rawOutcome: String = row["outcome"]
            guard let outcome = Outcome(rawValue: rawOutcome) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown removal capture outcome \(rawOutcome)."))
            }
            return SeratoRemovalCapture(storePath: row["store_path"], trackPath: row["track_path"],
                                        records: stored.map { record in SeratoRemovedRecord(index: record.index, record: record.record) },
                                        outcome: outcome)
        }
    }

    static func saveTrashDestination(eventID: Int64, originalPath: String, identity: FileMetadata, in database: Database) throws {
        try database.execute(sql: "INSERT INTO removal_trash_destinations (event_id, original_path, trash_identity) VALUES (?, ?, ?)",
                             arguments: [eventID, originalPath, JSONEncoder().encode(identity)])
    }

    static func trashDestination(eventID: Int64, in database: Database) throws -> (originalPath: String, identity: FileMetadata)? {
        guard let row = try Row.fetchOne(database, sql: "SELECT original_path, trash_identity FROM removal_trash_destinations WHERE event_id = ?",
                                         arguments: [eventID]) else { return nil }
        return try (originalPath: row["original_path"], identity: JSONDecoder().decode(FileMetadata.self, from: row["trash_identity"]))
    }
}
