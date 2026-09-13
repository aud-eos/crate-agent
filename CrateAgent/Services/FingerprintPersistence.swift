import Foundation
import GRDB

/// The single `files` row write every fingerprinting outcome goes through —
/// shared by `FingerprintWorker`'s batch flush (copy-from-twin, representative,
/// and sibling-propagation writes) and `AutoTaggerService`'s on-demand
/// ensure-fingerprint path. One `UPDATE` definition, not four.
enum FingerprintPersistence {
    static func write(fileID: Int64, fingerprint: Data?, status: FingerprintStatus, in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE files
            SET chromaprint_fingerprint = ?,
                fingerprint_status = ?
            WHERE id = ?
            """,
            arguments: [fingerprint, status.rawValue, fileID]
        )
    }
}
