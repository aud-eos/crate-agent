import GRDB

/// Derived cache of plays from Serato History, rebuilt wholesale by
/// `SeratoPlayCountService`; never written through `applyMutation`.
enum AddSeratoPlayCountsMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("022_add_serato_play_counts") { database in
            try database.execute(sql: """
            CREATE TABLE serato_play_counts (
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                play_count INTEGER NOT NULL CHECK (play_count > 0),
                last_played_at INTEGER NOT NULL
            );
            """)
        }
    }
}
