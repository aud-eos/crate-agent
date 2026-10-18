import GRDB

/// Caches each file's full-content digest (byte-level duplicates) and
/// decoded-audio digest (perceptual duplicates). Each row records the size,
/// mtime and inode of the `files` row plus the nanosecond mtime and ctime it
/// was computed from; a row whose basis no longer matches its file is stale
/// and never confirms a duplicate. `retryable` marks a transient failure
/// that the next check retries.
enum AddFileDigestsMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("021_add_file_digests") { database in
            try database.execute(sql: """
            CREATE TABLE file_content_digests (
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                file_size INTEGER NOT NULL,
                mtime INTEGER NOT NULL,
                inode INTEGER NOT NULL,
                modified_nanoseconds INTEGER NOT NULL,
                changed_seconds INTEGER NOT NULL,
                changed_nanoseconds INTEGER NOT NULL,
                content_sha256 BLOB,
                failure TEXT,
                retryable INTEGER NOT NULL DEFAULT 0,
                CHECK ((failure IS NULL) = (content_sha256 IS NOT NULL))
            );
            CREATE TABLE file_audio_digests (
                file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                file_size INTEGER NOT NULL,
                mtime INTEGER NOT NULL,
                inode INTEGER NOT NULL,
                modified_nanoseconds INTEGER NOT NULL,
                changed_seconds INTEGER NOT NULL,
                changed_nanoseconds INTEGER NOT NULL,
                format TEXT,
                pcm_sha256 BLOB,
                full_fingerprint_sha256 BLOB,
                duration_seconds REAL,
                failure TEXT,
                retryable INTEGER NOT NULL DEFAULT 0,
                CHECK ((failure IS NULL) = (format IS NOT NULL AND pcm_sha256 IS NOT NULL
                    AND full_fingerprint_sha256 IS NOT NULL AND duration_seconds IS NOT NULL))
            );
            """)
        }
    }
}
