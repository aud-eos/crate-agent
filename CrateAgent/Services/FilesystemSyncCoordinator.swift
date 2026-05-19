import Foundation
import GRDB
import os.log

/// Translates `FSEventsObservation` values into `TrackMutation` calls
/// on the `OperationEngine`. Sits between the raw filesystem watcher
/// (an event source) and the engine (a mutation sink).
///
/// SP-1 v1 behavior:
/// - `wasCreated` + audio extension + file exists → `indexNewFile`
/// - `wasRenamed` + file exists at the new path → look up by inode in
///   the `files` table; if found, issue `renameFile`; if not, fall
///   through to `indexNewFile`
/// - `wasRenamed` events where the file does not exist at the
///   observed path are skipped — that's the old-path side of a
///   rename; the new-path event arriving in the same batch (or
///   immediately after) carries the inode that lets us update the
///   row in place.
/// - `wasRemoved` is deferred until removeFile lands in
///   OperationEngine.
///
/// Audio extension filter prevents OS-side metadata files
/// (`.DS_Store`, `.localized`, sidecar `*.cue`, etc.) from polluting
/// the library. The default set covers every format Serato accepts.
public actor FilesystemSyncCoordinator {

    public static let defaultAudioExtensions: Set<String> = [
        "mp3", "flac", "wav", "wave", "aif", "aiff",
        "m4a", "mp4", "alac", "aac",
        "ogg", "oga", "opus",
    ]

    private static let logger = Logger(
        subsystem: "com.crateagent.app",
        category: "FilesystemSyncCoordinator"
    )

    private let operationEngine: OperationEngine
    private let database: LibraryDatabase
    private let audioExtensions: Set<String>

    public init(
        operationEngine: OperationEngine,
        database: LibraryDatabase,
        audioExtensions: Set<String> = FilesystemSyncCoordinator.defaultAudioExtensions
    ) {
        self.operationEngine = operationEngine
        self.database = database
        self.audioExtensions = audioExtensions
    }

    public func handleObservations(_ observations: [FSEventsObservation]) async {
        for observation in observations {
            await handle(observation)
        }
    }

    private func handle(_ observation: FSEventsObservation) async {
        guard observation.isFile else { return }

        let pathExtension = (observation.path as NSString).pathExtension.lowercased()
        guard audioExtensions.contains(pathExtension) else { return }

        let fileExistsOnDisk = FileManager.default.fileExists(atPath: observation.path)

        if observation.wasRenamed && fileExistsOnDisk {
            await handleRenameOrIndex(path: observation.path)
            return
        }
        if observation.wasCreated && fileExistsOnDisk {
            await indexNewFile(path: observation.path)
            return
        }
        // wasRenamed + !fileExistsOnDisk: old-path side of a rename;
        // intentionally ignored. wasRemoved: deferred to a later commit.
    }

    private func handleRenameOrIndex(path: String) async {
        guard let metadata = FileMetadataCollector.collect(at: path) else {
            Self.logger.warning(
                "could not stat file at \(path, privacy: .public); skipping"
            )
            return
        }

        // If a file with this inode is already known, the event
        // represents a move/rename of that file to its new path.
        let existingFile: FileRecord?
        do {
            existingFile = try await database.writer.read { db in
                try FileRecord
                    .filter(Column("inode") == metadata.inode)
                    .filter(Column("volume_uuid") == metadata.volumeUuid)
                    .fetchOne(db)
            }
        } catch {
            Self.logger.error(
                "DB lookup for inode \(metadata.inode) failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        if let existing = existingFile, let fileId = existing.id {
            if existing.path == path {
                return  // row already up to date — likely a duplicate event
            }
            do {
                try await operationEngine.apply(.renameFile(RenameFilePayload(
                    fileId: fileId,
                    newPath: path
                )))
            } catch {
                Self.logger.error(
                    "rename mutation for file \(fileId) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            return
        }

        // No prior knowledge of this inode → treat the rename event
        // as "discovered a new file at this path."
        await indexNewFile(path: path, metadata: metadata)
    }

    private func indexNewFile(path: String, metadata precomputed: FileMetadata? = nil) async {
        let metadata = precomputed ?? FileMetadataCollector.collect(at: path)
        guard let metadata else {
            Self.logger.warning(
                "could not stat file at \(path, privacy: .public); skipping index"
            )
            return
        }

        do {
            try await operationEngine.apply(.indexNewFile(IndexNewFilePayload(
                path: metadata.path,
                volumeUuid: metadata.volumeUuid,
                inode: metadata.inode,
                fileSize: metadata.fileSize,
                mtime: metadata.mtime
            )))
        } catch {
            Self.logger.error(
                "index mutation for \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

}
