import GRDB

/// Records each same-audio duplicate group whose disagreeing version labels
/// the user chose to keep. `signature` digests the members' file ids and
/// their content or decoded-audio digests, so a changed or added copy no
/// longer matches and the disagreement is shown again.
enum AddDuplicateLabelReviewsMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("022_add_duplicate_label_reviews") { database in
            try database.execute(sql: """
            CREATE TABLE duplicate_label_reviews (
                signature TEXT PRIMARY KEY NOT NULL CHECK (length(signature) = 64),
                kept_at INTEGER NOT NULL
            )
            """)
        }
    }
}
