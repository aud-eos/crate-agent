import GRDB

/// Popularity is derived observation data keyed by the checklist's recording
/// key (MusicBrainz recording ID, else the track, else the file). Lookups keep
/// each source's raw value over time so Hot can be growth; scores are the
/// derived summary the Library joins. Written only by `PopularityStore`.
enum AddPopularityMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("034_add_popularity") { database in
            try database.execute(sql: """
            CREATE TABLE popularity_lookups (
                recording_key TEXT NOT NULL,
                source TEXT NOT NULL,
                observed_at INTEGER NOT NULL,
                value REAL NOT NULL,
                PRIMARY KEY (recording_key, source, observed_at)
            ) WITHOUT ROWID;
            CREATE TABLE popularity_scores (
                recording_key TEXT PRIMARY KEY,
                all_time REAL,
                hot REAL,
                detail TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE INDEX popularity_scores_updated ON popularity_scores(updated_at);
            """)
        }
    }
}
