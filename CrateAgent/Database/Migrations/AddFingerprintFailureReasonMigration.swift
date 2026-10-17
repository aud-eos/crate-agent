import GRDB

enum AddFingerprintFailureReasonMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("015_add_fingerprint_failure_reason") { database in
            try database.execute(sql: "ALTER TABLE files ADD COLUMN fingerprint_failure TEXT")
        }
    }
}
