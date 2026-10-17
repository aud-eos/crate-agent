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
        guard case let .identity(statIdentity) = try observe(at: path) else {
            throw FileTrashLocationError.unverifiable(path: path)
        }
        let recordedHash: Data?
        switch try content(of: statIdentity) {
        case .gone: return nil
        case .unreadable: recordedHash = nil
        case let .hash(hash): recordedHash = hash
        }
        let location = FileMetadata(path: statIdentity.path, volumeUuid: statIdentity.volumeUuid, inode: statIdentity.inode,
                                    fileSize: statIdentity.fileSize, mtime: statIdentity.mtime, lightweightHash: recordedHash)
        try readIdentity.requireUnchanged(at: path)
        let matches = location.lightweightHash == nil
            ? Self.sameStatIdentity(location, file.identity)
            : FileIdentityObservationMutation.matchesContent(file, identity: location)
        return matches ? location : nil
    }

    /// Availability of a row whose indexed path no longer exists. Only a recorded Trash item
    /// that still verifies keeps it trashed; an item that cannot be checked is never taken as
    /// gone. Stat identity is compared first, so a replaced item is missing without being read.
    /// Under the write lock, `comparingContent: false` rechecks only existence and stat identity.
    static func availability(of location: FileMetadata?, resolver: FileAvailabilityResolver, comparingContent: Bool = true) throws -> FileAvailability {
        guard let location else { return .missing }
        switch try resolver.inspect(path: location.path, volumeID: location.volumeUuid) {
        case .trashed:
            switch try observe(at: location.path) {
            case .gone: return .missing
            case .inaccessible: return .inaccessible
            case let .identity(current):
                guard sameStatIdentity(location, current) else { return .missing }
                guard comparingContent, let recordedHash = location.lightweightHash else { return .trashed }
                switch try content(of: current) {
                case .gone: return .missing
                case .unreadable: return .trashed
                case let .hash(currentHash): return currentHash == recordedHash ? .trashed : .missing
                }
            }
        case .offline: return .offline
        case .inaccessible: return .inaccessible
        case .available, .missing, .unknown: return .missing
        }
    }

    /// Availability of a row's own path when it lies in Trash: trashed only while it still holds
    /// the file with this volume and inode, since a path is only a label. An item that cannot
    /// be checked is inaccessible, never taken as gone.
    static func ownPathAvailability(path: String, volumeUuid: String, inode: Int64, resolver: FileAvailabilityResolver) throws -> FileAvailability {
        let resolved = try resolver.inspect(path: path, volumeID: volumeUuid)
        guard resolved == .trashed else { return resolved }
        switch try observe(at: path) {
        case .gone: return .missing
        case .inaccessible: return .inaccessible
        case let .identity(current): return current.volumeUuid == volumeUuid && current.inode == inode ? .trashed : .missing
        }
    }

    private enum Observation {
        case identity(FileMetadata)
        case gone
        case inaccessible
    }

    private enum Content {
        case hash(Data)
        /// Empty, or read permission denied: the stat identity decides.
        case unreadable
        case gone
    }

    /// The item's stat identity, without reading its content.
    private static func observe(at path: String) throws -> Observation {
        if let absence = try absence(at: path) {
            return absence
        }
        guard let metadata = FileMetadataCollector.collect(at: path) else {
            return try absence(at: path) ?? .inaccessible
        }
        return .identity(metadata)
    }

    /// Nil while a regular file is present at `path`.
    private static func absence(at path: String) throws -> Observation? {
        var status = stat()
        guard stat(path, &status) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .gone
            case EACCES, EPERM: return .inaccessible
            default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return status.st_mode & S_IFMT == S_IFREG ? nil : .gone
    }

    /// Hashes through the descriptor it opens, after confirming that descriptor is the
    /// observed item, so a replacement between stat and read is never hashed in its place.
    /// Any failure other than absence or denied permission is an error, not a guess.
    private static func content(of item: FileMetadata) throws -> Content {
        guard item.fileSize > 0 else { return .unreadable }
        let descriptor = open(item.path, O_RDONLY)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .gone
            case EACCES, EPERM: return .unreadable
            default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard Int64(status.st_ino) == item.inode, Int64(status.st_size) == item.fileSize,
              item.hasSameModificationTime(as: StatModificationTime(status)) else { return .gone }
        guard let hash = LightweightHashCalculator.compute(reading: handle) else {
            throw FileTrashLocationError.unverifiable(path: item.path)
        }
        return .hash(hash)
    }

    private static func sameStatIdentity(_ location: FileMetadata, _ current: FileMetadata) -> Bool {
        current.volumeUuid == location.volumeUuid && current.inode == location.inode && current.fileSize == location.fileSize
            && current.hasSameModificationTime(as: location)
    }
}

enum FileTrashLocationError: LocalizedError, Equatable {
    case unverifiable(path: String)
    /// The Trash item a write relied on changed before commit. Row-level staleness: callers
    /// leave the row for the next check instead of failing their batch.
    case itemChanged(fileId: Int64)

    var errorDescription: String? {
        switch self {
        case let .unverifiable(path): "The Trash item at \(path) could not be verified."
        case let .itemChanged(fileId): "The Trash item recorded for file \(fileId) changed before it could be saved; it will be checked again."
        }
    }
}
