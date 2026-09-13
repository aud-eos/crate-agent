import CryptoKit
import Foundation

/// A keyed byte cache for AcoustID/MusicBrainz lookup responses, so
/// re-running an auto-tag pass over the same tracks costs zero network.
///
/// The disk-backed variant (`init(directory:)`) is what production uses,
/// rooted under Application Support; `.memory()` backs tests that want a
/// cache with real hit/miss behavior but no filesystem I/O to clean up.
///
/// A miss — key never stored, file deleted out from under us, or
/// unreadable for any other reason — is expected steady-state behavior
/// for a cache, not an error: callers fall back to a network lookup. That
/// is why reads swallow errors (`try?`) and return `nil` instead of
/// throwing; it is not the "no silent failures" rule being bent, because
/// a cache miss isn't a failure.
public final class LookupCache: Sendable {
    private let backend: LookupCacheBackend

    /// - Parameter directory: root directory for cache files, created if
    ///   missing. Callers point this at Application Support in production
    ///   and a temp directory in tests.
    public init(directory: URL, fileManager: FileManager = .default) {
        backend = DiskLookupCacheBackend(directory: directory, fileManager: fileManager)
    }

    private init(backend: LookupCacheBackend) {
        self.backend = backend
    }

    /// In-memory cache for tests: same hit/miss semantics, no disk I/O.
    public static func memory() -> LookupCache {
        LookupCache(backend: MemoryLookupCacheBackend())
    }

    public func data(forKey key: String) -> Data? {
        backend.data(forKey: key)
    }

    public func store(_ data: Data, forKey key: String) {
        backend.store(data, forKey: key)
    }

    /// Evicts a cache entry outright. Used when a cache hit turns out to
    /// be undecodable (corrupt bytes, or bytes written by an older,
    /// incompatible model) — the bad entry must not keep answering every
    /// future lookup for this key with the same failure.
    public func remove(forKey key: String) {
        backend.remove(forKey: key)
    }

    /// Reads a cache hit and decodes it with `decode`. If decoding fails,
    /// the entry is treated as a MISS rather than a permanent failure: it
    /// is evicted here so the caller falls through to a fresh network
    /// fetch instead of replaying the same undecodable bytes forever.
    /// Shared by `AcoustIDClient.lookup` and `MusicBrainzClient.recording`
    /// — both are "decode a cache hit; on failure evict + miss," differing
    /// only in their decode function.
    public func cachedValue<Value>(forKey key: String, decode: (Data) throws -> Value) -> Value? {
        guard let cachedData = data(forKey: key) else { return nil }
        guard let value = try? decode(cachedData) else {
            remove(forKey: key)
            return nil
        }
        return value
    }
}

/// The storage mechanic `LookupCache` delegates to. Kept private: callers
/// only ever see `LookupCache` itself, constructed via `init(directory:)`
/// or `.memory()`.
private protocol LookupCacheBackend: Sendable {
    func data(forKey key: String) -> Data?
    func store(_ data: Data, forKey key: String)
    func remove(forKey key: String)
}

/// `FileManager` itself isn't `Sendable`, but every method here just reads
/// or writes a file at a path and returns/takes `Data` (a value type) — no
/// shared mutable state is exposed across calls, and `FileManager.default`
/// (the only instance production code passes in) is documented as safe
/// for concurrent use.
private final class DiskLookupCacheBackend: LookupCacheBackend, @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager) {
        self.directory = directory
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: fileURL(forKey: key))
    }

    func store(_ data: Data, forKey key: String) {
        try? data.write(to: fileURL(forKey: key), options: .atomic)
    }

    func remove(forKey key: String) {
        try? fileManager.removeItem(at: fileURL(forKey: key))
    }

    /// Logical keys (e.g. `"acoustid:<fingerprint>"`, `"mb:<mbid>"`) can
    /// contain characters that aren't safe filenames, and are also
    /// arbitrary length, so the file on disk is named by the SHA-256 hex
    /// digest of the key rather than the key itself.
    private func fileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hexDigest = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hexDigest)
    }
}

/// Thread-safe in-memory backend. Keys are used as-is — there's no
/// filesystem-safety constraint to hash them away, and readable keys make
/// test failures easier to diagnose.
private final class MemoryLookupCacheBackend: LookupCacheBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    func store(_ data: Data, forKey key: String) {
        lock.withLock { storage[key] = data }
    }

    func remove(forKey key: String) {
        lock.withLock { storage.removeValue(forKey: key) }
    }
}
