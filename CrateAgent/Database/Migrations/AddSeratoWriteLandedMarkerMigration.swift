import GRDB

enum AddSeratoWriteLandedMarkerMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("016_add_serato_write_landed_marker") { database in
            try database.execute(sql: """
            ALTER TABLE serato_write_queue ADD COLUMN may_have_landed INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE serato_write_queue ADD COLUMN io_started INTEGER NOT NULL DEFAULT 0;
            """)
            // The new column's initial value: before the marker, a row attempted
            // without a recorded error was read as possibly landed.
            try database.execute(sql: "UPDATE serato_write_queue SET may_have_landed = 1 WHERE attempts > 0 AND last_error IS NULL")
        }
    }
}
