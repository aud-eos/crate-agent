import Foundation
import GRDB
import os.log

/// Walks a music folder recursively and indexes every audio file
/// that isn't already in the library database. Used by AppServices
/// on launch to bootstrap the index from existing files — without it,
/// the user's pre-existing library would be invisible to crate-agent
/// until each file got renamed (which is exactly what we're trying
/// to fix).
///
/// The scanner is idempotent: repeated runs skip files already in
/// `files`, so re-running on every launch (or after a folder change)
/// is fast. The first run on a real library walks tens of thousands
/// of files; the bottleneck is filesystem I/O, not DB writes.
///
/// Progress is reported via the per-batch callback so the UI can
/// show "Indexed N of M" during long initial scans. The callback runs
/// on whatever thread Swift concurrency chooses; UI code should hop
/// to MainActor inside the callback if it needs to update state.
public actor LibraryScanner {

    public static let defaultAudioExtensions: Set<String> = FilesystemSyncCoordinator.defaultAudioExtensions

    public struct ScanProgress: Sendable, Equatable {
        public let filesEncountered: Int
        public let filesIndexed: Int
        public let filesSkipped: Int
        public let lastIndexedPath: String?
    }

    public struct ScanResult: Sendable, Equatable {
        public let filesEncountered: Int
        public let filesIndexed: Int
        public let filesSkipped: Int
    }

    public typealias ProgressHandler = @Sendable (ScanProgress) -> Void

    private static let logger = Logger(
        subsystem: "com.crateagent.app",
        category: "LibraryScanner"
    )

    private let operationEngine: OperationEngine
    private let database: LibraryDatabase
    private let audioExtensions: Set<String>

    public init(
        operationEngine: OperationEngine,
        database: LibraryDatabase,
        audioExtensions: Set<String> = LibraryScanner.defaultAudioExtensions
    ) {
        self.operationEngine = operationEngine
        self.database = database
        self.audioExtensions = audioExtensions
    }

    /// Walk `directoryUrl` recursively and index every previously-
    /// unseen audio file. Skips files whose path already exists in
    /// the `files` table (path-based dedup is sufficient for a
    /// startup scan — inode-based cross-volume detection happens via
    /// FSEvents during normal operation).
    ///
    /// Files inside managed libraries (Apple Music, iTunes, Logic)
    /// are skipped UNLESS the supplied `seratoReferenceSet` already
    /// references them — in which case crate-agent needs to know
    /// about them to keep Serato's pointers fresh when the managing
    /// app renames the file.
    ///
    /// Throws only on catastrophic failure (DB unavailable at start).
    /// Per-file errors are logged and the scan continues.
    @discardableResult
    public func scan(
        _ directoryUrl: URL,
        seratoReferenceSet: SeratoLibraryReferenceSet = .empty,
        progress: ProgressHandler? = nil
    ) async throws -> ScanResult {
        Self.logger.info(
            "Starting library scan at \(directoryUrl.path, privacy: .public)"
        )

        // Snapshot known paths up front so we don't query the DB per
        // file during the walk. On a 32k-track library this saves
        // ~32k queries.
        let knownPaths: Set<String> = try await database.writer.read { db in
            let paths = try String.fetchAll(db, sql: "SELECT path FROM files")
            return Set(paths)
        }

        let enumerator = FileManager.default.enumerator(
            at: directoryUrl,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var filesEncountered = 0
        var filesIndexed = 0
        var filesSkipped = 0

        while let fileUrl = enumerator?.nextObject() as? URL {
            let pathExtension = fileUrl.pathExtension.lowercased()
            guard audioExtensions.contains(pathExtension) else { continue }

            let filePath = fileUrl.path

            // Apple Music / iTunes / Logic libraries are managed by
            // other apps. Skip them UNLESS Serato references the file
            // — in which case crate-agent needs to know about it so
            // we can keep Serato's path pointers fresh if the
            // managing app (Apple Music) renames the file later.
            if ManagedLibraryDetector.isInsideManagedLibrary(filePath) {
                guard seratoReferenceSet.contains(filePath) else { continue }
            }

            filesEncountered += 1

            if knownPaths.contains(filePath) {
                filesSkipped += 1
                continue
            }

            guard let metadata = FileMetadataCollector.collect(at: filePath) else {
                Self.logger.warning(
                    "could not stat \(filePath, privacy: .public); skipping"
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
                    mtime: metadata.mtime
                )))
                filesIndexed += 1
            } catch {
                Self.logger.error(
                    "index of \(filePath, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                filesSkipped += 1
                continue
            }

            // Per-file progress updates would deluge the UI; emit
            // batched updates every 50 files for a responsive but
            // not chatty indicator.
            if filesIndexed % 50 == 0 {
                progress?(ScanProgress(
                    filesEncountered: filesEncountered,
                    filesIndexed: filesIndexed,
                    filesSkipped: filesSkipped,
                    lastIndexedPath: filePath
                ))
            }
        }

        // Final progress callback so the UI lands on the real total.
        progress?(ScanProgress(
            filesEncountered: filesEncountered,
            filesIndexed: filesIndexed,
            filesSkipped: filesSkipped,
            lastIndexedPath: nil
        ))

        Self.logger.info(
            "Library scan complete: \(filesEncountered) audio files, \(filesIndexed) newly indexed, \(filesSkipped) skipped"
        )
        return ScanResult(
            filesEncountered: filesEncountered,
            filesIndexed: filesIndexed,
            filesSkipped: filesSkipped
        )
    }
}
