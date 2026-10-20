import GRDB

/// Derived caches the per-file checklist reads: Serato's V2 facts and
/// Subcrates membership (kept by `SeratoLibraryFactsService`), and duplicate
/// membership. None is written through `applyMutation`; each is rebuilt from
/// its source. `checklist_source_stamps` records what each source looked
/// like when it was last read in full.
enum AddChecklistFactsMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("030_add_checklist_facts") { database in
            try database.execute(sql: """
            CREATE TABLE serato_track_facts (
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                beatgrid_locked INTEGER,
                added_at INTEGER,
                added_source TEXT NOT NULL CHECK (added_source IN ('serato', 'indexed'))
            );
            CREATE TABLE serato_crate_memberships (
                file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                crate_name TEXT NOT NULL,
                PRIMARY KEY (file_id, crate_name)
            ) WITHOUT ROWID;
            CREATE TABLE checklist_source_stamps (
                source TEXT PRIMARY KEY,
                stamp TEXT NOT NULL
            );
            CREATE TABLE checklist_duplicate_members (
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                group_key TEXT NOT NULL
            );
            """)
        }
    }
}
