import Foundation
import GRDB

actor SyncCheckpointStore {
    private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
    }

    func currentRevision() async throws -> Int64 {
        try await database.writer.read { connection in try Self.revision(in: connection) }
    }

    static func revision(in connection: Database) throws -> Int64 {
        try Int64.fetchOne(connection, sql: "SELECT revision FROM sync_revision WHERE id = 1") ?? 0
    }

    func dirtyFiles() async throws -> SyncDirtyFiles {
        try await database.writer.read { connection in
            let rows = try Row.fetchAll(connection, sql: "SELECT file_id, path FROM sync_dirty_files")
            return SyncDirtyFiles(fileIDs: Set(rows.map { row in row["file_id"] }), paths: Set(rows.map { row in row["path"] }))
        }
    }

    func pendingEffects() async throws -> [String] {
        try await database.writer.read { connection in
            try String.fetchAll(connection, sql: "SELECT batch_id FROM sync_effect_fences ORDER BY batch_id")
        }
    }

    func beginEffect(batchID: String) async throws {
        try await database.writer.write { connection in try Self.beginEffect(batchID: batchID, in: connection) }
    }

    func finishEffect(batchID: String) async throws {
        try await database.writer.write { connection in try Self.finishEffect(batchID: batchID, in: connection) }
    }

    static func beginEffect(batchID: String, in connection: Database) throws {
        try connection.execute(sql: "INSERT OR IGNORE INTO sync_effect_fences (batch_id) VALUES (?)", arguments: [batchID])
        if connection.changesCount > 0 {
            try connection.execute(sql: "INSERT INTO sync_revision (id, revision) VALUES (1, 1) ON CONFLICT(id) DO UPDATE SET revision = revision + 1")
        }
    }

    static func finishEffect(batchID: String, in connection: Database) throws {
        try connection.execute(sql: "DELETE FROM sync_effect_fences WHERE batch_id = ?", arguments: [batchID])
    }

    static func eventFence(_ eventID: Int64) -> String {
        "event:\(eventID)"
    }

    func loadHeader() async throws -> SyncCheckpointHeader? {
        try await database.writer.read { connection in try Self.header(in: connection) }
    }

    private static func header(in connection: Database) throws -> SyncCheckpointHeader? {
        guard let row = try Row.fetchOne(connection, sql: "SELECT version, payload FROM sync_checkpoint WHERE id = 1") else { return nil }
        let version: Int = row["version"]
        guard version <= SyncCheckpointHeader.currentVersion else { throw SyncCheckpointError.malformed }
        guard version == SyncCheckpointHeader.currentVersion else { return nil }
        let bytes: Data = row["payload"]
        let header = try decode(SyncCheckpointHeader.self, from: bytes)
        guard header.formatVersion == version, header.localRevision >= 0,
              !header.libraryID.isEmpty, Set(header.watchRoots).count == header.watchRoots.count else { throw SyncCheckpointError.malformed }
        return header
    }

    private static func decode<Value: Codable>(_ type: Value.Type, from bytes: Data) throws -> Value {
        let value = try JSONDecoder().decode(type, from: bytes)
        let original = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary
        let canonical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary
        guard let original, let canonical, original.isEqual(canonical) else {
            throw SyncCheckpointError.malformed
        }
        return value
    }

    func load() async throws -> LibrarySyncCheckpoint? {
        try await database.writer.read { connection in
            guard let header = try Self.header(in: connection) else { return nil }
            let records = try Row.fetchAll(connection, sql: "SELECT ordinal, path, metadata FROM sync_saved_occurrences ORDER BY ordinal").enumerated().map { index, row in
                let ordinal: Int = row["ordinal"]
                guard ordinal == index else { throw SyncCheckpointError.malformed }
                let bytes: Data = row["metadata"]
                let record = try SavedSeratoOccurrence(pathBytes: row["path"], metadata: Self.decode(SeratoMetadata.self, from: bytes))
                _ = try record.record()
                return record
            }
            let files = try Row.fetchAll(connection, sql: "SELECT file_id, payload FROM sync_file_evidence ORDER BY file_id").map { row in
                let bytes: Data = row["payload"]
                let evidence = try Self.decode(SyncFileEvidence.self, from: bytes)
                let fileID: Int64 = row["file_id"]
                guard fileID == evidence.fileID else { throw SyncCheckpointError.malformed }
                return evidence
            }
            return LibrarySyncCheckpoint(header: header, records: records, files: files)
        }
    }

    func publish(_ checkpoint: LibrarySyncCheckpoint, expectedRevision: Int64) async throws {
        let encoder = JSONEncoder()
        let headerBytes = try encoder.encode(checkpoint.header)
        let records = try checkpoint.records.map { record in try (record.pathBytes, encoder.encode(record.metadata)) }
        let files = try checkpoint.files.map { file in try (file.fileID, encoder.encode(file)) }
        try await database.writer.write { connection in
            guard try !Bool.fetchOne(connection, sql: "SELECT EXISTS(SELECT 1 FROM sync_effect_fences)")! else {
                throw SyncCheckpointError.incompleteEffects
            }
            guard try Self.revision(in: connection) == expectedRevision, checkpoint.header.localRevision == expectedRevision else {
                throw SyncCheckpointError.changed
            }
            guard checkpoint.header.formatVersion == SyncCheckpointHeader.currentVersion,
                  checkpoint.header.complete else { throw SyncCheckpointError.malformed }
            try connection.execute(sql: "DELETE FROM sync_saved_occurrences; DELETE FROM sync_file_evidence")
            for (index, record) in records.enumerated() {
                try connection.execute(sql: "INSERT INTO sync_saved_occurrences (ordinal, path, metadata) VALUES (?, ?, ?)", arguments: [index, record.0, record.1])
            }
            for file in files {
                try connection.execute(sql: "INSERT INTO sync_file_evidence (file_id, payload) VALUES (?, ?)", arguments: [file.0, file.1])
            }
            try connection.execute(sql: "INSERT OR REPLACE INTO sync_checkpoint (id, version, payload) VALUES (1, ?, ?)", arguments: [SyncCheckpointHeader.currentVersion, headerBytes])
            try connection.execute(sql: "DELETE FROM sync_dirty_files")
        }
    }
}
