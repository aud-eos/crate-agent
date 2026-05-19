import Foundation

/// Identifies filesystem paths managed by another macOS application
/// — Apple Music, legacy iTunes, Logic Pro audio assets — that
/// crate-agent must not index or modify by default.
///
/// Rationale: those apps store their library data alongside the
/// audio files (Apple Music's `Library.musiclibrary` package, the
/// legacy `iTunes Library.itl`) and assume they are the sole writer
/// of those paths. Renaming or moving files inside their libraries
/// breaks their references and surfaces "missing track" errors.
/// crate-agent is meant to operate on the user's own DJ library, not
/// to fight other media managers for the same data.
///
/// Users who want to work with a track that lives inside a managed
/// library should copy it to a non-managed location first; that copy
/// workflow lands as a follow-up UI feature.
public enum ManagedLibraryDetector {

    /// Subpaths (relative to the user's home directory) that
    /// crate-agent will not index or modify. Hard-coded list — these
    /// locations are well-defined macOS conventions, not user
    /// configuration. Order isn't significant; matching is by prefix.
    public static let defaultExcludedSubpaths: [String] = [
        "Music/Music/Media",          // Apple Music (macOS 10.15+)
        "Music/Music/Music",          // Older Apple Music layout
        "Music/iTunes/iTunes Media",  // Legacy iTunes (most common)
        "Music/iTunes/iTunes Music",  // Very legacy iTunes
        "Music/Audio Music Apps",     // Logic Pro / GarageBand assets
        "Music/Audio Hijack",         // Audio Hijack recordings cache
        "Music/GarageBand",           // GarageBand projects + samples
    ]

    /// Returns true if `path` is inside any managed library path on
    /// disk for the given home directory. Matching is prefix-based
    /// (`hasPrefix(managedPath + "/")` or exact `==`), so files at
    /// or under the managed location are excluded but a sibling
    /// folder with a similar name is not.
    public static func isInsideManagedLibrary(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let managedAbsolutePaths = fullExcludedPaths(homeDirectory: homeDirectory)
        for managedPath in managedAbsolutePaths {
            if path == managedPath || path.hasPrefix(managedPath + "/") {
                return true
            }
        }
        return false
    }

    /// Absolute filesystem paths for every managed library location.
    /// Used by the SQL purge migration to delete already-indexed rows
    /// and by tests that need to reason about the full path set.
    public static func fullExcludedPaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        defaultExcludedSubpaths.map { subpath in
            homeDirectory.appendingPathComponent(subpath, isDirectory: true).path
        }
    }
}
