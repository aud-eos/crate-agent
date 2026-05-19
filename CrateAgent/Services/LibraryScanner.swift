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

        for (absolutePath, record) in seratoRecords {
            if let existingFile = knownFilesByPath[absolutePath],
               let fileId = existingFile.id {
                // Backfill lightweightHash for rows that pre-date the
                // cross-volume-move feature. Idempotent: skipped when
                // the hash is already present. Direct DB write rather
                // than a mutation — the hash is a derived value, not
                // a user action, so it doesn't belong in the event log.
                if existingFile.lightweightHash == nil {
                    if let hash = LightweightHashCalculator.compute(forFileAt: absolutePath) {
                        do {
                            try await database.writer.write { db in
                                try db.execute(
                                    sql: "UPDATE files SET lightweight_hash = ? WHERE id = ?",
                                    arguments: [hash, fileId]
                                )
                            }
                        } catch {
                            Self.logger.error(
                                "Hash backfill for \(absolutePath, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }
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

            do {
                try await operationEngine.apply(.indexNewFile(IndexNewFilePayload(
                    path: metadata.path,
                    volumeUuid: metadata.volumeUuid,
                    inode: metadata.inode,
                    fileSize: metadata.fileSize,
                    mtime: metadata.mtime,
                    lightweightHash: metadata.lightweightHash,
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
        return Dictionary(uniqueKeysWithValues: allFiles.map { ($0.path, $0) })
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
}
