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

    /// Availability of a trashed row whose indexed path no longer exists.
    static func availability(of location: FileMetadata?, resolver: FileAvailabilityResolver) throws -> FileAvailability {
        guard let location else { return .missing }
        switch try resolver.inspect(path: location.path, volumeID: location.volumeUuid) {
        case .trashed:
            return FileMetadataCollector.collect(at: location.path, includeLightweightHash: true) == location ? .trashed : .missing
        case .offline: return .offline
        case .inaccessible: return .inaccessible
        case .available, .missing, .unknown: return .missing
        }
    }
}
