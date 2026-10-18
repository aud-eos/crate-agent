import GRDB

/// Keys every checkpoint row by the generation that published it, so a new
/// checkpoint can be staged beside the current one in short transactions and
/// made current by one small header update (#238). Existing rows become
/// generation 0, which the existing header already names.
enum AddSyncCheckpointGenerationsMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("024_add_sync_checkpoint_generations") { database in
            try database.execute(sql: """
            ALTER TABLE sync_checkpoint ADD COLUMN generation INTEGER NOT NULL DEFAULT 0;

            CREATE TABLE sync_saved_occurrences_generations (
                generation INTEGER NOT NULL, ordinal INTEGER NOT NULL, path BLOB NOT NULL, metadata BLOB NOT NULL, normalized_path TEXT,
                PRIMARY KEY (generation, ordinal)
            );
            INSERT INTO sync_saved_occurrences_generations SELECT 0, ordinal, path, metadata, normalized_path FROM sync_saved_occurrences;
            DROP TABLE sync_saved_occurrences;
            ALTER TABLE sync_saved_occurrences_generations RENAME TO sync_saved_occurrences;
            CREATE INDEX sync_saved_normalized_path ON sync_saved_occurrences(generation, normalized_path);

            CREATE TABLE sync_file_evidence_generations (
                generation INTEGER NOT NULL, file_id INTEGER NOT NULL, payload BLOB NOT NULL,
                PRIMARY KEY (generation, file_id)
            );
            INSERT INTO sync_file_evidence_generations SELECT 0, file_id, payload FROM sync_file_evidence;
            DROP TABLE sync_file_evidence;
            ALTER TABLE sync_file_evidence_generations RENAME TO sync_file_evidence;

            CREATE TABLE sync_file_stats_generations (
                generation INTEGER NOT NULL,
                file_id INTEGER NOT NULL,
                path TEXT NOT NULL,
                volume_uuid TEXT NOT NULL,
                device INTEGER NOT NULL,
                inode INTEGER NOT NULL,
                size INTEGER NOT NULL,
                modified_seconds INTEGER NOT NULL,
                modified_nanoseconds INTEGER NOT NULL,
                changed_seconds INTEGER NOT NULL,
                changed_nanoseconds INTEGER NOT NULL,
                link_evidence BLOB,
                PRIMARY KEY (generation, file_id)
            );
            INSERT INTO sync_file_stats_generations
            SELECT 0, file_id, path, volume_uuid, device, inode, size, modified_seconds, modified_nanoseconds,
                   changed_seconds, changed_nanoseconds, link_evidence
            FROM sync_file_stats;
            DROP TABLE sync_file_stats;
            ALTER TABLE sync_file_stats_generations RENAME TO sync_file_stats;
            """)
        }
    }
}
