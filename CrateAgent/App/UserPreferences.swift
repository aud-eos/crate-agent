import Foundation

/// Thin wrapper over UserDefaults for the small set of preferences
/// crate-agent persists across launches. Currently just the
/// user-chosen music folder; expanded over time as Settings UI lands.
///
/// Reads are synchronous and cheap; writes flush via UserDefaults's
/// own coalescing. No abstraction is layered on top because the goal
/// is exactly "UserDefaults-backed string with a typed accessor" —
/// the type guards against typos in the key string and the URL/Path
/// conversion is centralized.
public enum UserPreferences {

    /// Stored as a path string; converted to URL on read. We don't
    /// use security-scoped bookmarks because the app is not sandboxed
    /// at SP-1 — bookmark roundtripping becomes necessary if/when
    /// App Store distribution lands.
    public static var watchedMusicFolder: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: Key.watchedMusicFolderPath) else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.path, forKey: Key.watchedMusicFolderPath)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.watchedMusicFolderPath)
            }
        }
    }

    /// Resolve the music folder to watch: stored preference takes
    /// precedence; falls back to `~/Music`. Throws only if the
    /// fallback URL itself cannot be resolved (effectively never).
    public static func resolveMusicFolder() throws -> URL {
        if let stored = watchedMusicFolder {
            return stored
        }
        return try FileManager.default.url(
            for: .musicDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }

    enum Key {
        static let watchedMusicFolderPath = "WatchedMusicFolderPath"
    }
}
