import Foundation
import GRDB

/// UniFFI emits only immutable UInt32/Data value fields, without Sendable conformance.
extension SeratoRemovedRecord: @unchecked Sendable {}

/// What each landed removal took out of a Serato store, and where a cleaned-up
/// file's audio went in Trash: the inputs an undo needs to put both back.
enum SeratoRemovalCaptureStore {
    /// What a removal found in a store.
    enum Outcome: String, Sendable {
        case removed
        case nothingRemoved = "nothing_removed"
        /// Committed before the store's I/O and replaced in the I/O's own
        /// transaction, so one left behind means that I/O may have landed.
        case inProgress = "in_progress"
        /// A retry found nothing left where an attempt had been in progress:
        /// its records may have been removed, and their capture was lost.
        case unrecorded
    }

    struct SeratoRemovalCapture: Sendable {
        let storePath: String
        let trackPath: String
        let records: [SeratoRemovedRecord]
        let outcome: Outcome

        /// Whether the store's records may have been removed without being recorded.
        var isUnrecorded: Bool {
            outcome == .unrecorded || outcome == .inProgress
        }
    }

    /// The generated `SeratoRemovedRecord` cannot synthesize Codable outside its own file.
    private struct StoredRecord: Codable {
        let index: UInt32
        let record: Data
    }

    /// Marks the store in progress unless an earlier attempt recorded it, in a
    /// transaction committed before the store's I/O. Returns that earlier outcome.
    static func beginRemoval(eventID: Int64, storePath: String, trackPath: String, in database: Database) throws -> Outcome? {
        if let existing = try outcome(eventID: eventID, storePath: storePath, in: database) {
            return existing
        }
        try write(eventID: eventID, storePath: storePath, trackPath: trackPath, records: [], outcome: .inProgress, in: database)
        return nil
    }

    /// Records what the store's I/O removed, in the I/O's own transaction. A
    /// store this attempt found empty after an earlier attempt was in progress
    /// is unrecorded; any other committed outcome is kept.
    static func save(eventID: Int64, storePath: String, trackPath: String, records: [SeratoRemovedRecord],
                     earlierOutcome: Outcome?, in database: Database) throws
    {
        let outcome: Outcome
        switch (earlierOutcome, records.isEmpty) {
        case (.removed, _), (.nothingRemoved, true), (.unrecorded, true): return
        case (_, false): outcome = .removed
        case (nil, true): outcome = .nothingRemoved
        case (.inProgress, true): outcome = .unrecorded
        }
        try write(eventID: eventID, storePath: storePath, trackPath: trackPath, records: records, outcome: outcome, in: database)
    }

    /// Withdraws this attempt's in-progress mark when its I/O cannot have landed.
    static func abandonRemoval(eventID: Int64, storePath: String, earlierOutcome: Outcome?, in database: Database) throws {
        guard earlierOutcome == nil else { return }
        try database.execute(sql: "DELETE FROM serato_removal_captures WHERE event_id = ? AND store_path = ? AND outcome = ?",
                             arguments: [eventID, storePath, Outcome.inProgress.rawValue])
    }

    private static func outcome(eventID: Int64, storePath: String, in database: Database) throws -> Outcome? {
        guard let raw = try String.fetchOne(database, sql: "SELECT outcome FROM serato_removal_captures WHERE event_id = ? AND store_path = ?",
                                            arguments: [eventID, storePath]) else { return nil }
        return try decodeOutcome(raw)
    }

    private static func decodeOutcome(_ raw: String) throws -> Outcome {
        guard let outcome = Outcome(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown removal capture outcome \(raw)."))
        }
        return outcome
    }

    private static func write(eventID: Int64, storePath: String, trackPath: String, records: [SeratoRemovedRecord], outcome: Outcome,
                              in database: Database) throws
    {
        let stored = records.map { removed in StoredRecord(index: removed.index, record: removed.record) }
        try database.execute(sql: """
        INSERT OR REPLACE INTO serato_removal_captures (event_id, store_path, track_path, records, outcome, captured_at) VALUES (?, ?, ?, ?, ?, ?)
        """, arguments: [eventID, storePath, trackPath, JSONEncoder().encode(stored), outcome.rawValue, SeratoWriteQueue.now()])
    }

    static func captures(eventID: Int64, in database: Database) throws -> [SeratoRemovalCapture] {
        try Row.fetchAll(database, sql: "SELECT store_path, track_path, records, outcome FROM serato_removal_captures WHERE event_id = ? ORDER BY store_path",
                         arguments: [eventID]).map { row in
            let stored = try JSONDecoder().decode([StoredRecord].self, from: row["records"])
            let outcome = try decodeOutcome(row["outcome"])
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
