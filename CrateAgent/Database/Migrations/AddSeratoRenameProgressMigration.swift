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
            """)
        }
    }
}
