import GRDB

/// Adds the subsecond part of each file's modification time (nanoseconds, 0..<1_000_000_000)
/// and the inode its stored fingerprint was computed from. Schema only: existing rows keep
/// NULL, which means "unknown", never zero. Seconds are not reinterpreted.
enum AddSubsecondFileIdentityMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("018_add_subsecond_file_identity") { database in
            try database.alter(table: "files") { table in
                table.add(column: "mtime_nanoseconds", .integer)
                table.add(column: "fingerprinted_mtime_nanoseconds", .integer)
                table.add(column: "fingerprinted_inode", .integer)
            }
        }
    }
}
