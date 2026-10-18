import GRDB

/// Records the MusicBrainz work a matched recording performs, so Find
/// Versions can group recordings of one song whose titles differ (#262).
/// Nullable: unmatched recordings, and recordings MusicBrainz relates to no
/// work, have none. `tracks.work_id` is the local song family, not this.
enum AddMusicBrainzWorkMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("027_add_musicbrainz_work") { database in
            try database.alter(table: "tracks") { table in
                table.add(column: "musicbrainz_work_id", .text)
            }
        }
    }
}
