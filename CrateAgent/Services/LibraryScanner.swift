import Foundation
import GRDB
import os.log

/// Mirrors Serato's library into crate-agent's local DB.
///
/// Reads `database V2` + every `.crate`, decodes the full per-track
/// records (path + artist/title/album/genre/bpm/key/comment/length/
/// label), then for each record:
///   • if crate-agent has no file row at that path → `indexNewFile`
///   • if crate-agent has the path but Serato's metadata differs from
///     the stored snapshot → `setMetadata`
///   • otherwise → no-op
///
/// The validated snapshot entry point works with SeratoMembershipReconciler,
/// which independently journals saved membership and retirement.
///
/// Used by AppServices on launch and by SeratoSyncCoordinator when
/// Serato quits — same operation in both contexts.
public actor LibraryScanner {
    public struct ScanProgress: Sendable, Equatable {
        public var completedFileCount: Int?
        public let seratoReferenceCount: Int
        public let filesIndexed: Int
        public let filesMetadataUpdated: Int
        public let filesSkipped: Int
        public let lastChangedPath: String?
    }

    public struct ScanResult: Sendable, Equatable {
        public var fileInfoFailures: [String] = []
        public let seratoReferenceCount: Int
        public let filesIndexed: Int
        public let filesMetadataUpdated: Int
        public let filesSkipped: Int
    }

    public typealias ProgressHandler = @Sendable (ScanProgress) -> Void

    private static let logger = Logger(
        subsystem: "com.crateagent.app",
        category: "LibraryScanner"
    )

    private let operationEngine: OperationEngine
    private let database: LibraryDatabase
    private let seratoLocator: SeratoLibraryLocator

    private let identityReader: @Sendable (String) throws -> FileMetadata
    private let bitrateReader: @Sendable (String) throws -> Int?
    private var refreshedEvidence: [Int64: SyncFileEvidence] = [:]

    public init(operationEngine: OperationEngine, database: LibraryDatabase, seratoLocator: SeratoLibraryLocator) {
        self.init(operationEngine: operationEngine, database: database, seratoLocator: seratoLocator,
                  identityReader: { path in try FileMetadataCollector.collectVerified(at: path) },
                  bitrateReader: { path in try readAudioTags(filePath: path).bitrateKbps.map(Int.init) })
    }

    init(operationEngine: OperationEngine, database: LibraryDatabase, seratoLocator: SeratoLibraryLocator,
         identityReader: @escaping @Sendable (String) throws -> FileMetadata,
         bitrateReader: @escaping @Sendable (String) throws -> Int?)
    {
        self.operationEngine = operationEngine
        self.database = database
        self.seratoLocator = seratoLocator
        self.identityReader = identityReader
        self.bitrateReader = bitrateReader
    }

    func evidenceAfterLastScan() -> [Int64: SyncFileEvidence] {
        refreshedEvidence
    }

    @discardableResult
    public func scan(progress: ProgressHandler? = nil) async throws -> ScanResult {
        Self.logger.info("Starting Serato library scan")

        let scopeAuthorization = await operationEngine.captureConflictScope()
        let seratoRecords = try await loadSeratoRecords()
        var seenPaths = Set<String>()
        for (path, _) in seratoRecords {
            guard seenPaths.insert(SeratoPath.normalized(path)).inserted else { throw SeratoPathConflictError(path: path) }
            try await operationEngine.requireUnconflicted(SeratoConflictTarget(paths: [path]))
        }
        Self.logger.info(
            "Serato references \(seratoRecords.count, privacy: .public) tracks"
        )

        let knownFilesByPath = try await loadKnownFilesByPath()

        var filesIndexed = 0
        var filesMetadataUpdated = 0
        var filesSkipped = 0
        var lastChangedPath: String?

        // Collected backfill writes — flushed in one transaction
        // after the per-file loop. The previous shape opened one
        // `database.writer.write` per backfilled field per file; a
        // first-scan over 30k files with both hash and bitrate
        // missing meant ~60k separate transactions, each with its
        // own fsync.
        var hashBackfills: [(fileId: Int64, hash: Data)] = []
        var bitrateBackfills: [(fileId: Int64, bitrate: Int)] = []

        for (absolutePath, record) in seratoRecords {
            if let existingFile = knownFilesByPath[absolutePath],
               let fileId = existingFile.id
            {
                try await operationEngine.requireUnconflicted(.file(existingFile))
                // Backfill lightweightHash for rows that pre-date the
                // cross-volume-move feature. Idempotent: skipped when
                // the hash is already present. Direct DB write rather
                // than a mutation — the hash is a derived value, not
                // a user action, so it doesn't belong in the event log.
                if existingFile.lightweightHash == nil,
                   let hash = LightweightHashCalculator.compute(forFileAt: absolutePath)
                {
                    hashBackfills.append((fileId: fileId, hash: hash))
                }

                // Same idempotent backfill for bitrate (added in
                // migration #004). Same direct-write rationale: bitrate
                // is a derived property of the file, not a user action.
                if existingFile.bitrateKbps == nil,
                   let bitrate = readBitrateKbps(forPathAt: absolutePath)
                {
                    bitrateBackfills.append((fileId: fileId, bitrate: bitrate))
                }

                let seratoMetadata = makeSeratoMetadata(fromRecord: record)
                let storedMetadata = makeSeratoMetadata(fromFileRecord: existingFile)
                if seratoMetadata == storedMetadata {
                    continue
                }
                do {
                    try await operationEngine.apply(.setMetadata(SetMetadataPayload(
                        fileId: fileId,
                        metadata: seratoMetadata,
                        isSeratoAuthoritative: true
                    )))
                    filesMetadataUpdated += 1
                    lastChangedPath = absolutePath
                } catch {
                    Self.logger.error(
                        "Metadata update for \(absolutePath, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
                    filesSkipped += 1
                }
                continue
            }

            guard let metadata = FileMetadataCollector.collect(
                at: absolutePath,
                includeLightweightHash: true
            ) else {
                Self.logger.warning(
                    "Serato references \(absolutePath, privacy: .public) but the file is missing or unreadable; skipping"
                )
                filesSkipped += 1
                continue
            }

            // Probe bitrate via the FFI. Cheap (read of a few hundred
            // bytes for the format header); only happens once per
            // file because the result lands in the row.
            let bitrate = readBitrateKbps(forPathAt: absolutePath)

            do {
                try await operationEngine.apply(.indexNewFile(IndexNewFilePayload(
                    path: metadata.path,
                    volumeUuid: metadata.volumeUuid,
                    inode: metadata.inode,
                    fileSize: metadata.fileSize,
                    mtime: metadata.mtime,
                    lightweightHash: metadata.lightweightHash,
                    bitrateKbps: bitrate,
                    metadata: makeSeratoMetadata(fromRecord: record)
                )))
                filesIndexed += 1
                lastChangedPath = absolutePath
            } catch {
                Self.logger.error(
                    "Index of \(absolutePath, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                filesSkipped += 1
                continue
            }

            if (filesIndexed + filesMetadataUpdated) % 50 == 0 {
                progress?(ScanProgress(
                    seratoReferenceCount: seratoRecords.count,
                    filesIndexed: filesIndexed,
                    filesMetadataUpdated: filesMetadataUpdated,
                    filesSkipped: filesSkipped,
                    lastChangedPath: lastChangedPath
                ))
            }
        }

        // Flush every backfill update in one transaction. SQLite
        // commits + fsyncs once instead of once per row; for 30k
        // files this is the difference between ~60k fsyncs and 1.
        if !hashBackfills.isEmpty || !bitrateBackfills.isEmpty {
            do {
                try await database.writer.write { db in
                    try scopeAuthorization?.check()
                    for entry in hashBackfills {
                        try db.execute(
                            sql: "UPDATE files SET lightweight_hash = ? WHERE id = ?",
                            arguments: [entry.hash, entry.fileId]
                        )
                    }
                    for entry in bitrateBackfills {
                        try db.execute(
                            sql: "UPDATE files SET bitrate_kbps = ? WHERE id = ?",
                            arguments: [entry.bitrate, entry.fileId]
                        )
                    }
                    try scopeAuthorization?.check()
                }
            } catch {
                throw error
            }
        }

        progress?(ScanProgress(
            seratoReferenceCount: seratoRecords.count,
            filesIndexed: filesIndexed,
            filesMetadataUpdated: filesMetadataUpdated,
            filesSkipped: filesSkipped,
            lastChangedPath: nil
        ))

        Self.logger.info(
            "Library scan complete: \(filesIndexed) indexed, \(filesMetadataUpdated) metadata updated, \(filesSkipped) skipped, \(seratoRecords.count) Serato references"
        )
        return ScanResult(
            seratoReferenceCount: seratoRecords.count,
            filesIndexed: filesIndexed,
            filesMetadataUpdated: filesMetadataUpdated,
            filesSkipped: filesSkipped
        )
    }

    // MARK: - Helpers

    /// Consumes exactly the saved generation reconciled by the caller. Run before
    /// queue drain; draining changes V2 and requires a newly read snapshot.
    @discardableResult
    func identityProjectionsForConflictAnalysis() async throws -> [FileRecord] {
        try await FileRecord.loadIdentityProjections(database: database)
    }

    func scan(snapshot: SeratoMembershipSnapshot, reader: SeratoMembershipSnapshotReader, analysis suppliedAnalysis: SeratoConflictAnalysis? = nil, plan: LibraryRefreshPlan? = nil, progress: ProgressHandler? = nil) async throws -> ScanResult {
        refreshedEvidence.removeAll()
        var fileInfoFailures: [String] = []
        try await reader.validate(snapshot)
        let directAuthorization = suppliedAnalysis == nil ? await operationEngine.captureConflictScope() : nil
        let files: [FileRecord]
        if let plan {
            let refreshed = try await database.writer.read { connection in
                try FileRecord.filter(plan.reconcileFileIDs.contains(Column("id"))).fetchAll(connection)
            }
            let byID = Dictionary(uniqueKeysWithValues: refreshed.compactMap { file in file.id.map { identifier in (identifier, file) } })
            files = plan.indexedFiles.map { file in file.id.flatMap { identifier in byID[identifier] } ?? file }
        } else {
            files = try await FileRecord.loadIdentityProjections(database: database)
        }
        let analysis: SeratoConflictAnalysis = if let suppliedAnalysis {
            suppliedAnalysis
        } else {
            try await SeratoConflictAnalyzer().analyze(snapshot: snapshot, files: files, pendingRenames: operationEngine.pendingRenameSources())
        }
        try analysis.validate(snapshot)
        try await reader.validate(snapshot)
        if suppliedAnalysis == nil {
            try await operationEngine.installDirectConflictAnalysis(analysis, authorization: directAuthorization)
        }
        var byPath: [String: FileRecord] = [:]
        for file in files where analysis.scope.conflictingPath(for: .file(file)) == nil {
            let path = SeratoPath.normalized(file.path)
            guard byPath.updateValue(file, forKey: path) == nil else { throw SeratoReconciliationError.ambiguousIdentity(path) }
        }
        var records: [String: SeratoTrackRecord] = [:]
        for record in snapshot.records {
            let path = SeratoPath.normalized(record.path)
            guard analysis.scope.conflictingPath(for: SeratoConflictTarget(paths: [path])) == nil else { continue }
            guard records.updateValue(record, forKey: path) == nil else { throw SeratoReconciliationError.ambiguousIdentity(path) }
        }
        var renameSources: [String: Int64] = [:]
        for source in try await operationEngine.pendingRenameSources() where analysis.scope.conflictingPath(for: SeratoConflictTarget(fileIDs: [source.fileID])) == nil {
            renameSources[SeratoPath.normalized(source.savedPath)] = source.fileID
        }
        let plannedCount = plan.map { plan in plan.refreshPaths.union(plan.metadataPaths).count } ?? records.count
        var completed = 0
        var indexed = 0
        var updated = 0
        var skipped = 0
        let resolver = FileAvailabilityResolver()
        for path in records.keys.sorted() {
            try Task.checkCancellation()
            guard let record = records[path] else { preconditionFailure("Snapshot path index lost a record") }
            let rawPath = Data(record.path.utf8)
            if let plan, !plan.refreshPaths.contains(rawPath), !plan.metadataPaths.contains(rawPath) {
                continue
            }
            completed += 1
            let existing = byPath[path]
            if let plan, plan.metadataPaths.contains(rawPath) {
                guard let existing, let identifier = existing.id, let evidence = plan.evidence[identifier],
                      evidence.identity == existing.identity, evidence.membershipRevision == existing.membershipRevision,
                      let stamp = evidence.readIdentity else { throw SyncCheckpointError.changed }
                let authorization = try await reader.authorization(for: snapshot)
                let events = try await operationEngine.observeSnapshotMetadata(.init(fileId: identifier, expectedRevision: existing.membershipRevision,
                                                                                     previousIdentity: existing.identity, identity: existing.identity,
                                                                                     metadata: makeSeratoMetadata(fromRecord: record), bitrateKbps: existing.bitrateKbps,
                                                                                     expectedState: existing.libraryState), authorization: authorization,
                                                                               metadataEvidence: stamp, expectedMetadata: existing.seratoMetadata)
                if !events.isEmpty {
                    updated += 1
                }
                refreshedEvidence[identifier] = evidence
                continue
            }
            if existing == nil, let fileID = renameSources[path] {
                // Serato still saves this file's record at the old path of its
                // queued rename, so the record is that file's saved metadata.
                if try await observeRenamedRecord(record, fileID: fileID, snapshot: snapshot, reader: reader) {
                    updated += 1
                }
                continue
            }
            if let existing, existing.libraryMembership != .active || existing.fileAvailability != .available
                || (existing.seratoLibraryId != nil && existing.seratoLibraryId != snapshot.libraryID)
            {
                skipped += 1
                continue
            }
            guard let basic = FileMetadataCollector.collect(at: path) else {
                // Missing audio remains diagnosable through reconciliation's availability.
                skipped += 1
                continue
            }
            guard try resolver.inspect(path: path, volumeID: existing?.volumeUuid ?? basic.volumeUuid) == .available else {
                skipped += 1
                continue
            }
            let stamp = try AudioFileReadIdentity.read(at: path)
            let identity = try identityReader(path)
            guard analysis.scope.conflictingPath(for: SeratoConflictTargets.identity(identity)) == nil else {
                skipped += 1
                continue
            }
            let bitrate: Int?
            var bitrateError: String?
            do {
                LibrarySyncMetrics.current?.record(.audioTag)
                LibrarySyncMetrics.current?.record(.bitrate)
                bitrate = try bitrateReader(path)
            } catch is CancellationError { throw CancellationError() }
            catch {
                bitrate = nil
                bitrateError = "\((path as NSString).lastPathComponent): \(error.localizedDescription)"
                fileInfoFailures.append(bitrateError!)
            }
            try stamp.requireUnchanged(at: path)
            let metadata = makeSeratoMetadata(fromRecord: record)
            let authorization = try await reader.authorization(for: snapshot)
            if let existing, let fileID = existing.id {
                // Identity refresh belongs to reconciliation, which supersedes stale work.
                guard !FileIdentityObservationMutation.isReplacement(existing, identity: identity) else {
                    throw SeratoReconciliationError.ambiguousIdentity(path)
                }
                let events = try await operationEngine.observeSnapshotMetadata(.init(fileId: fileID, expectedRevision: existing.membershipRevision,
                                                                                     previousIdentity: existing.identity, identity: identity, metadata: metadata,
                                                                                     bitrateKbps: bitrate, bitrateWasRead: bitrateError == nil, expectedState: existing.libraryState), authorization: authorization)
                if !events.isEmpty {
                    updated += 1
                }
            } else {
                _ = try await operationEngine.applyObservedBatch([.indexNewFile(.init(path: identity.path, volumeUuid: identity.volumeUuid, inode: identity.inode,
                                                                                      fileSize: identity.fileSize, mtime: identity.mtime, lightweightHash: identity.lightweightHash,
                                                                                      bitrateKbps: bitrate, metadata: metadata))], authorization: authorization)
                guard let file = try await database.writer.read({ connection in
                    try FileRecord.filter(Column("path") == path).fetchOne(connection)
                }), let fileID = file.id else { throw SeratoReconciliationError.ambiguousIdentity(path) }
                try await reader.validate(snapshot)
                _ = try await operationEngine.applyObservedBatch([
                    .observeFileIdentity(.init(fileId: fileID, expectedRevision: file.membershipRevision, previousIdentity: file.identity, identity: identity, expectedState: file.libraryState)),
                    .setFileLibraryState(.init(fileId: fileID, expectedRevision: file.membershipRevision,
                                               state: FileLibraryState(membership: .active, availability: .available, libraryID: snapshot.libraryID, retiredAt: nil))),
                ], authorization: authorization)
                guard let active = try await database.writer.read({ connection in
                    try FileRecord.fetchOne(connection, key: fileID)
                }) else { throw SeratoReconciliationError.ambiguousIdentity(path) }
                _ = try await operationEngine.observeSnapshotMetadata(.init(fileId: fileID, expectedRevision: active.membershipRevision,
                                                                            previousIdentity: active.identity, identity: identity, metadata: metadata,
                                                                            expectedState: active.libraryState), authorization: authorization)
                indexed += 1
            }
            if let refreshed = try await database.writer.read({ connection in
                try FileRecord.filter(Column("path") == path).fetchOne(connection)
            }), let identifier = refreshed.id {
                try stamp.requireUnchanged(at: path)
                refreshedEvidence[identifier] = SyncFileEvidence(fileID: identifier, membershipRevision: refreshed.membershipRevision,
                                                                 identity: refreshed.identity, readIdentity: stamp, bitrateProbed: bitrateError == nil,
                                                                 bitrateError: bitrateError)
            }
            if (indexed + updated) % 50 == 0 {
                progress?(ScanProgress(completedFileCount: completed, seratoReferenceCount: plannedCount, filesIndexed: indexed, filesMetadataUpdated: updated, filesSkipped: skipped, lastChangedPath: path))
            }
        }
        try await reader.validate(snapshot)
        progress?(ScanProgress(completedFileCount: completed, seratoReferenceCount: plannedCount, filesIndexed: indexed, filesMetadataUpdated: updated, filesSkipped: skipped, lastChangedPath: nil))
        return ScanResult(fileInfoFailures: fileInfoFailures, seratoReferenceCount: records.count, filesIndexed: indexed, filesMetadataUpdated: updated, filesSkipped: skipped)
    }

    /// Read Serato's database V2 and return the records keyed by
    /// absolute path. Off the actor's isolation domain because the
    /// FFI call can take a while on a 25MB database.
    /// Observes the record at a queued rename's old path as the renamed file's
    /// saved metadata. Audio identity is not re-read: the record names a path
    /// the file no longer occupies, so only its saved V2 fields are evidence.
    private func observeRenamedRecord(_ record: SeratoTrackRecord, fileID: Int64, snapshot: SeratoMembershipSnapshot,
                                      reader: SeratoMembershipSnapshotReader) async throws -> Bool
    {
        guard let file = try await database.writer.read({ connection in try FileRecord.fetchOne(connection, key: fileID) }),
              file.libraryMembership == .active, file.fileAvailability == .available,
              file.seratoLibraryId == nil || file.seratoLibraryId == snapshot.libraryID else { return false }
        let authorization = try await reader.authorization(for: snapshot)
        let events = try await operationEngine.observeSnapshotMetadata(.init(fileId: fileID, expectedRevision: file.membershipRevision,
                                                                             previousIdentity: file.identity, identity: file.identity,
                                                                             metadata: makeSeratoMetadata(fromRecord: record), bitrateKbps: file.bitrateKbps,
                                                                             expectedState: file.libraryState), authorization: authorization)
        return !events.isEmpty
    }

    private func loadSeratoRecords() async throws -> [(String, SeratoTrackRecord)] {
        let databaseV2Path = seratoLocator.databaseV2Url.path
        guard FileManager.default.fileExists(atPath: databaseV2Path) else {
            return []
        }
        let records = try await Task.detached(priority: .userInitiated) {
            try readDatabaseRecords(databasePath: databaseV2Path)
        }.value
        return records.map { record in
            let absolutePath = record.path.hasPrefix("/") ? record.path : "/" + record.path
            return (absolutePath, record)
        }
    }

    private func loadKnownFilesByPath() async throws -> [String: FileRecord] {
        let allFiles: [FileRecord] = try await database.writer.read { db in
            try FileRecord.fetchAll(db)
        }
        let indexed = Self.buildPathIndex(allFiles)
        if indexed.duplicatePathCount > 0 {
            throw SeratoReconciliationError.ambiguousIdentity("Multiple indexed rows share a path")
        }
        return indexed.byPath
    }

    /// Build the path → FileRecord lookup map used by `scan`.
    /// Defensive: the `files.path` column has a UNIQUE constraint, so
    /// duplicates "shouldn't" exist. In practice large libraries can
    /// carry bytewise-distinct paths that pass the SQL constraint but
    /// COLLIDE on Swift's `String == String` (Unicode normalization
    /// — NFC vs NFD "Café.mp3" produces different SQLite UTF-8 byte
    /// sequences but identical Swift strings). `Dictionary(uniqueKeysWithValues:)`
    /// traps on collision; `buildPathIndex` is the tolerant
    /// alternative — last-write-wins, surfaces a count for logging.
    static func buildPathIndex(
        _ files: [FileRecord]
    ) -> (byPath: [String: FileRecord], duplicatePathCount: Int) {
        var byPath: [String: FileRecord] = [:]
        byPath.reserveCapacity(files.count)
        var duplicatePathCount = 0
        for file in files {
            if byPath[file.path] != nil {
                duplicatePathCount += 1
            }
            byPath[file.path] = file
        }
        return (byPath, duplicatePathCount)
    }

    private func makeSeratoMetadata(fromRecord record: SeratoTrackRecord) -> SeratoMetadata {
        SeratoMetadata(
            artist: record.artist,
            title: record.title,
            album: record.album,
            genre: record.genre,
            bpm: record.bpm,
            musicalKey: record.key,
            comment: record.comment,
            length: record.length,
            label: record.label
        )
    }

    private func makeSeratoMetadata(fromFileRecord file: FileRecord) -> SeratoMetadata {
        SeratoMetadata(
            artist: file.artist,
            title: file.title,
            album: file.album,
            genre: file.genre,
            bpm: file.bpm,
            musicalKey: file.musicalKey,
            comment: file.comment,
            length: file.length,
            label: file.label
        )
    }

    /// Probe a file's audio bitrate via the existing `readAudioTags`
    /// FFI. Returns nil if the file is unreadable or the format
    /// doesn't carry a bitrate; the keeper picker treats nil as
    /// "unknown" rather than zero.
    private func readBitrateKbps(forPathAt path: String) -> Int? {
        do {
            let tags = try readAudioTags(filePath: path)
            return tags.bitrateKbps.map(Int.init)
        } catch {
            return nil
        }
    }
}
