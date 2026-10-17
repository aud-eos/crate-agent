import Darwin
import Foundation

enum LegacyFileIdentity {
    static let unknownVolume = "unknown-volume"

    static func canAdoptVolume(_ file: FileRecord, identity: FileMetadata) -> Bool {
        file.volumeUuid == unknownVolume && identity.volumeUuid != unknownVolume
            && FileImportIdentity.matchesAttributes(file, identity: identity)
    }
}

/// File-level identity metadata extracted from a path on disk: the
/// fields needed to populate `FileRecord` plus the inode used by the
/// FilesystemSyncCoordinator's rename-detection lookups.
///
/// Wrapped in its own type so both the FSEvents-driven flow and the
/// LibraryScanner walk share a single source of truth for "given a
/// path, what metadata do we record?" Adding a new field here (e.g.,
/// lightweight content hash for cross-volume move detection) lights
/// up both call sites at once.
public struct FileMetadata: Codable, Sendable, Equatable {
    public let path: String
    public let volumeUuid: String
    public let inode: Int64
    public let fileSize: Int64
    public let mtime: Int64
    /// Optional because callers that don't care about cross-volume
    /// move detection skip the disk read. Nil when omitted or when
    /// the hash couldn't be computed (unreadable file, etc.).
    public let lightweightHash: Data?

    public init(
        path: String,
        volumeUuid: String,
        inode: Int64,
        fileSize: Int64,
        mtime: Int64,
        lightweightHash: Data? = nil
    ) {
        self.path = path
        self.volumeUuid = volumeUuid
        self.inode = inode
        self.fileSize = fileSize
        self.mtime = mtime
        self.lightweightHash = lightweightHash
    }
}

/// Audio paths may be links. Keep both their directory entry and regular target
/// stable across a read; database V2 deliberately uses the stricter lstat check.
public struct AudioFileReadIdentity: Codable, Equatable, Sendable {
    let entry: SeratoSourceIdentity
    let target: SeratoSourceIdentity
    let resolvedPath: String

    static func read(at path: String) throws -> Self {
        var entry = stat()
        var target = stat()
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard lstat(path, &entry) == 0, stat(path, &target) == 0 else {
            let failure = errno
            switch failure {
            case ENOENT, ENOTDIR: throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
            case EACCES, EPERM: throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
            default: throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO, userInfo: [NSFilePathErrorKey: path])
            }
        }
        guard target.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: path])
        }
        guard resolved == URL(fileURLWithPath: path).resolvingSymlinksInPath().path else {
            throw SeratoMembershipSnapshotError.sourceChanged
        }
        return Self(entry: SeratoSourceIdentity(entry), target: SeratoSourceIdentity(target), resolvedPath: resolved)
    }

    func requireUnchanged(at path: String) throws {
        guard try self == Self.read(at: path) else { throw SeratoMembershipSnapshotError.sourceChanged }
    }
}

public enum FileMetadataCollector {
    static func collectVerified(at path: String) throws -> FileMetadata {
        let before = try AudioFileReadIdentity.read(at: path)
        guard let metadata = collect(at: path, includeLightweightHash: true), metadata.lightweightHash != nil
        else {
            throw SeratoMembershipSnapshotError.sourceChanged
        }
        try before.requireUnchanged(at: path)
        return metadata
    }

    /// Read metadata for the file at `path`. Returns nil when the
    /// file doesn't exist, isn't stat-able (permissions, broken
    /// symlink, etc.), or the volume identifier is unavailable. The
    /// caller is responsible for handling "skip this file" vs.
    /// "abort the operation" semantics.
    ///
    /// `includeLightweightHash` controls whether to spend the I/O to
    /// compute the cross-volume-move fingerprint. The indexing paths
    /// (LibraryScanner, ImportCoordinator) pass `true`; FSEvents-
    /// driven rename lookups also pass `true` to enable hash-based
    /// fallback. Tests can pass `false` to keep stat-only behavior.
    public static func collect(
        at path: String,
        includeLightweightHash: Bool = false
    ) -> FileMetadata? {
        var statBuffer = stat()
        guard stat(path, &statBuffer) == 0, statBuffer.st_mode & S_IFMT == S_IFREG else { return nil }

        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let volumeUuidString = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?
            .volumeUUIDString else { return nil }

        let hash = includeLightweightHash
            ? LightweightHashCalculator.compute(forFileAt: path)
            : nil

        return FileMetadata(
            path: path,
            volumeUuid: volumeUuidString,
            inode: Int64(statBuffer.st_ino),
            fileSize: Int64(statBuffer.st_size),
            mtime: Int64(statBuffer.st_mtimespec.tv_sec),
            lightweightHash: hash
        )
    }
}
