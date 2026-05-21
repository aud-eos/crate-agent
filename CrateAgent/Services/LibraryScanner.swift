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
/// Tracks Serato has removed are NOT yet pruned from the local table
/// (the `removeFile` mutation hasn't landed). They'd just sit there
/// orphaned until that ships.
///
/// Used by AppServices on launch and by SeratoSyncCoordinator when
/// Serato quits — same operation in both contexts.
public actor LibraryScanner {

    public struct ScanProgress: Sendable, Equatable {
        public let seratoReferenceCount: Int
        public let filesIndexed: Int
        public let filesMetadataUpdated: Int
        public let filesSkipped: Int
        public let lastChangedPath: String?
    }

    public struct ScanResult: Sendable, Equatable {
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

    public init(
        operationEngine: OperationEngine,
        database: LibraryDatabase,
        seratoLocator: SeratoLibraryLocator
    ) {
        self.operationEngine = operationEngine
        self.database = database
        self.seratoLocator = seratoLocator
    }

    @discardableResult
    public func scan(progress: ProgressHandler? = nil) async throws -> ScanResult {
        Self.logger.info("Starting Serato library scan")

        let seratoRecords = try await loadSeratoRecords()
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
               let fileId = existingFile.id {
                // Backfill lightweightHash for rows that pre-date the
                // cross-volume-move feature. Idempotent: skipped when
                // the hash is already present. Direct DB write rather
                // than a mutation — the hash is a derived value, not
                // a user action, so it doesn't belong in the event log.
                if existingFile.lightweightHash == nil,
                   let hash = LightweightHashCalculator.compute(forFileAt: absolutePath) {
                    hashBackfills.append((fileId: fileId, hash: hash))
                }

                // Same idempotent backfill for bitrate (added in
                // migration #004). Same direct-write rationale: bitrate
                // is a derived property of the file, not a user action.
                if existingFile.bitrateKbps == nil,
                   let bitrate = readBitrateKbps(forPathAt: absolutePath) {
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
                        metadata: seratoMetadata
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
                }
            } catch {
                Self.logger.error(
                    "Backfill flush failed: \(error.localizedDescription, privacy: .public)"
                )
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

    /// Read Serato's database V2 and return the records keyed by
    /// absolute path. Off the actor's isolation domain because the
    /// FFI call can take a while on a 25MB database.
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
            Self.logger.warning(
                "loadKnownFilesByPath: \(indexed.duplicatePathCount, privacy: .public) duplicate path(s) in files table (likely Unicode normalization or symlink-resolution mismatches). Last-seen wins. Investigate via #35 if this recurs."
            )
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
            if byPath[file.path] != nil { duplicatePathCount += 1 }
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
