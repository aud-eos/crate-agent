import Darwin
import Foundation

/// File-level identity metadata extracted from a path on disk: the
/// fields needed to populate `FileRecord` plus the inode used by the
/// FilesystemSyncCoordinator's rename-detection lookups.
///
/// Wrapped in its own type so both the FSEvents-driven flow and the
/// LibraryScanner walk share a single source of truth for "given a
/// path, what metadata do we record?" Adding a new field here (e.g.,
/// lightweight content hash for cross-volume move detection) lights
/// up both call sites at once.
public struct FileMetadata: Sendable, Equatable {
    public let path: String
    public let volumeUuid: String
    public let inode: Int64
    public let fileSize: Int64
    public let mtime: Int64

    public init(
        path: String,
        volumeUuid: String,
        inode: Int64,
        fileSize: Int64,
        mtime: Int64
    ) {
        self.path = path
        self.volumeUuid = volumeUuid
        self.inode = inode
        self.fileSize = fileSize
        self.mtime = mtime
    }
}

public enum FileMetadataCollector {

    /// Read metadata for the file at `path`. Returns nil when the
    /// file doesn't exist, isn't stat-able (permissions, broken
    /// symlink, etc.), or the volume identifier is unavailable. The
    /// caller is responsible for handling "skip this file" vs.
    /// "abort the operation" semantics.
    public static func collect(at path: String) -> FileMetadata? {
        var statBuffer = stat()
        guard stat(path, &statBuffer) == 0 else { return nil }

        let url = URL(fileURLWithPath: path)
        let volumeUuidString = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?
            .volumeUUIDString ?? "unknown-volume"

        return FileMetadata(
            path: path,
            volumeUuid: volumeUuidString,
            inode: Int64(statBuffer.st_ino),
            fileSize: Int64(statBuffer.st_size),
            mtime: Int64(statBuffer.st_mtimespec.tv_sec)
        )
    }
}
