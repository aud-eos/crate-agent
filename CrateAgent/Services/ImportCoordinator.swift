import Foundation
import GRDB
import os.log

/// Orchestrates the drag-drop import flow. The user drops files or
/// folders onto crate-agent's window; this actor walks them, reads
/// audio tags via the existing FFI, and fires two-mutation batches
/// (`indexNewFile` + `addTrackToSerato`) through the OperationEngine.
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
    }

    private static let logger = Logger(
        subsystem: "com.crateagent.app",
        category: "ImportCoordinator"
    )

    private let operationEngine: OperationEngine
    private let database: LibraryDatabase
    private let audioExtensions: Set<String>

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

        for rootUrl in urls {
            let audioFileUrls = enumerateAudioFiles(at: rootUrl)
            for fileUrl in audioFileUrls {
                if await importSingleFile(at: fileUrl) {
                    filesImported += 1
                } else {
                    filesSkipped += 1
                }
            }
        }
        return ImportResult(filesImported: filesImported, filesSkipped: filesSkipped)
    }

    private func importSingleFile(at fileUrl: URL) async -> Bool {
        let absolutePath = fileUrl.path

        let fileMetadata: FileMetadata
        do {
            fileMetadata = try FileMetadataCollector.collectVerified(at: SeratoPath.normalized(absolutePath))
        } catch {
            Self.logger.warning(
                "could not stat \(absolutePath, privacy: .public); skipping import"
            )
            return false
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
                guard existing.libraryMembership != .active,
                      FileImportIdentity.matches(existing, identity: fileMetadata),
                      let existingID = existing.id else { return false }
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
                    return false
                }
                fileId = newId
            }
        } catch {
            // Most likely cause: path already in the DB (path is UNIQUE).
            // That's a no-op for the user — they re-dropped a file
            // crate-agent already knew about.
            Self.logger.info(
                "indexNewFile rejected (likely duplicate path): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        do {
            let file = try await database.writer.read { database in
                try FileRecord.fetchOne(database, key: fileId)
            }
            guard let file else { throw OperationEngineError.fileNotFound(fileId: fileId) }
            _ = try await operationEngine.applyBatch([
                .beginFileImport(BeginFileImportPayload(fileId: fileId, expectedRevision: file.membershipRevision, identity: fileMetadata)),
                .addTrackToSerato(AddTrackToSeratoPayload(
                    fileId: fileId,
                    metadata: seratoMetadata
                )),
            ],
            batchId: batchId)
        } catch {
            Self.logger.error(
                "addTrackToSerato for \(absolutePath, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        return true
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
            musicalKey: nil,  // not in AudioTags; Serato analysis fills this
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
