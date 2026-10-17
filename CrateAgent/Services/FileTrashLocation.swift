import Foundation
import GRDB

/// The verified native Trash item of a file whose indexed path is deliberately retained.
/// Only this record can prove that a trashed row's audio still exists.
enum FileTrashLocation {
    static func load(fileID: Int64, in database: GRDB.Database) throws -> FileMetadata? {
        guard let identity = try Data.fetchOne(database, sql: "SELECT identity FROM file_trash_locations WHERE file_id = ?",
                                               arguments: [fileID]) else { return nil }
        return try JSONDecoder().decode(FileMetadata.self, from: identity)
    }

    static func store(_ location: FileMetadata?, fileID: Int64, in database: GRDB.Database) throws {
        guard let location else {
            try database.execute(sql: "DELETE FROM file_trash_locations WHERE file_id = ?", arguments: [fileID])
            return
        }
        try database.execute(sql: "INSERT OR REPLACE INTO file_trash_locations (file_id, path, identity) VALUES (?, ?, ?)",
                             arguments: [fileID, lookupKey(location.path), JSONEncoder().encode(location)])
    }

    static func fileIDs(at path: String, in database: GRDB.Database) throws -> [Int64] {
        try Int64.fetchAll(database, sql: "SELECT file_id FROM file_trash_locations WHERE path = ?", arguments: [lookupKey(path)])
    }

    /// Removal events name the Trash item exactly as it was delivered. URL standardization is
    /// unusable here because it rewrites `/private/tmp` only while the item still exists.
    private static func lookupKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    /// The verified identity of `file`'s item in Trash, or nil when that item is not `file`.
    /// Without Full Disk Access, Trash items can be stat-able but unreadable; such an item
    /// is recorded by its stat identity alone instead of failing the observation. That
    /// identity relies on APFS/HFS+ file IDs, which are never reused; msdosfs IDs can be.
    static func capture(at path: String, for file: FileRecord) throws -> FileMetadata? {
        let readIdentity = try AudioFileReadIdentity.read(at: path)
        guard case let .identity(location) = try observe(at: path, hashing: true) else {
            throw FileTrashLocationError.unverifiable(path: path)
        }
        try readIdentity.requireUnchanged(at: path)
        let matches = location.lightweightHash == nil
            ? file.fileSize == location.fileSize && file.inode == location.inode && file.volumeUuid == location.volumeUuid
            && file.mtime == location.mtime
            : FileIdentityObservationMutation.matchesContent(file, identity: location)
        return matches ? location : nil
    }

    /// Availability of a row whose indexed path no longer exists. Only a recorded Trash item
    /// that still verifies keeps it trashed; an item that cannot be checked is never taken as gone.
    static func availability(of location: FileMetadata?, resolver: FileAvailabilityResolver) throws -> FileAvailability {
        guard let location else { return .missing }
        switch try resolver.inspect(path: location.path, volumeID: location.volumeUuid) {
        case .trashed:
            switch try observe(at: location.path, hashing: location.lightweightHash != nil) {
            case let .identity(current): return stillIdentifies(location, current: current) ? .trashed : .missing
            case .gone: return .missing
            case .inaccessible: return .inaccessible
            }
        case .offline: return .offline
        case .inaccessible: return .inaccessible
        case .available, .missing, .unknown: return .missing
        }
    }

    private enum Observation {
        case identity(FileMetadata)
        case gone
        case inaccessible
    }

    /// Hashes the item only when it can be opened; denied read permission yields a stat-only
    /// identity, and any other read failure is an error rather than a guess.
    private static func observe(at path: String, hashing: Bool) throws -> Observation {
        var status = stat()
        guard stat(path, &status) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .gone
            case EACCES, EPERM: return .inaccessible
            default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard status.st_mode & S_IFMT == S_IFREG else { return .gone }
        let readable = hashing ? try canOpen(path) : false
        guard let metadata = FileMetadataCollector.collect(at: path, includeLightweightHash: readable) else { return .inaccessible }
        guard !readable || metadata.lightweightHash != nil else { throw FileTrashLocationError.unverifiable(path: path) }
        return .identity(metadata)
    }

    private static func canOpen(_ path: String) throws -> Bool {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            if errno == EACCES || errno == EPERM {
                return false
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        close(descriptor)
        return true
    }

    /// Compares only what was captured: a content hash that can no longer be read is a
    /// permission failure, so the stat identity decides.
    private static func stillIdentifies(_ location: FileMetadata, current: FileMetadata) -> Bool {
        guard current.volumeUuid == location.volumeUuid, current.inode == location.inode, current.fileSize == location.fileSize,
              current.mtime == location.mtime else { return false }
        guard let recordedHash = location.lightweightHash, let currentHash = current.lightweightHash else { return true }
        return recordedHash == currentHash
    }
}

enum FileTrashLocationError: LocalizedError, Equatable {
    case unverifiable(path: String)

    var errorDescription: String? {
        switch self {
        case let .unverifiable(path): "The Trash item at \(path) could not be verified."
        }
    }
}
