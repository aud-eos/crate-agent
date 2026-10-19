import GRDB

/// Cue point and beatgrid marker counts read from each file's Serato tags,
/// kept by `SeratoAnalysisWorker` against the file basis they were read
/// from. A derived cache, never written through `applyMutation`.
enum AddSeratoAnalysisMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("031_add_serato_analysis") { database in
            try database.execute(sql: """
            CREATE TABLE file_serato_analysis (
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                file_size INTEGER NOT NULL,
                mtime INTEGER NOT NULL,
                inode INTEGER NOT NULL,
                modified_nanoseconds INTEGER NOT NULL,
                changed_seconds INTEGER NOT NULL,
                changed_nanoseconds INTEGER NOT NULL,
                cue_count INTEGER,
                beatgrid_marker_count INTEGER,
                failure TEXT,
                CHECK ((failure IS NULL) = (cue_count IS NOT NULL))
            );
            """)
        }
    }
}
