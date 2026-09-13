import Foundation
import GRDB

/// The single `files` row write every fingerprinting outcome goes through —
/// shared by `FingerprintWorker`'s batch flush (copy-from-twin, representative,
/// and sibling-propagation writes) and `AutoTaggerService`'s on-demand
/// ensure-fingerprint path. One `UPDATE` definition, not four.
enum FingerprintPersistence {
    /// - Parameter freshnessBasis: the file's on-disk size + mtime AT THE TIME
    ///   this fingerprint was computed, persisted into
    ///   `fingerprinted_size`/`fingerprinted_mtime` so a later scan can tell a
    ///   trustworthy stored fingerprint from a stale one WITHOUT re-decoding
    ///   (finding #3999114461). Pass it whenever the caller computed the
    ///   fingerprint from the live file (the on-demand path). Nil leaves the
    ///   basis columns untouched — callers that don't have the file's current
    ///   stat (or are clearing a failed fingerprint) fall back to
    ///   `file_size`/`mtime`.
    static func write(
        fileID: Int64,
        fingerprint: Data?,
        status: FingerprintStatus,
        freshnessBasis: FileFreshnessSnapshot? = nil,
        in db: Database
    ) throws {
        if let basis = freshnessBasis {
            try db.execute(
                sql: """
                UPDATE files
                SET chromaprint_fingerprint = ?,
                    fingerprint_status = ?,
                    fingerprinted_size = ?,
                    fingerprinted_mtime = ?
                WHERE id = ?
                """,
                arguments: [fingerprint, status.rawValue, basis.fileSize, basis.mtime, fileID]
            )
        } else {
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
}
