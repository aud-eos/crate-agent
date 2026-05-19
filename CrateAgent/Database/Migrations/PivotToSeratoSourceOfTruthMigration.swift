import Foundation
import GRDB

/// Wipes the `files` and `events` tables on first run after the
/// design pivot to "Serato is the source of truth." Pre-pivot
/// crate-agent walked the filesystem and indexed every audio file
/// it found, which under the new model means the existing `files`
/// rows are a confusing mixture of Serato-known and Serato-unknown
/// tracks, and the existing `events` journal references files that
/// no longer apply to the new indexing rules.
///
/// The next launch's LibraryScanner reads from Serato's library and
/// repopulates `files` with exactly the set Serato references.
/// `events` rebuilds from scratch as the new mutations land.
///
/// `events` must be deleted before `files` even though events has
/// `ON DELETE SET NULL` on file_id — observed behavior on the real
/// 32k-track production database is that SQLite reports a FOREIGN
/// KEY constraint violation when bulk-deleting parent rows that
/// have many cascading-null children, even with `foreign_keys=ON`.
/// Explicit ordering avoids the issue entirely.
enum PivotToSeratoSourceOfTruthMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("002_pivot_to_serato_source_of_truth") { db in
            try db.execute(sql: "DELETE FROM events")
            try db.execute(sql: "DELETE FROM files")
        }
    }
}
