import GRDB

enum AddFileLibraryStateMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("010_add_file_library_state") { database in
            try database.alter(table: "files") { table in
                table.add(column: "library_membership", .text).notNull().defaults(to: LibraryMembership.legacyUnverified.rawValue)
                table.add(column: "file_availability", .text).notNull().defaults(to: FileAvailability.unknown.rawValue)
                table.add(column: "serato_library_id", .text)
                table.add(column: "retired_at", .integer)
                table.add(column: "membership_revision", .integer).notNull().defaults(to: 0)
            }
        }
    }
}
