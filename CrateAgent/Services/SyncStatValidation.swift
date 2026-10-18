import Darwin
import Foundation
import GRDB

struct SyncStatValidation: Sendable {
    let validatedFileIDs: Set<Int64>
    let changedFileIDs: Set<Int64>
}

enum AddSyncStatProjectionMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("012_add_sync_stat_projection") { database in
            try database.execute(sql: """
            CREATE TABLE sync_file_stats (
                file_id INTEGER PRIMARY KEY,
                path TEXT NOT NULL,
                volume_uuid TEXT NOT NULL,
                device INTEGER NOT NULL,
                inode INTEGER NOT NULL,
                size INTEGER NOT NULL,
                modified_seconds INTEGER NOT NULL,
                modified_nanoseconds INTEGER NOT NULL,
                changed_seconds INTEGER NOT NULL,
                changed_nanoseconds INTEGER NOT NULL,
                link_evidence BLOB
            );
            ALTER TABLE sync_saved_occurrences ADD COLUMN normalized_path TEXT;
            CREATE INDEX sync_saved_normalized_path ON sync_saved_occurrences(normalized_path);
            """)
        }
    }
}

extension SyncCheckpointStore {
    func validateFileStats(expectedRevision: Int64) async throws -> SyncStatValidation {
        let metrics = LibrarySyncMetrics.current
        return try await database.writer.read { connection in
            guard try Self.revision(in: connection) == expectedRevision else { throw SyncCheckpointError.changed }
            var validated: Set<Int64> = []
            var changed: Set<Int64> = []
            var volumes: [Int32: String] = [:]
            let cursor = try Row.fetchCursor(connection, sql: """
            SELECT files.id, files.path AS current_path, evidence.*
            FROM files LEFT JOIN sync_file_stats evidence ON evidence.file_id = files.id
              AND evidence.generation = (SELECT generation FROM sync_checkpoint WHERE id = 1)
            """)
            while let row = try cursor.next() {
                try Task.checkCancellation()
                let identifier: Int64 = row["id"]
                let path: String = row["current_path"]
                guard let savedPath: String = row["path"], path == savedPath else {
                    changed.insert(identifier)
                    continue
                }
                var metadata = stat()
                metrics?.record(.stat)
                guard lstat(path, &metadata) == 0,
                      metadata.st_dev == row["device"], metadata.st_ino == row["inode"],
                      metadata.st_size == row["size"],
                      metadata.st_mtimespec.tv_sec == row["modified_seconds"],
                      metadata.st_mtimespec.tv_nsec == row["modified_nanoseconds"],
                      metadata.st_ctimespec.tv_sec == row["changed_seconds"],
                      metadata.st_ctimespec.tv_nsec == row["changed_nanoseconds"]
                else {
                    changed.insert(identifier)
                    continue
                }
                let link: Data? = row["link_evidence"]
                let volumePath: String
                if let link {
                    let evidence = try JSONDecoder().decode(AudioFileReadIdentity.self, from: link)
                    do {
                        try evidence.requireUnchanged(at: path)
                        volumePath = evidence.resolvedPath
                        metadata.st_dev = evidence.target.device
                    } catch {
                        changed.insert(identifier)
                        continue
                    }
                } else {
                    guard metadata.st_mode & S_IFMT == S_IFREG else { changed.insert(identifier); continue }
                    volumePath = path
                }
                let volume: String
                if let cached = volumes[metadata.st_dev] {
                    volume = cached
                } else {
                    guard let current = try URL(fileURLWithPath: volumePath).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else {
                        changed.insert(identifier)
                        continue
                    }
                    volumes[metadata.st_dev] = current
                    volume = current
                }
                guard volume == row["volume_uuid"] else { changed.insert(identifier); continue }
                validated.insert(identifier)
            }
            return SyncStatValidation(validatedFileIDs: validated, changedFileIDs: changed)
        }
    }

    static func saveStatEvidence(_ file: SyncFileEvidence, generation: Int64, in connection: Database) throws {
        guard file.bitrateProbed, let stamp = file.readIdentity else { return }
        let entry = stamp.entry
        let link = entry == stamp.target ? nil : try JSONEncoder().encode(stamp)
        try connection.execute(sql: """
        INSERT INTO sync_file_stats
        (generation, file_id, path, volume_uuid, device, inode, size, modified_seconds, modified_nanoseconds, changed_seconds, changed_nanoseconds, link_evidence)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [generation, file.fileID, file.identity.path, file.identity.volumeUuid, entry.device, entry.inode, entry.size,
                         entry.modifiedSeconds, entry.modifiedNanoseconds, entry.changedSeconds, entry.changedNanoseconds, link])
    }
}
