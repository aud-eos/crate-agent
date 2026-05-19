import Foundation

/// Snapshot of every audio-file path Serato currently references in
/// its library — the union of `pfil` entries across `database V2`
/// and `ptrk` entries across every `.crate` file. Used to decide
/// whether a file that lives inside a managed library (Apple Music,
/// iTunes, Logic) should still be indexed by crate-agent because
/// Serato itself depends on it.
///
/// The set is built once per scan and treated as a snapshot. Serato
/// can add or remove references while crate-agent is running; in
/// the worst case a freshly-added Apple Music track that Serato now
/// references won't be indexed until the next scan. This is an
/// acceptable freshness trade-off for SP-1 — refreshing on Serato
/// library file changes is a later refinement.
public struct SeratoLibraryReferenceSet: Sendable, Equatable {

    public let paths: Set<String>

    public init(paths: Set<String>) {
        self.paths = paths
    }

    /// Read every `.crate` file in `locator.subcratesDirectoryUrl`
    /// and the `database V2` file, decode their referenced paths,
    /// and assemble them into the absolute-path form crate-agent
    /// stores in its `files` table.
    ///
    /// Serato stores paths in volume-relative form (`Users/x/Music/...`)
    /// — we prepend a leading slash so the entries match the
    /// absolute paths crate-agent uses everywhere else.
    public static func collect(from locator: SeratoLibraryLocator) throws -> SeratoLibraryReferenceSet {
        var collected: Set<String> = []

        let databaseV2Path = locator.databaseV2Url.path
        if FileManager.default.fileExists(atPath: databaseV2Path) {
            let dbPaths = try readDatabasePaths(databasePath: databaseV2Path)
            collected.formUnion(dbPaths.map(absolutePathFromSeratoRelative))
        }

        let crateFiles = try locator.enumerateCrateFiles()
        for crateFile in crateFiles {
            let cratePaths = try readCratePaths(cratePath: crateFile.path)
            collected.formUnion(cratePaths.map(absolutePathFromSeratoRelative))
        }

        return SeratoLibraryReferenceSet(paths: collected)
    }

    /// Async wrapper around `collect(from:)` to keep the (potentially
    /// slow on a 25MB database V2) FFI work off whichever isolation
    /// domain the caller lives on.
    public static func collectInBackground(
        from locator: SeratoLibraryLocator
    ) async throws -> SeratoLibraryReferenceSet {
        try await Task.detached(priority: .userInitiated) {
            try collect(from: locator)
        }.value
    }

    public func contains(_ absolutePath: String) -> Bool {
        paths.contains(absolutePath)
    }

    /// The empty set — useful in tests and as a fallback when no
    /// Serato library is present (first-time user). The scanner
    /// treats this as "Serato references nothing," so any file in a
    /// managed library is skipped.
    public static let empty = SeratoLibraryReferenceSet(paths: [])

    private static func absolutePathFromSeratoRelative(_ seratoPath: String) -> String {
        seratoPath.hasPrefix("/") ? seratoPath : "/" + seratoPath
    }
}
