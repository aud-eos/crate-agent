import GRDB

enum AddSyncCheckpointMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("011_add_sync_checkpoint") { database in
            try database.execute(sql: """
            CREATE TABLE sync_revision (id INTEGER PRIMARY KEY CHECK (id = 1), revision INTEGER NOT NULL);
            CREATE TABLE sync_checkpoint (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE sync_saved_occurrences (ordinal INTEGER PRIMARY KEY, path BLOB NOT NULL, metadata BLOB NOT NULL);
            CREATE TABLE sync_file_evidence (file_id INTEGER PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE sync_dirty_files (file_id INTEGER NOT NULL, path BLOB NOT NULL, PRIMARY KEY (file_id, path));
            CREATE TABLE sync_effect_fences (batch_id TEXT PRIMARY KEY NOT NULL);
            """)
            let columns = ["path", "volume_uuid", "inode", "file_size", "mtime", "lightweight_hash", "track_id", "bitrate_kbps",
                           "library_membership", "file_availability", "serato_library_id", "retired_at", "membership_revision",
                           "last_projection_invalidation_revision", "artist", "title", "album", "genre", "bpm", "musical_key", "comment", "length", "label"]
            let changed = columns.map { column in "OLD.\(column) IS NOT NEW.\(column)" }.joined(separator: " OR ")
            for (action, references, predicate) in [("INSERT", ["NEW"], ""), ("DELETE", ["OLD"], ""), ("UPDATE", ["OLD", "NEW"], "WHEN \(changed)")] {
                let paths = references.map { reference in
                    "INSERT OR IGNORE INTO sync_dirty_files (file_id, path) VALUES (\(reference).id, CAST(\(reference).path AS BLOB));"
                }.joined(separator: "\n")
                try database.execute(sql: """
                CREATE TRIGGER sync_files_\(action.lowercased()) AFTER \(action) ON files \(predicate)
                BEGIN
                  INSERT INTO sync_revision (id, revision) VALUES (1, 1)
                    ON CONFLICT(id) DO UPDATE SET revision = revision + 1;
                  \(paths)
                END;
                """)
            }
        }
    }
}
