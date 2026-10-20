import GRDB

/// The files the user marked as keepers. A mark protects every encoding of
/// the file's recording while `marked_revision` is at least the file's last
/// projection invalidation, so replaced content or retirement drops it.
/// Written only through `applyMutation` (`TrackMutation.keeper`).
enum AddKeeperMarksMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("032_add_keeper_marks") { database in
            try database.execute(sql: """
            CREATE TABLE keeper_marks (
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                marked_revision INTEGER NOT NULL,
                marked_at INTEGER NOT NULL
            )
            """)
        }
    }
}
