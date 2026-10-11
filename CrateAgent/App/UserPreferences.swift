import CoreServices
import Foundation

public enum UserPreferences {
    private static var store: PreferencesStore {
        do { return try PreferencesStore.live() }
        catch { preconditionFailure("Live preferences are unavailable in tests: \(error)") }
    }

    public static var watchedMusicFolder: URL? {
        get { store.watchedMusicFolder }
        set { store.watchedMusicFolder = newValue }
    }

    public static var filenameTemplate: String {
        get { store.filenameTemplate }
        set { store.filenameTemplate = newValue }
    }

    public static func lastFSEventId(forWatchedPath path: String) -> FSEventStreamEventId? {
        store.lastFSEventId(forWatchedPath: path)
    }

    public static func setLastFSEventId(_ eventId: FSEventStreamEventId, forWatchedPath path: String) {
        store.setLastFSEventId(eventId, forWatchedPath: path)
    }

    /// Resolve the music folder to watch: stored preference takes
    /// precedence; falls back to the opinionated default
    /// (`defaultLibraryRoot`). Throws only if the fallback URL
    /// itself cannot be resolved (effectively never).
    public static func resolveMusicFolder() throws -> URL {
        if let stored = watchedMusicFolder {
            return stored
        }
        return try defaultLibraryRoot()
    }

    /// Opinionated default location for a fresh install:
    /// `~/Music/_DJ_Library_/`. Underscore-bracketed to match
    /// Serato's `_Serato_` convention — sorts to the top of
    /// `~/Music/` and visually telegraphs "managed by the tool,
    /// don't reorganize by hand."
    ///
    /// The directory is NOT created here — callers that pick this
    /// as the destination (onboarding "Use default" button,
    /// migration sheet) are responsible for `createDirectory`
    /// at the point of use so the side effect is visible.
    public static let defaultLibraryFolderName: String = "_DJ_Library_"

    public static func defaultLibraryRoot() throws -> URL {
        let musicDirectory = try FileManager.default.url(
            for: .musicDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return musicDirectory.appendingPathComponent(
            defaultLibraryFolderName,
            isDirectory: true
        )
    }

    /// Default template used by the manual rename dialog. Beets-style
    /// `$field` syntax; see FilenameTemplateEngine. The user-saved
    /// override (if any) takes precedence; both forms always include
    /// the extension via `$ext` so renames don't accidentally drop it.
    public static let defaultFilenameTemplate = "$artist - $title.$ext"
}

struct PreferencesStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        precondition(!ApplicationRuntime.isTesting || defaults !== UserDefaults.standard,
                     "Tests must inject isolated preferences")
        self.defaults = defaults
    }

    static func live() throws -> PreferencesStore {
        try ApplicationRuntime.requireLiveResources()
        return PreferencesStore(defaults: .standard)
    }

    /// Stored as a path string; converted to URL on read. We don't
    /// use security-scoped bookmarks because the app is not sandboxed
    /// at SP-1 — bookmark roundtripping becomes necessary if/when
    /// App Store distribution lands.
    var watchedMusicFolder: URL? {
        get {
            guard let path = defaults.string(forKey: Key.watchedMusicFolderPath) else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.path, forKey: Key.watchedMusicFolderPath)
            } else {
                defaults.removeObject(forKey: Key.watchedMusicFolderPath)
            }
        }
    }

    /// Last FSEvents event ID we successfully processed for the
    /// given watched-folder path. Used as the `sinceWhen` argument on
    /// next launch so events that fire while crate-agent is closed
    /// are replayed rather than silently lost. Keyed by path so that
    /// changing the watched folder doesn't replay events from the
    /// old folder against the new one.
    func lastFSEventId(forWatchedPath path: String) -> FSEventStreamEventId? {
        let key = Key.lastFSEventIdPrefix + path
        guard let stored = defaults.object(forKey: key) as? UInt64 else {
            return nil
        }
        return FSEventStreamEventId(stored)
    }

    func setLastFSEventId(
        _ eventId: FSEventStreamEventId,
        forWatchedPath path: String
    ) {
        let key = Key.lastFSEventIdPrefix + path
        defaults.set(UInt64(eventId), forKey: key)
    }

    var filenameTemplate: String {
        get {
            defaults.string(forKey: Key.filenameTemplate)
                ?? UserPreferences.defaultFilenameTemplate
        }
        nonmutating set {
            defaults.set(newValue, forKey: Key.filenameTemplate)
        }
    }

    enum Key {
        static let watchedMusicFolderPath = "WatchedMusicFolderPath"
        static let lastFSEventIdPrefix = "LastFSEventId:"
        static let filenameTemplate = "FilenameTemplate"
    }
}
