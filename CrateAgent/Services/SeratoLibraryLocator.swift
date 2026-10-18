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
        try ApplicationRuntime.requireLiveResources()
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

    func supportedLibraryIdentity() throws -> String {
        let directory = seratoDirectory.resolvingSymlinksInPath().standardizedFileURL
        let volume = try directory.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsLocalKey])
        guard volume.volumeIsLocal == true, let volumeID = volume.volumeUUIDString else {
            throw SeratoMembershipSnapshotError.unsupportedSource
        }
        return "\(volumeID):\(directory.path.precomposedStringWithCanonicalMapping)"
    }

    /// Serato's play log, read-only: `History/Sessions/*.session`.
    public var historyDirectoryUrl: URL {
        seratoDirectory.appendingPathComponent("History", isDirectory: true)
    }

    public var subcratesDirectoryUrl: URL {
        seratoDirectory.appendingPathComponent("Subcrates", isDirectory: true)
    }

    public var smartCratesDirectoryUrl: URL {
        seratoDirectory.appendingPathComponent("SmartCrates", isDirectory: true)
    }

    /// Enumerate every crate-like file Serato uses to track paths:
    /// `Subcrates/*.crate` (user-curated playlists) AND
    /// `SmartCrates/*.scrate` (rule-based dynamic playlists, which
    /// also store a MATERIALIZED otrk list — when a path is missing
    /// from V2 but present in a smart crate, Serato re-imports it
    /// to V2 on next launch, undoing any V2 rewrite we performed).
    /// Both file formats share the same TLV layout for `otrk`/`ptrk`
    /// records, so `rewrite_path` and `remove_track` operate on
    /// them identically — they just live under different directories.
    /// Results are sorted by path for stable iteration.
    public func enumerateCrateFiles() throws -> [URL] {
        let regular = try enumerateFiles(
            in: subcratesDirectoryUrl,
            extension: "crate"
        )
        let smart = try enumerateFiles(
            in: smartCratesDirectoryUrl,
            extension: "scrate"
        )
        return (regular + smart).sorted(by: { lhs, rhs in lhs.path < rhs.path })
    }

    private func enumerateFiles(
        in directory: URL,
        extension fileExtension: String
    ) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        let allFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return allFiles.filter { $0.pathExtension == fileExtension }
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
