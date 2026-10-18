import Foundation
import GRDB
import os.log

/// Orchestrates the drag-drop import flow. The user drops files or
/// folders onto crate-agent's window; this actor walks them, reads
/// audio tags via the existing FFI, and journals each file in its own batch
/// (`indexNewFile`, then `beginFileImport` + `addTrackToSerato`) through the
/// OperationEngine. The drop's Serato adds are then applied in one pass, so
/// a drop rewrites `database V2` once per 200 files rather than once per
/// file (#187).
///
/// `indexNewFile` registers the file in crate-agent's DB; the path
/// uniqueness constraint makes re-drops a safe no-op. `addTrackToSerato`
/// appends to Serato's `database V2` — gated by SeratoWatchdog, so
/// dropping while Serato is open queues the Serato write to drain
/// when Serato exits.
///
/// Folder drops recurse for audio files (same extension filter as the
/// FilesystemSyncCoordinator). Non-audio files are silently skipped —
/// this isn't a general-purpose file importer, it's a music importer.
public actor ImportCoordinator {
    public static let defaultAudioExtensions: Set<String> = FilesystemSyncCoordinator.defaultAudioExtensions

    public struct ImportResult: Sendable, Equatable {
        public let filesImported: Int
        public let filesSkipped: Int
        public let syncFailures: [String]
        public let blockedFiles: [String]
        /// Files whose Serato add was dropped because the file changed first,
        /// each with what to do; Retry Sync has nothing to finish for them.
        public let filesNotAdded: [String]
        /// Files an earlier drop is still importing.
        public let filesAlreadyImporting: [String]

        public init(filesImported: Int, filesSkipped: Int, syncFailures: [String], blockedFiles: [String] = [],
                    filesNotAdded: [String] = [], filesAlreadyImporting: [String] = [])
        {
            self.filesImported = filesImported
            self.filesSkipped = filesSkipped
            self.syncFailures = syncFailures
            self.blockedFiles = blockedFiles
            self.filesNotAdded = filesNotAdded
            self.filesAlreadyImporting = filesAlreadyImporting
        }

        public var filesPendingSync: Int {
            syncFailures.count
        }
    }

    private enum FileImportOutcome {
        case awaitingSerato(DeferredSeratoBatch)
        case skipped
        case blocked(String)
        /// The file changed between its stat and its import mutations.
        case notAdded(String)
    }

    public static let alreadyImportingMessage = "already being imported"
    public static let changedBeforeAddMessage = "Not added to Serato: the file changed before it could be registered. Drop it again to import it."

    private static let logger = Logger(
        subsystem: "com.crateagent.app",
        category: "ImportCoordinator"
    )

    private let operationEngine: OperationEngine
    private let database: LibraryDatabase
    private let audioExtensions: Set<String>
    /// Normalized paths an unfinished drop is importing. The actor is
    /// reentrant, so a drop claims its paths with no suspension in between.
    private var inFlightPaths = Set<String>()

    public init(
        operationEngine: OperationEngine,
        database: LibraryDatabase,
        audioExtensions: Set<String> = ImportCoordinator.defaultAudioExtensions
    ) {
        self.operationEngine = operationEngine
        self.database = database
        self.audioExtensions = audioExtensions
    }

    /// Walk every URL the user dropped — files become single
    /// imports, directories recurse — and route audio files into the
    /// engine. Returns a tally for the caller to surface in UI.
    @discardableResult
    public func importDroppedItems(_ urls: [URL]) async -> ImportResult {
        var filesImported = 0
        var filesSkipped = 0
        var syncFailures: [String] = []
        var blockedFiles: [String] = []
        var filesNotAdded: [String] = []
        var filesAlreadyImporting: [String] = []
        var awaitingSerato: [(batch: DeferredSeratoBatch, fileName: String)] = []

        var claimed: [(url: URL, path: String)] = []
        var seenPaths = Set<String>()
        for rootUrl in urls {
            for fileUrl in enumerateAudioFiles(at: rootUrl) {
                let path = SeratoPath.normalized(fileUrl.path)
                guard seenPaths.insert(path).inserted else { continue }
                if inFlightPaths.insert(path).inserted {
                    claimed.append((fileUrl, path))
                } else {
                    filesAlreadyImporting.append("\(fileUrl.lastPathComponent): \(Self.alreadyImportingMessage)")
                }
            }
        }
        defer { inFlightPaths.subtract(claimed.map(\.path)) }
        for file in claimed {
            switch await importSingleFile(at: file.url) {
            case let .awaitingSerato(batch):
                awaitingSerato.append((batch, file.url.lastPathComponent))
            case .skipped:
                filesSkipped += 1
            case let .blocked(message):
                blockedFiles.append(message)
            case let .notAdded(message):
                filesNotAdded.append(message)
            }
        }
        let shortfalls: [String: DeferredSeratoShortfall]
        do { shortfalls = try await operationEngine.routeDeferredSeratoWrites(awaitingSerato.map(\.batch)) }
        catch {
            // Only the status read after the pass throws here, so which adds
            // landed is unknown; Retry Sync replays any still queued.
            Self.logger.error("confirming dropped files with Serato failed: \(error.localizedDescription, privacy: .public)")
            let shortfall = DeferredSeratoShortfall.failed("Could not confirm the Serato registration: \(error.localizedDescription)")
            shortfalls = Dictionary(awaitingSerato.map { entry in (entry.batch.batchId, shortfall) }, uniquingKeysWith: { first, _ in first })
        }
        for entry in awaitingSerato {
            switch shortfalls[entry.batch.batchId] {
            case let .failed(failure): syncFailures.append("\(entry.fileName): \(failure)")
            case .superseded: filesNotAdded.append("\(entry.fileName): \(Self.changedBeforeAddMessage)")
            case nil: filesImported += 1
            }
        }
        return ImportResult(filesImported: filesImported, filesSkipped: filesSkipped, syncFailures: syncFailures, blockedFiles: blockedFiles,
                            filesNotAdded: filesNotAdded, filesAlreadyImporting: filesAlreadyImporting)
    }

    private func importSingleFile(at fileUrl: URL) async -> FileImportOutcome {
        let absolutePath = fileUrl.path

        let fileMetadata: FileMetadata
        do {
            try await operationEngine.requireUnconflicted(SeratoConflictTarget(paths: [absolutePath]))
            fileMetadata = try FileMetadataCollector.collectVerified(at: SeratoPath.normalized(absolutePath))
            try await operationEngine.requireUnconflicted(SeratoConflictTargets.identity(fileMetadata))
        } catch let conflict as SeratoPathConflictError {
            return .blocked(conflict.localizedDescription)
        } catch {
            Self.logger.warning(
                "could not stat \(absolutePath, privacy: .public); skipping import"
            )
            return .skipped
        }

        // Read existing audio tags via the FFI; failures fall back to
        // an empty metadata struct so the file still gets imported
        // (with no artist/title/etc., to be filled in later).
        let (seratoMetadata, bitrateKbps) = readMetadataAndBitrate(from: absolutePath)

        let batchId = UUID().uuidString

        let fileId: Int64
        do {
            let existing = try await database.writer.read { database in
                let candidates = try FileRecord.filter(Column("path") == fileMetadata.path || (Column("inode") == fileMetadata.inode && Column("volume_uuid") == fileMetadata.volumeUuid)).fetchAll(database)
                    .filter { file in SeratoPath.normalized(file.path) == SeratoPath.normalized(fileMetadata.path) }
                guard candidates.count <= 1 else { throw SeratoReconciliationError.ambiguousIdentity(fileMetadata.path) }
                return candidates.first
            }
            if let existing {
                guard existing.libraryMembership != .active, let existingID = existing.id else { return .skipped }
                if !FileImportIdentity.matches(existing, identity: fileMetadata) {
                    // Only an import that never finished, such as one whose add
                    // was superseded because the file changed, takes the file now
                    // at its path; a retired row never adopts a replacement.
                    guard [.pendingImport, .legacyUnverified].contains(existing.libraryMembership) else { return .skipped }
                    _ = try await operationEngine.apply(
                        .observeFileIdentity(ObserveFileIdentityPayload(
                            fileId: existingID, expectedRevision: existing.membershipRevision,
                            previousIdentity: existing.identity, identity: fileMetadata,
                            metadata: seratoMetadata, bitrateKbps: bitrateKbps, expectedState: existing.libraryState
                        )),
                        batchId: batchId
                    )
                }
                fileId = existingID
            } else {
                _ = try await operationEngine.apply(
                    .indexNewFile(IndexNewFilePayload(
                        path: fileMetadata.path,
                        volumeUuid: fileMetadata.volumeUuid,
                        inode: fileMetadata.inode,
                        fileSize: fileMetadata.fileSize,
                        mtime: fileMetadata.mtime,
                        lightweightHash: fileMetadata.lightweightHash,
                        bitrateKbps: bitrateKbps,
                        metadata: seratoMetadata
                    )),
                    batchId: batchId
                )
                // Look up the just-inserted file's id for the Serato add.
                guard let newId = try await database.writer.read({ db in
                    try Int64.fetchOne(
                        db,
                        sql: "SELECT id FROM files WHERE path = ?",
                        arguments: [fileMetadata.path]
                    )
                }) else {
                    Self.logger.error(
                        "indexNewFile succeeded but the row at \(fileMetadata.path, privacy: .public) is gone"
                    )
                    return .skipped
                }
                fileId = newId
            }
        } catch let conflict as SeratoPathConflictError {
            return .blocked(conflict.localizedDescription)
        } catch let readiness as LibrarySyncReadinessError {
            return .blocked("\(fileUrl.lastPathComponent): \(readiness.localizedDescription)")
        } catch {
            return Self.unimported(fileUrl, error: error)
        }

        do {
            let file = try await database.writer.read { database in
                try FileRecord.fetchOne(database, key: fileId)
            }
            guard let file else { throw OperationEngineError.fileNotFound(fileId: fileId) }
            return try await .awaitingSerato(operationEngine.applyBatchDeferringSerato([
                    .beginFileImport(BeginFileImportPayload(fileId: fileId, expectedRevision: file.membershipRevision, identity: fileMetadata)),
                    .addTrackToSerato(AddTrackToSeratoPayload(
                        fileId: fileId,
                        metadata: seratoMetadata
                    )),
                ],
                batchId: batchId))
        } catch let conflict as SeratoPathConflictError {
            return .blocked(conflict.localizedDescription)
        } catch {
            return Self.unimported(fileUrl, error: error)
        }
    }

    /// A file whose import mutations threw is reported with its reason, never
    /// counted as skipped: a file that changed meanwhile can be dropped again,
    /// and anything else, such as an ambiguous legacy identity, needs fixing.
    private static func unimported(_ fileUrl: URL, error: Error) -> FileImportOutcome {
        let fileName = fileUrl.lastPathComponent
        if case FileProcessingEligibilityError.superseded = error {
            return .notAdded("\(fileName): \(changedBeforeAddMessage)")
        }
        logger.error("importing \(fileUrl.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        return .blocked("\(fileName): \(error.localizedDescription)")
    }

    private func readMetadataAndBitrate(from path: String) -> (SeratoMetadata, Int?) {
        let tags: AudioTags
        do {
            tags = try readAudioTags(filePath: path)
        } catch {
            Self.logger.info(
                "no readable tags for \(path, privacy: .public); importing with empty metadata"
            )
            return (SeratoMetadata(), nil)
        }

        let metadata = SeratoMetadata(
            artist: tags.artist,
            title: tags.title,
            album: tags.album,
            genre: tags.genre,
            // BPM in audio tags is a Double; convert to Serato's string format.
            bpm: tags.bpm.map { String(format: "%.3f", $0) },
            musicalKey: nil, // not in AudioTags; Serato analysis fills this
            comment: tags.comment,
            length: tags.durationSeconds.map(Self.formatDuration),
            label: nil
        )
        return (metadata, tags.bitrateKbps.map(Int.init))
    }

    private nonisolated func enumerateAudioFiles(at rootUrl: URL) -> [URL] {
        let resourceValues = try? rootUrl.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = resourceValues?.isDirectory ?? false

        if !isDirectory {
            return isAudioFile(at: rootUrl) ? [rootUrl] : []
        }

        var collected: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: rootUrl,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            if isAudioFile(at: url) {
                collected.append(url)
            }
        }
        return collected
    }

    private nonisolated func isAudioFile(at url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    private static func formatDuration(_ seconds: UInt64) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
