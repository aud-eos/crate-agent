import Foundation
import GRDB

/// Adds `fingerprinted_size` / `fingerprinted_mtime` to the `files` table:
/// the file's on-disk size + mtime AT THE TIME its current Chromaprint
/// fingerprint was computed.
///
/// Why this exists (finding #3999114461): the auto-tagger only trusts a
/// stored `.done` fingerprint for a lookup when the file's live on-disk stat
/// still matches the stat the fingerprint was computed from. Before this
/// column that basis was read from the general-purpose `files.file_size` /
/// `mtime` (the index-time snapshot). But an on-demand recompute persisted
/// only the fingerprint bytes — never a new basis — so once a file was edited
/// (or an Auto-Tag apply rewrote it), the live stat never matched the frozen
/// index snapshot again and every subsequent scan re-decoded up to 120s of
/// audio, even immediately after a successful recompute.
///
/// Recording the fingerprint's OWN basis decouples freshness from
/// `file_size`/`mtime` (which other flows read for dup grouping, ranking,
/// display) and lets a recompute update the basis in lock-step with the bytes.
///
/// Additive and nullable: existing rows (and rows the background worker
/// fingerprints at index time) leave these NULL and fall back to
/// `file_size`/`mtime`, which for those rows still IS the fingerprint's basis.
enum AddFingerprintFreshnessBasisMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("009_add_fingerprint_freshness_basis") { db in
            try db.alter(table: "files") { table in
                table.add(column: "fingerprinted_size", .integer)
                table.add(column: "fingerprinted_mtime", .integer)
            }
        }
    }
}
