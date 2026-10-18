import Foundation
import GRDB

/// UniFFI emits only immutable UInt32/Data value fields, without Sendable conformance.
extension SeratoRemovedRecord: @unchecked Sendable {}

/// What each landed removal took out of a Serato store, and where a cleaned-up
/// file's audio went in Trash: the inputs an undo needs to put both back.
enum SeratoRemovalCaptureStore {
    struct SeratoRemovalCapture: Sendable {
        let storePath: String
        let trackPath: String
        let records: [SeratoRemovedRecord]
    }

    /// The generated `SeratoRemovedRecord` cannot synthesize Codable outside its own file.
    private struct StoredRecord: Codable {
        let index: UInt32
        let record: Data
    }

    static func save(eventID: Int64, storePath: String, trackPath: String, records: [SeratoRemovedRecord], in database: Database) throws {
        guard !records.isEmpty else { return }
        let stored = records.map { removed in StoredRecord(index: removed.index, record: removed.record) }
        try database.execute(sql: """
        INSERT INTO serato_removal_captures (event_id, store_path, track_path, records, captured_at) VALUES (?, ?, ?, ?, ?)
        """, arguments: [eventID, storePath, trackPath, JSONEncoder().encode(stored), SeratoWriteQueue.now()])
    }

    static func captures(eventID: Int64, in database: Database) throws -> [SeratoRemovalCapture] {
        try Row.fetchAll(database, sql: "SELECT store_path, track_path, records FROM serato_removal_captures WHERE event_id = ? ORDER BY store_path",
                         arguments: [eventID]).map { row in
            let stored = try JSONDecoder().decode([StoredRecord].self, from: row["records"])
            return SeratoRemovalCapture(storePath: row["store_path"], trackPath: row["track_path"],
                                        records: stored.map { record in SeratoRemovedRecord(index: record.index, record: record.record) })
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
