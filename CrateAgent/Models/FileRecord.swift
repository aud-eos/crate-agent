import Foundation
import GRDB

/// One row in the `files` table — filesystem-level identity for a
/// single audio file on disk.
///
/// File identity is path + volume + inode + lightweight hash. Track
/// identity (Chromaprint fingerprint, MBID) lives in `TrackRecord`;
/// this row links to it via `trackId` once fingerprinting resolves.
public struct FileRecord: Codable, FetchableRecord, MutablePersistableRecord,
    Hashable, Identifiable {

    public static let databaseTableName = "files"
    public static let databaseColumnDecodingStrategy =
        DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy =
        DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var path: String
    public var volumeUuid: String
    public var inode: Int64
    public var fileSize: Int64
    public var mtime: Int64
    public var lightweightHash: Data?
    public var chromaprintFingerprint: Data?
    public var fingerprintStatus: FingerprintStatus
    public var trackId: Int64?

    public init(
        id: Int64? = nil,
        path: String,
        volumeUuid: String,
        inode: Int64,
        fileSize: Int64,
        mtime: Int64,
        lightweightHash: Data? = nil,
        chromaprintFingerprint: Data? = nil,
        fingerprintStatus: FingerprintStatus = .pending,
        trackId: Int64? = nil
    ) {
        self.id = id
        self.path = path
        self.volumeUuid = volumeUuid
        self.inode = inode
        self.fileSize = fileSize
        self.mtime = mtime
        self.lightweightHash = lightweightHash
        self.chromaprintFingerprint = chromaprintFingerprint
        self.fingerprintStatus = fingerprintStatus
        self.trackId = trackId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// State of the background fingerprinting pipeline for a given file.
/// Stored as a TEXT column to keep schema browseable; the enum value
/// is the source of truth in Swift.
public enum FingerprintStatus: String, Codable, DatabaseValueConvertible,
    Hashable, Sendable {
    case pending
    case done
    case failed
}
