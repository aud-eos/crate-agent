import GRDB

/// Caches each file's decoded-audio digest for the size, mtime and inode it
/// was computed from. A row whose basis no longer matches its file is stale
/// and is recomputed; it never confirms duplicate audio.
enum AddFileAudioDigestsMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("021_add_file_audio_digests") { database in
            try database.execute(sql: """
            CREATE TABLE file_audio_digests (
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                file_size INTEGER NOT NULL,
                mtime INTEGER NOT NULL,
                inode INTEGER NOT NULL,
                format TEXT,
                pcm_sha256 BLOB,
                full_fingerprint_sha256 BLOB,
                duration_seconds REAL,
                failure TEXT,
                CHECK ((failure IS NULL) = (format IS NOT NULL AND pcm_sha256 IS NOT NULL
                    AND full_fingerprint_sha256 IS NOT NULL AND duration_seconds IS NOT NULL))
            )
            """)
        }
    }
}
