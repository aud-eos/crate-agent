import Foundation
import GRDB

/// One-time data hygiene migration: deletes any `files` rows whose
/// path lives inside a managed library (Apple Music, iTunes, Logic).
/// Earlier versions of crate-agent indexed those files; this purges
/// them so the library browser only shows folders the user actually
/// manages themselves.
///
/// New installations after this migration ran will have an empty
/// table and skip these locations in the scanner from the start, so
/// the migration is a one-shot cleanup for existing databases.
///
/// `ON DELETE SET NULL` on `events.file_id` means event-log entries
/// pointing at the deleted files are preserved (with their file_id
/// nulled) — the journal of "we once knew about this file" remains.
enum PurgeManagedLibraryRowsMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("002_purge_managed_library_rows") { db in
            let managedAbsolutePaths = ManagedLibraryDetector.fullExcludedPaths()
            for managedPath in managedAbsolutePaths {
                // LIKE pattern matches every row under the managed
                // root. Trailing slash + wildcard ensures we don't
                // accidentally delete a sibling folder whose name
                // starts the same way (e.g., `Music/Music/MediaTwo`
                // wouldn't match `Music/Music/Media/%`).
                try db.execute(
                    sql: "DELETE FROM files WHERE path LIKE ? OR path = ?",
                    arguments: [managedPath + "/%", managedPath]
                )
            }
        }
    }
}
