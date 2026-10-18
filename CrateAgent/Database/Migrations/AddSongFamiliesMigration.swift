import GRDB

enum AddSongFamiliesMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("017_add_song_families") { database in
            try database.alter(table: "works") { table in
                table.add(column: "representative_track_id", .integer).references("tracks", onDelete: .setNull)
            }
            try database.create(index: "tracks_work_id", on: "tracks", columns: ["work_id"])
        }
    }
}
