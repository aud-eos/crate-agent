import Foundation
import GRDB

/// Resets every row's fingerprint state so the worker re-fingerprints
/// the library under the new 120-second cap (introduced in the same
/// PR as this migration).
///
/// Why this is necessary: Chromaprint hashes generated from "full
/// audio" vs "first 120 seconds" of the same file are different byte
/// sequences. Mixing both in one library would mean perceptual
/// duplicate detection can't match a track fingerprinted under the
/// old rule against a track fingerprinted under the new rule. Better
/// to take the one-time re-fingerprint cost than to leave the library
/// in an internally inconsistent state.
///
/// The reset only affects `done` rows. `pending` rows just continue
/// being processed by the worker (under the new cap). `failed` rows
/// are left as-is — they failed for a reason that the duration cap
/// doesn't fix.
enum ResetFingerprintsForDurationCapMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("005_reset_fingerprints_for_duration_cap") { db in
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
