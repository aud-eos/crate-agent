import Foundation
import GRDB

actor SyncCheckpointStore {
    let database: LibraryDatabase

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

    /// Whether an active, available row was indexed before subsecond times were kept. Only a
    /// planned sync records that time, so such a row keeps sync off the unchanged fast path.
    /// Whether a row the reconciler can record for `libraryID` still lacks its subsecond
    /// time. Rows of another Serato library are never reconciled here, so they must not
    /// keep the fast path closed.
    func hasRowsAwaitingSubsecondTime(libraryID: String) async throws -> Bool {
        try await database.writer.read { connection in
            try Bool.fetchOne(connection, sql: """
            SELECT EXISTS(SELECT 1 FROM files WHERE mtime_nanoseconds IS NULL
                          AND library_membership = 'active' AND file_availability = 'available'
                          AND (serato_library_id IS NULL OR serato_library_id = ?))
            """, arguments: [libraryID]) ?? false
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

    /// Pre-queue builds fenced each journaled event's external effects; only
    /// `recoverLegacyEffectFences` still reads these.
    static let legacyEventFencePrefix = "event:"

    /// Physical-move and legacy fences and queued effects must all be finished
    /// before a checkpoint can claim the library is complete. A cleanup intent
    /// between steps owns no row and does not block: it forces the next
    /// startup onto the strict path, which advances it.
    private static func requireNoUnfinishedEffects(allowedQueueIDs: Set<Int64>, in connection: Database) throws {
        guard try !Bool.fetchOne(connection, sql: "SELECT EXISTS(SELECT 1 FROM sync_effect_fences)")! else {
            throw SyncCheckpointError.incompleteEffects
        }
        let queued = try Set(Int64.fetchAll(connection, sql: "SELECT queue_id FROM serato_write_queue"))
        guard queued.isSubset(of: allowedQueueIDs) else { throw SyncCheckpointError.queuedChangesPending }
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
        let header = try decodeCanonical(SyncCheckpointHeader.self, from: bytes)
        guard header.formatVersion == version, header.localRevision >= 0,
              !header.libraryID.isEmpty, Set(header.watchRoots).count == header.watchRoots.count else { throw SyncCheckpointError.malformed }
        return header
    }

    static func decodeCanonical<Value: Codable>(_ type: Value.Type, from bytes: Data) throws -> Value {
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
                let record = try SavedSeratoOccurrence(pathBytes: row["path"], metadata: Self.decodeCanonical(SeratoMetadata.self, from: bytes))
                _ = try record.record()
                return record
            }
            let files = try Row.fetchAll(connection, sql: "SELECT file_id, payload FROM sync_file_evidence ORDER BY file_id").map { row in
                let bytes: Data = row["payload"]
                let evidence = try Self.decodeCanonical(SyncFileEvidence.self, from: bytes)
                let fileID: Int64 = row["file_id"]
                guard fileID == evidence.fileID else { throw SyncCheckpointError.malformed }
                return evidence
            }
            return LibrarySyncCheckpoint(header: header, records: records, files: files)
        }
    }

    func publish(_ checkpoint: LibrarySyncCheckpoint, expectedRevision: Int64,
                 sourceAuthorization: SeratoSnapshotAuthorization? = nil, ready: LibrarySyncReadiness.Authorization? = nil) async throws
    {
        let encoder = JSONEncoder()
        let headerBytes = try encoder.encode(checkpoint.header)
        let records = try checkpoint.records.map { record in try (record.pathBytes, encoder.encode(record.metadata)) }
        let files = try checkpoint.files.map { file in try (file.fileID, encoder.encode(file)) }
        try await database.writer.writeWithoutTransaction { connection in
            try connection.inTransaction {
                try sourceAuthorization?.check()
                try Self.requireNoUnfinishedEffects(allowedQueueIDs: [], in: connection)
                guard try Self.revision(in: connection) == expectedRevision, checkpoint.header.localRevision == expectedRevision else {
                    throw SyncCheckpointError.changed
                }
                guard checkpoint.header.formatVersion == SyncCheckpointHeader.currentVersion,
                      checkpoint.header.complete else { throw SyncCheckpointError.malformed }
                try connection.execute(sql: "DELETE FROM sync_saved_occurrences; DELETE FROM sync_file_evidence; DELETE FROM sync_file_stats")
                for (index, record) in records.enumerated() {
                    try connection.execute(sql: "INSERT INTO sync_saved_occurrences (ordinal, path, metadata, normalized_path) VALUES (?, ?, ?, ?)", arguments: [index, record.0, record.1, String(data: record.0, encoding: .utf8).map(SeratoPath.normalized)])
                }
                for file in files {
                    try connection.execute(sql: "INSERT INTO sync_file_evidence (file_id, payload) VALUES (?, ?)", arguments: [file.0, file.1])
                }
                for file in checkpoint.files {
                    try Self.saveStatEvidence(file, in: connection)
                }
                try connection.execute(sql: "INSERT OR REPLACE INTO sync_checkpoint (id, version, payload) VALUES (1, ?, ?)", arguments: [SyncCheckpointHeader.currentVersion, headerBytes])
                try connection.execute(sql: "DELETE FROM sync_dirty_files")
                try sourceAuthorization?.check()
                try Task.checkCancellation()
                return .commit
            }
            do {
                try sourceAuthorization?.check()
                try Task.checkCancellation()
                if let ready {
                    try ready.gate.markReady(ready)
                }
            } catch {
                try connection.execute(sql: "DELETE FROM sync_checkpoint")
                throw error
            }
        }
    }

    func authorizeReady(expectedRevision: Int64, source: SeratoSnapshotAuthorization, ready: LibrarySyncReadiness.Authorization,
                        allowedQueueIDs: Set<Int64> = []) async throws
    {
        try await database.writer.writeWithoutTransaction { connection in
            guard try Self.revision(in: connection) == expectedRevision else { throw SyncCheckpointError.changed }
            try Self.requireNoUnfinishedEffects(allowedQueueIDs: allowedQueueIDs, in: connection)
            try source.check()
            try Task.checkCancellation()
            try ready.gate.markReady(ready)
        }
    }

    /// The checkpoint's saved occurrence for a file whose evidence still matches
    /// its revision and identity. The current V2 source may differ: own writes
    /// and strict observations after publication are kept in
    /// `serato_external_baselines`, which callers consult first.
    static func checkpointBaseline(token: FileMembershipToken, identity: FileMetadata, locator: SeratoLibraryLocator,
                                   in connection: Database) throws -> SeratoMetadata?
    {
        guard let header = try header(in: connection), header.complete,
              let bytes = try Data.fetchOne(connection, sql: "SELECT payload FROM sync_file_evidence WHERE file_id = ?", arguments: [token.fileId])
        else { return nil }
        let libraryID: String
        // An unidentifiable library cannot vouch for this checkpoint; the baseline stays unknown, which observation reports as uncertain.
        do { libraryID = try locator.supportedLibraryIdentity() } catch { return nil }
        guard libraryID == header.libraryID else { return nil }
        let evidence = try decodeCanonical(SyncFileEvidence.self, from: bytes)
        guard evidence.membershipRevision == token.revision, evidence.identity == identity else { return nil }
        let metadata = try Data.fetchAll(connection, sql: "SELECT metadata FROM sync_saved_occurrences WHERE normalized_path = ?", arguments: [SeratoPath.normalized(identity.path)])
        guard metadata.count == 1 else { return nil }
        return try decodeCanonical(SeratoMetadata.self, from: metadata[0])
    }
}
