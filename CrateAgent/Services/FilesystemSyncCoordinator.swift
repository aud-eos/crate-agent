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
///   file + lightweight hash matches a known file →
///   `renameFile` with cross-volume identity update (the file moved
///   to a different volume; refresh inode + volume_uuid alongside path)
/// - `wasRenamed` + file exists + neither inode nor hash matches
///   anything → ignore (file isn't in Serato; not our concern)
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
        // Stat-only first. Computing the lightweight hash reads up to
        // 2 MB per file — wasted work for the common case (same-volume
        // rename, satisfied by the inode lookup below). During a Bulk
        // Organize of 5k files this avoided ~10 GB of disk I/O.
        guard let statMetadata = FileMetadataCollector.collect(
            at: path,
            includeLightweightHash: false
        ) else {
            Self.logger.warning(
                "could not stat file at \(path, privacy: .public); skipping"
            )
            return
        }

        // First pass: same-volume rename (inode + volume_uuid match).
        // This is the common case — Finder rename, mv within a volume,
        // editor "Save As" reusing the inode, etc.
        let inodeMatch: FileRecord?
        do {
            inodeMatch = try await database.writer.read { db in
                try FileRecord
                    .filter(Column("inode") == statMetadata.inode)
                    .filter(Column("volume_uuid") == statMetadata.volumeUuid)
                    .fetchOne(db)
            }
        } catch {
            Self.logger.error(
                "DB lookup for inode \(statMetadata.inode) failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        if let existing = inodeMatch, let fileId = existing.id {
            if existing.path == path {
                return  // already up to date; duplicate event
            }
            await applyRename(
                fileId: fileId,
                newPath: path,
                crossVolumeIdentity: nil
            )
            return
        }

        // Second pass: cross-volume move fallback (file_size +
        // lightweight_hash match an existing row whose inode/volume
        // didn't). Only now do we read the file content to compute
        // the hash — same-volume renames never get this far.
        guard let lightweightHash = LightweightHashCalculator.compute(
            forFileAt: path
        ) else {
            // Hash unreadable: fall back to inode-only behavior,
            // which we've already exhausted. Not our file.
            return
        }
        // Compose a metadata record carrying the freshly-computed
        // hash so the rest of the function reads as one logical flow.
        let metadata = FileMetadata(
            path: statMetadata.path,
            volumeUuid: statMetadata.volumeUuid,
            inode: statMetadata.inode,
            fileSize: statMetadata.fileSize,
            mtime: statMetadata.mtime,
            lightweightHash: lightweightHash
        )

        let hashMatch: FileRecord?
        do {
            hashMatch = try await database.writer.read { db in
                try FileRecord
                    .filter(Column("file_size") == metadata.fileSize)
                    .filter(Column("lightweight_hash") == lightweightHash)
                    .fetchOne(db)
            }
        } catch {
            Self.logger.error(
                "DB hash lookup at \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        guard let existing = hashMatch, let fileId = existing.id else {
            // Not in Serato's library — not our concern.
            return
        }
        if existing.path == path
            && existing.inode == metadata.inode
            && existing.volumeUuid == metadata.volumeUuid {
            return  // already up to date; duplicate event after the row was updated
        }

        Self.logger.info(
            "Cross-volume move detected for file \(fileId): \(existing.path, privacy: .public) → \(path, privacy: .public)"
        )
        await applyRename(
            fileId: fileId,
            newPath: path,
            crossVolumeIdentity: (volumeUuid: metadata.volumeUuid, inode: metadata.inode)
        )
    }

    private func applyRename(
        fileId: Int64,
        newPath: String,
        crossVolumeIdentity: (volumeUuid: String, inode: Int64)?
    ) async {
        do {
            try await operationEngine.apply(.renameFile(RenameFilePayload(
                fileId: fileId,
                newPath: newPath,
                newVolumeUuid: crossVolumeIdentity?.volumeUuid,
                newInode: crossVolumeIdentity?.inode
            )))
        } catch {
            Self.logger.error(
                "rename mutation for file \(fileId) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
