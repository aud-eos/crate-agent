import GRDB

enum AddSeratoRenameProgressMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("020_add_serato_rename_progress") { database in
            try database.execute(sql: """
            CREATE TABLE serato_rename_progress (
                queue_id INTEGER NOT NULL REFERENCES serato_write_queue(queue_id) ON DELETE CASCADE,
                store TEXT NOT NULL,
                matched INTEGER NOT NULL,
                PRIMARY KEY (queue_id, store)
            );
            ALTER TABLE serato_write_queue ADD COLUMN rename_new_path_key TEXT;
            CREATE INDEX serato_write_queue_rename_arrivals ON serato_write_queue(rename_new_path_key, queue_id);
            ALTER TABLE serato_write_dispositions ADD COLUMN new_path_held INTEGER NOT NULL DEFAULT 0;
            CREATE INDEX serato_write_dispositions_event ON serato_write_dispositions(event_id, kind);
            """)
        }
    }
}
