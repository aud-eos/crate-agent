import Foundation

/// Snapshot of every audio-file path Serato currently references in
/// its library — the union of `pfil` entries across `database V2`
/// and `ptrk` entries across every `.crate` file.
///
/// This is **the source of truth for what crate-agent indexes.**
/// Per the project's design pivot, crate-agent does not walk the
/// filesystem looking for tracks; it reads what Serato has and
/// mirrors that set. Adding tracks to the crate-agent library means
/// adding them to Serato's library (either through Serato itself or
/// via crate-agent's drag-drop import flow — the latter lands in a
/// follow-up PR).
///
/// The set is built once per scan and treated as a snapshot. Serato
/// can add or remove references while crate-agent is running; in the
/// worst case a freshly-added Serato track won't be indexed until
/// the next scan. Live watching of `~/Music/_Serato_/` is a later
/// enhancement.
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

    /// The empty set — used when Serato has no library yet (first-
    /// time user) and as a test fixture.
    public static let empty = SeratoLibraryReferenceSet(paths: [])

    private static func absolutePathFromSeratoRelative(_ seratoPath: String) -> String {
        seratoPath.hasPrefix("/") ? seratoPath : "/" + seratoPath
    }
}
