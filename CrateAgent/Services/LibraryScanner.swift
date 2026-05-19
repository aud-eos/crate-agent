import Foundation
import GRDB
import os.log

/// Hydrates the local files table from Serato's library. Serato is
/// the source of truth — crate-agent only knows about tracks Serato
/// references. The scanner reads `database V2` plus every `.crate`,
/// diffs against the current `files` table, and indexes the set of
/// paths Serato has that crate-agent doesn't yet.
///
/// Adding tracks to crate-agent's library means adding them to
/// Serato's library first (either via Serato directly or via the
/// drag-drop import flow, landing in a follow-up PR). The scanner
/// itself never walks the filesystem looking for arbitrary audio
/// files.
///
/// Idempotent: running the scanner repeatedly only inserts newly-
/// appearing Serato references. Tracks Serato has removed are not
/// (yet) removed from the local table — that's a sync-direction
/// question for a later refinement.
public actor LibraryScanner {

    public struct ScanProgress: Sendable, Equatable {
        /// Total paths Serato references in its library.
        public let seratoReferenceCount: Int
        /// Paths newly inserted into the local DB this scan.
        public let filesIndexed: Int
        /// Paths Serato references that are missing on disk or
        /// couldn't be stat'd; logged but otherwise skipped.
        public let filesSkipped: Int
        public let lastIndexedPath: String?
    }

    public struct ScanResult: Sendable, Equatable {
        public let seratoReferenceCount: Int
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

    /// Read Serato's library, diff against the local DB, and index
    /// any newly-referenced tracks. The optional `progress` callback
    /// fires every 50 indexed files plus once at the end.
    ///
    /// Throws only on catastrophic failure (DB unavailable, Serato
    /// library unreadable). Per-file errors are logged and the scan
    /// continues so a single broken file doesn't abort the whole run.
    @discardableResult
    public func scan(progress: ProgressHandler? = nil) async throws -> ScanResult {
        Self.logger.info("Starting Serato library scan")

        let referenceSet = try await SeratoLibraryReferenceSet.collectInBackground(
            from: seratoLocator
        )
        Self.logger.info(
            "Serato references \(referenceSet.paths.count, privacy: .public) paths"
        )

        let knownPaths: Set<String> = try await database.writer.read { db in
            let paths = try String.fetchAll(db, sql: "SELECT path FROM files")
            return Set(paths)
        }

        // Paths Serato has but crate-agent doesn't — the work to do.
        // Sorted so iteration order is stable across runs (helps with
        // debug log readability and progress monotonicity).
        let pathsToIndex = referenceSet.paths
            .subtracting(knownPaths)
            .sorted()

        var filesIndexed = 0
        var filesSkipped = 0

        for filePath in pathsToIndex {
            guard let metadata = FileMetadataCollector.collect(at: filePath) else {
                Self.logger.warning(
                    "Serato references \(filePath, privacy: .public) but the file is missing or unreadable; skipping"
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
                    "Index of \(filePath, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                filesSkipped += 1
                continue
            }

            if filesIndexed % 50 == 0 {
                progress?(ScanProgress(
                    seratoReferenceCount: referenceSet.paths.count,
                    filesIndexed: filesIndexed,
                    filesSkipped: filesSkipped,
                    lastIndexedPath: filePath
                ))
            }
        }

        progress?(ScanProgress(
            seratoReferenceCount: referenceSet.paths.count,
            filesIndexed: filesIndexed,
            filesSkipped: filesSkipped,
            lastIndexedPath: nil
        ))

        Self.logger.info(
            "Library scan complete: \(filesIndexed) newly indexed, \(filesSkipped) skipped, \(referenceSet.paths.count) Serato references total"
        )
        return ScanResult(
            seratoReferenceCount: referenceSet.paths.count,
            filesIndexed: filesIndexed,
            filesSkipped: filesSkipped
        )
    }
}
