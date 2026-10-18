import GRDB

enum AddSeratoWriteResolutionsMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("023_add_serato_write_resolutions") { database in
            try database.execute(sql: """
            CREATE INDEX serato_write_dispositions_batch ON serato_write_dispositions(batch_id, event_id);
            CREATE TABLE serato_write_resolutions (
                event_id INTEGER NOT NULL,
                kind TEXT NOT NULL,
                disposition_id INTEGER NOT NULL,
                resolved_at INTEGER NOT NULL,
                PRIMARY KEY (event_id, kind)
            );
            """)
        }
    }
}
