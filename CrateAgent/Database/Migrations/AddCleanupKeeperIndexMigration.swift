import GRDB

/// Lets "is this file the keeper of a pending removal?" run as an indexed
/// predicate instead of decoding every intent payload (#272). The column is
/// written beside the payload; existing rows are backfilled from it.
enum AddCleanupKeeperIndexMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("033_add_cleanup_keeper_index") { database in
            try database.execute(sql: """
            ALTER TABLE duplicate_cleanup_intents ADD COLUMN keeper_file_id INTEGER;
            UPDATE duplicate_cleanup_intents
               SET keeper_file_id = json_extract(CAST(payload AS TEXT), '$.keeper.token.fileId');
            CREATE INDEX duplicate_cleanup_intents_keeper ON duplicate_cleanup_intents(keeper_file_id);
            """)
        }
    }
}
