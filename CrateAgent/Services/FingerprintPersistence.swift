import Foundation
import GRDB

/// The single `files` row write every fingerprinting outcome goes through —
/// shared by `FingerprintWorker`'s batch flush (copy-from-twin, representative,
/// and sibling-propagation writes) and `AutoTaggerService`'s on-demand
/// ensure-fingerprint path. One `UPDATE` definition, not four.
enum FingerprintPersistence {
    /// Run inside the writer transaction so supersession rolls back every batch row.
    static func withAuthorization<Result>(
        _ authorization: LibrarySyncReadiness.Authorization?,
        targets: [SeratoConflictTarget] = [],
        perform: () throws -> Result
    ) throws -> Result {
        try Task.checkCancellation()
        try authorization?.check()
        for target in targets {
            try authorization?.check(target: target)
        }
        let result = try perform()
        try Task.checkCancellation()
        try authorization?.check()
        for target in targets {
            try authorization?.check(target: target)
        }
        return result
    }

    /// - Parameter freshnessBasis: the file's on-disk identity AT THE TIME
    ///   this fingerprint was computed, persisted into the `fingerprinted_*`
    ///   columns so a later scan can tell a
    ///   trustworthy stored fingerprint from a stale one WITHOUT re-decoding
    ///   (finding #3999114461). Pass it whenever the caller computed the
    ///   fingerprint from the live file (the on-demand path). Nil leaves the
    ///   basis columns untouched — callers that don't have the file's current
    ///   stat (or are clearing a failed fingerprint) fall back to
    ///   `file_size`/`mtime`.
    /// - Parameter requirePendingStatus: when true the write only lands if the
    ///   row is still `pending`. The background `FingerprintWorker` passes true
    ///   so a flush that completes AFTER `AutoTaggerService` has already
    ///   fingerprinted the same file on demand (a newer `.done` result, whose
    ///   basis is up to date) does not clobber it with the worker's older bytes
    ///   and a stale/absent basis (finding #4000806487). The on-demand path
    ///   leaves it false — it is the authoritative recompute.
    @discardableResult static func write(
        fileID: Int64,
        fingerprint: Data?,
        status: FingerprintStatus,
        failureReason: String? = nil,
        freshnessBasis: FileFreshnessSnapshot? = nil,
        requirePendingStatus: Bool = false,
        expectedMembershipToken: FileMembershipToken? = nil,
        in db: Database
    ) throws -> Bool {
        if let expectedMembershipToken {
            do {
                try FileProcessingEligibility.requireCurrent(expectedMembershipToken, in: db)
            } catch is FileProcessingEligibilityError {
                return false
            }
        }
        let pendingGuard = requirePendingStatus ? " AND fingerprint_status = 'pending'" : ""
        if let basis = freshnessBasis {
            try db.execute(
                sql: """
                UPDATE files
                SET chromaprint_fingerprint = ?,
                    fingerprint_status = ?,
                    fingerprint_failure = ?,
                    fingerprinted_size = ?,
                    fingerprinted_mtime = ?,
                    fingerprinted_mtime_nanoseconds = ?,
                    fingerprinted_inode = ?
                WHERE id = ?\(pendingGuard)
                """,
                arguments: [fingerprint, status.rawValue, failureReason, basis.fileSize, basis.mtime, basis.mtimeNanoseconds, basis.inode, fileID]
            )
        } else {
            try db.execute(
                sql: """
                UPDATE files
                SET chromaprint_fingerprint = ?,
                    fingerprint_status = ?,
                    fingerprint_failure = ?
                WHERE id = ?\(pendingGuard)
                """,
                arguments: [fingerprint, status.rawValue, failureReason, fileID]
            )
        }
        return db.changesCount > 0
    }

    /// Returns `done` rows whose explicit fingerprint basis was recorded before subsecond times
    /// were kept to the worker's queue. Such a basis can never be confirmed, so each file would
    /// otherwise be decoded again on the Auto-Tag path; the worker refreshes it in the
    /// background instead, and Workers counts it as pending. The stored fingerprint stays
    /// until the new one lands, and the refreshed basis is the row's own identity.
    @discardableResult static func requeueUnconfirmableBases(in db: Database) throws -> Int {
        try db.execute(sql: """
        UPDATE files
        SET fingerprint_status = 'pending', fingerprinted_size = NULL, fingerprinted_mtime = NULL,
            fingerprinted_mtime_nanoseconds = NULL, fingerprinted_inode = NULL
        WHERE fingerprint_status = 'done' AND fingerprinted_size IS NOT NULL
          AND (fingerprinted_mtime_nanoseconds IS NULL OR fingerprinted_inode IS NULL)
        """)
        return db.changesCount
    }

    /// Returns failed and invalid `done` rows to `pending` so the worker recomputes them;
    /// valid fingerprints and files that cannot be processed are left alone. Nil retries
    /// every such row.
    @discardableResult static func requeueForRetry(fileIDs: [Int64]?, in db: Database) throws -> Int {
        var sql = """
        UPDATE files
        SET fingerprint_status = 'pending', chromaprint_fingerprint = NULL, fingerprint_failure = NULL
        WHERE \(FileProcessingEligibility.processableSQL)
          AND (fingerprint_status = 'failed' OR (\(WorkerCoverageQuery.invalidDoneSQL)))
        """
        var arguments = StatementArguments()
        if let fileIDs {
            guard !fileIDs.isEmpty else { return 0 }
            sql += " AND id IN (\(databaseQuestionMarks(count: fileIDs.count)))"
            arguments = StatementArguments(fileIDs)
        }
        try db.execute(sql: sql, arguments: arguments)
        return db.changesCount
    }
}
