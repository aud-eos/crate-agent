import GRDB

/// Keeps what a landed removal took out of each Serato store, and where its
/// audio went in Trash, so History can undo the removal exactly. Trash
/// destinations are keyed by the `.fileTrashed` event because the file row
/// they describe is deleted by the same cleanup.
enum AddSeratoRemovalCapturesMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("029_add_serato_removal_captures") { database in
            try database.execute(sql: """
            CREATE TABLE serato_removal_captures (
                event_id INTEGER NOT NULL,
                store_path BLOB NOT NULL,
                track_path BLOB NOT NULL,
                records BLOB NOT NULL,
                outcome TEXT NOT NULL,
                captured_at INTEGER NOT NULL,
                PRIMARY KEY (event_id, store_path)
            );
            CREATE TABLE removal_trash_destinations (
                event_id INTEGER PRIMARY KEY,
                original_path BLOB NOT NULL,
                trash_identity BLOB NOT NULL
            );
            """)
        }
    }
}
