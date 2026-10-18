import GRDB

/// Mirrors Serato's `ttyr` year text into `files.serato_year` (#95), and
/// makes a change to it mark the file dirty for sync like the other
/// mirrored fields. Rows fill in on the next full sync.
enum AddSeratoYearToFilesMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("019_add_serato_year_to_files") { database in
            try database.alter(table: "files") { table in
                table.add(column: "serato_year", .text)
            }
            let columns = ["path", "volume_uuid", "inode", "file_size", "mtime", "lightweight_hash", "track_id", "bitrate_kbps",
                           "library_membership", "file_availability", "serato_library_id", "retired_at", "membership_revision",
                           "last_projection_invalidation_revision", "artist", "title", "album", "genre", "bpm", "musical_key", "comment", "length", "label",
                           "serato_year"]
            let changed = columns.map { column in "OLD.\(column) IS NOT NEW.\(column)" }.joined(separator: " OR ")
            try database.execute(sql: """
            DROP TRIGGER sync_files_update;
            CREATE TRIGGER sync_files_update AFTER UPDATE ON files WHEN \(changed)
            BEGIN
              INSERT INTO sync_revision (id, revision) VALUES (1, 1)
                ON CONFLICT(id) DO UPDATE SET revision = revision + 1;
              INSERT OR IGNORE INTO sync_dirty_files (file_id, path) VALUES (OLD.id, CAST(OLD.path AS BLOB));
              INSERT OR IGNORE INTO sync_dirty_files (file_id, path) VALUES (NEW.id, CAST(NEW.path AS BLOB));
            END;
            """)
        }
    }
}
