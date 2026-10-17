import CryptoKit
import Foundation

/// Computes a lightweight content hash used to recognize the same file
/// after a cross-volume move.
///
/// On a same-volume rename, `(inode, volume_uuid)` stays constant — the
/// FilesystemSyncCoordinator catches that case directly. A cross-volume
/// move is really a copy-then-delete, so the new file has a fresh
/// inode on a new volume. We need a cheap content fingerprint that
/// survives the copy.
///
/// Strategy: SHA-256 of the first 1MB followed by the last 1MB. For
/// files smaller than 2MB we hash the whole file. 2MB is a comfortable
/// upper bound — typical DJ audio files are 5–15MB MP3 / 30–80MB
/// lossless, so 1MB head + 1MB tail samples ~10–20% of bytes with the
/// head capturing the codec / metadata frame patterns and the tail
/// capturing the trailing audio bytes. Collisions across distinct
/// audio files are astronomically unlikely; collisions between the
/// same recording at different bitrates ARE expected and intentional
/// — bitrate-equivalent encodings of one recording produce one
/// fingerprint at the chromaprint layer, which is the right grain
/// for cross-volume detection (those are the same file from the
/// user's perspective: a copy).
public enum LightweightHashCalculator {
    /// 1MB read window for each of head and tail.
    public static let windowSize = 1 * 1024 * 1024

    /// Below this size we hash the whole file (head+tail would overlap).
    public static let smallFileThreshold = 2 * 1024 * 1024

    /// Compute the lightweight hash for the file at `path`. Returns
    /// nil for files that can't be opened — the caller treats this as
    /// "no hash available, fall back to inode-only behavior."
    public static func compute(forFileAt path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return compute(reading: handle)
    }

    /// Hash through a handle the caller already opened, so the content read is the
    /// file the caller verified rather than whatever the path names now.
    public static func compute(reading handle: FileHandle) -> Data? {
        LibrarySyncMetrics.current?.record(.hash)
        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            return nil
        }

        var hasher = SHA256()

        if fileSize < UInt64(smallFileThreshold) {
            // Small file: hash the whole thing in one read.
            guard let bytes = try? handle.read(upToCount: Int(fileSize)) else {
                return nil
            }
            hasher.update(data: bytes)
            return Data(hasher.finalize())
        }

        // Head window.
        guard let headBytes = try? handle.read(upToCount: windowSize) else {
            return nil
        }
        hasher.update(data: headBytes)

        // Tail window.
        do {
            try handle.seek(toOffset: fileSize - UInt64(windowSize))
        } catch {
            return nil
        }
        guard let tailBytes = try? handle.read(upToCount: windowSize) else {
            return nil
        }
        hasher.update(data: tailBytes)

        return Data(hasher.finalize())
    }
}
