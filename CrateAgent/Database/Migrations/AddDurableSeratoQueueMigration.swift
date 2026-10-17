import GRDB

enum AddDurableSeratoQueueMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("013_add_durable_serato_queue") { database in
            try database.execute(sql: """
            CREATE TABLE serato_write_queue (
                queue_id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id INTEGER NOT NULL,
                kind TEXT NOT NULL,
                file_id INTEGER NOT NULL,
                membership_revision INTEGER NOT NULL,
                payload BLOB NOT NULL,
                cleanup_target_file_id INTEGER,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_attempt_at INTEGER,
                last_error TEXT,
                created_at INTEGER NOT NULL,
                UNIQUE (event_id, kind)
            );
            CREATE INDEX serato_write_queue_file ON serato_write_queue(file_id);
            CREATE INDEX serato_write_queue_cleanup ON serato_write_queue(cleanup_target_file_id);
            CREATE TABLE duplicate_cleanup_intents (
                target_file_id INTEGER PRIMARY KEY,
                payload BLOB NOT NULL,
                step INTEGER NOT NULL,
                waiting_event_id INTEGER,
                removed_v2 INTEGER NOT NULL DEFAULT 0,
                failure TEXT
            );
            CREATE TABLE serato_external_baselines (
                file_id INTEGER PRIMARY KEY,
                membership_revision INTEGER NOT NULL,
                metadata BLOB NOT NULL
            );
            CREATE TABLE serato_write_dispositions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id INTEGER NOT NULL,
                batch_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                disposition TEXT NOT NULL,
                detail TEXT,
                created_at INTEGER NOT NULL,
                reported INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX serato_write_dispositions_unreported ON serato_write_dispositions(reported);
            CREATE TRIGGER serato_write_queue_insert AFTER INSERT ON serato_write_queue
            BEGIN
              INSERT INTO sync_revision (id, revision) VALUES (1, 1)
                ON CONFLICT(id) DO UPDATE SET revision = revision + 1;
            END;
            """)
        }
    }
}
