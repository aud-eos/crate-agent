import GRDB

/// Gives a file a recording identity of its own while its current 120 s
/// fingerprint hash is still `fingerprint_sha256` (#205). Its `tracks` key is
/// then the SHA-256 of that hash followed by `discriminator`
/// (`RecordingIdentity.key`). `source` says why: a differing full-length
/// fingerprint, or the user grouping files as different recordings. A row
/// whose hash no longer matches the file's fingerprint has no effect.
enum AddRecordingDiscriminatorsMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("026_add_recording_discriminators") { database in
            try database.execute(sql: """
            CREATE TABLE recording_discriminators (
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                fingerprint_sha256 BLOB NOT NULL CHECK (length(fingerprint_sha256) = 32),
                discriminator BLOB NOT NULL,
                source TEXT NOT NULL CHECK (source IN ('full_fingerprint', 'grouping'))
            )
            """)
        }
    }
}
