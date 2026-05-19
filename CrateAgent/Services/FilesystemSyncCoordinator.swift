import Foundation
import GRDB
import os.log

/// Translates `FSEventsObservation` values into `TrackMutation` calls
/// on the `OperationEngine`. Sits between the raw filesystem watcher
/// (an event source) and the engine (a mutation sink).
///
/// Per the project's "Serato is the source of truth" design, the
/// coordinator ONLY processes events for files crate-agent already
/// knows about — i.e., files that the LibraryScanner pulled in from
/// Serato's library. New files appearing under the watched folder
/// that aren't in Serato are intentionally ignored. The user adds
/// new tracks via Serato itself (or, in a future PR, by dragging
/// onto crate-agent's window).
///
/// Behavior:
/// - `wasRenamed` + file exists + inode matches a known file →
///   `renameFile` (the file moved; update Serato's pointers)
/// - `wasRenamed` + file exists + inode does NOT match any known
///   file → ignore (file isn't in Serato; not our concern)
/// - `wasRenamed` + file doesn't exist → ignore (old-path side of
///   a rename; the new-path event carries the update)
/// - `wasCreated` → ignore (new files only enter via Serato or
///   drag-drop, not auto-indexed)
/// - `wasRemoved` → deferred until removeFile lands in
///   OperationEngine.
///
/// Audio extension filter prevents OS-side metadata files
/// (`.DS_Store`, `.localized`, sidecar `*.cue`, etc.) from
/// triggering needless DB lookups.
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
        guard observation.wasRenamed && fileExistsOnDisk else {
            // wasCreated / wasRenamed-old-side / wasRemoved /
            // wasModified are all no-ops under the Serato-source-of-
            // truth design. New files come in via the LibraryScanner
            // (which reads Serato) or via the drag-drop import flow
            // (future PR); FSEvents is only for tracking existing
            // file movement.
            return
        }

        await handleRename(path: observation.path)
    }

    private func handleRename(path: String) async {
        guard let metadata = FileMetadataCollector.collect(at: path) else {
            Self.logger.warning(
                "could not stat file at \(path, privacy: .public); skipping"
            )
            return
        }

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

        guard let existing = existingFile, let fileId = existing.id else {
            // File at this inode isn't in crate-agent's DB → not in
            // Serato's library → not our concern. Apple Music files,
            // user's general music folder, etc. all hit this branch.
            return
        }
        if existing.path == path {
            return  // already up to date; duplicate event
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
    }
}
