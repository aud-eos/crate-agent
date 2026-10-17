import GRDB

enum AddSeratoWriteLandedMarkerMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("014_add_serato_write_landed_marker") { database in
            try database.execute(sql: "ALTER TABLE serato_write_queue ADD COLUMN may_have_landed INTEGER NOT NULL DEFAULT 0")
        }
    }
}
