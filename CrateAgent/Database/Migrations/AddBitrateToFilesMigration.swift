import Foundation
import GRDB

/// Adds `bitrate_kbps` to the `files` table. Populated by the indexer
/// (LibraryScanner + ImportCoordinator) via `readAudioTags`; backfilled
/// for existing rows on the next scan pass.
///
/// Used by `DuplicateKeeperPicker` to rank perceptual duplicate
/// groups — files in different formats at different qualities
/// of the same recording get ordered by encoding quality before
/// other tiebreakers (mtime, bucket-match, path). Nullable because
/// some formats (or unreadable files) report no bitrate.
enum AddBitrateToFilesMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("004_add_bitrate_to_files") { db in
            try db.alter(table: "files") { table in
                table.add(column: "bitrate_kbps", .integer)
            }
        }
    }
}
