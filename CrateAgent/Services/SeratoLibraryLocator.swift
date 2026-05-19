import Foundation

/// Resolves the paths of Serato's library files on disk. The default
/// location is `~/Music/_Serato_/`; tests inject a custom URL.
///
/// Scope cap for SP-1: only the home-directory `_Serato_/` is handled.
/// Per-drive `_Serato_/` folders on external volumes (for portable
/// library workflows) are out of scope until Pillar E lands.
public struct SeratoLibraryLocator: Sendable, Equatable {

    /// Folder containing the `database V2` file and the `Subcrates/`
    /// directory. For a default install this is
    /// `/Users/<user>/Music/_Serato_/`.
    public let seratoDirectory: URL

    public init(seratoDirectory: URL) {
        self.seratoDirectory = seratoDirectory
    }

    /// Locator pointing at `~/Music/_Serato_/`. Does not verify that
    /// the directory exists — callers should handle missing-library
    /// cases (e.g., Serato has never run on this machine).
    public static func defaultLocation() throws -> SeratoLibraryLocator {
        let musicFolderUrl = try FileManager.default.url(
            for: .musicDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return SeratoLibraryLocator(
            seratoDirectory: musicFolderUrl.appendingPathComponent("_Serato_", isDirectory: true)
        )
    }

    public var databaseV2Url: URL {
        seratoDirectory.appendingPathComponent("database V2", isDirectory: false)
    }

    public var subcratesDirectoryUrl: URL {
        seratoDirectory.appendingPathComponent("Subcrates", isDirectory: true)
    }

    /// Enumerate every `.crate` file in `Subcrates/`. Returns an empty
    /// array if the directory does not exist (Serato has never created
    /// any crates) — this is a normal first-run state, not an error.
    /// Results are sorted by URL to give stable iteration order.
    public func enumerateCrateFiles() throws -> [URL] {
        let subcratesDirectoryPath = subcratesDirectoryUrl.path
        guard FileManager.default.fileExists(atPath: subcratesDirectoryPath) else {
            return []
        }
        let allFiles = try FileManager.default.contentsOfDirectory(
            at: subcratesDirectoryUrl,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return allFiles
            .filter { $0.pathExtension == "crate" }
            .sorted(by: { lhs, rhs in lhs.path < rhs.path })
    }

    /// Convert an absolute filesystem path to the relative form Serato
    /// stores in its library files. For files on the boot volume, this
    /// is the absolute path with the leading slash stripped — e.g.,
    /// `/Users/benny/Music/A/Track.mp3` becomes
    /// `Users/benny/Music/A/Track.mp3`.
    public static func seratoRelativePath(fromAbsolute absolutePath: String) -> String {
        absolutePath.hasPrefix("/") ? String(absolutePath.dropFirst()) : absolutePath
    }
}
