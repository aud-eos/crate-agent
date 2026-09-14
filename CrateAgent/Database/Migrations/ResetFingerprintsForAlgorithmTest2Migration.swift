import Foundation
import GRDB

/// Resets every row's fingerprint state so the worker re-fingerprints
/// the library under chromaprint's TEST2 algorithm (switched to in the
/// same PR as this migration, for AcoustID compatibility).
///
/// Why this is necessary: TEST1 and TEST2 use different classifiers,
/// so a fingerprint produced under one is not comparable to one
/// produced under the other. Every fingerprint already stored was
/// computed under TEST1 and must be discarded so it regenerates under
/// TEST2 -- otherwise those tracks would silently keep a fingerprint
/// AcoustID can never match.
///
/// The reset only affects `done` rows. `pending` rows just continue
/// being processed by the worker (now under TEST2). `failed` rows are
/// left as-is -- they failed for a reason the algorithm switch doesn't
/// fix.
enum ResetFingerprintsForAlgorithmTest2Migration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("008_reset_fingerprints_for_algorithm_test2") { db in
            try db.execute(
                sql: """
                UPDATE files
                SET chromaprint_fingerprint = NULL,
                    fingerprint_status = 'pending'
                WHERE fingerprint_status = 'done'
                """
            )
        }
    }
}
