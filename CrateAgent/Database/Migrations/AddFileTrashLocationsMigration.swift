import GRDB

enum AddFileTrashLocationsMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("014_add_file_trash_locations") { database in
            try database.execute(sql: """
            CREATE TABLE file_trash_locations (
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                path TEXT NOT NULL,
                identity BLOB NOT NULL
            );
            CREATE INDEX file_trash_locations_path ON file_trash_locations(path);
            """)
        }
    }
}
