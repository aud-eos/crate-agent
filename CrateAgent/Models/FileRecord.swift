import Foundation
import GRDB

/// One row in the `files` table — filesystem-level identity for a
/// single audio file on disk, plus Serato's metadata snapshot for
/// that path.
///
/// Identity fields (path, volumeUuid, inode, hash, fingerprint)
/// describe the file in storage. Metadata fields (artist, title,
/// album, etc.) mirror what Serato has in `database V2` for the
/// same path — populated on initial scan and refreshed when Serato
/// quits (via SeratoSyncCoordinator's reload hook).
public struct FileRecord: Codable, FetchableRecord, MutablePersistableRecord,
    Hashable, Identifiable, Sendable {

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
    /// Audio bitrate in kbps from lofty's audio_bitrate, populated
    /// during indexing. Nil for rows pre-dating the bitrate column
    /// migration (#004) — those get backfilled on the next scan.
    public var bitrateKbps: Int?

    // Serato metadata snapshot. Stored as strings even for numeric
    // fields (`bpm`, `length`) to match Serato's source representation
    // ("128.000", "03:24") and keep the round-trip lossless.
    public var artist: String?
    public var title: String?
    public var album: String?
    public var genre: String?
    public var bpm: String?
    public var musicalKey: String?
    public var comment: String?
    public var length: String?
    public var label: String?

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
        trackId: Int64? = nil,
        bitrateKbps: Int? = nil,
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        bpm: String? = nil,
        musicalKey: String? = nil,
        comment: String? = nil,
        length: String? = nil,
        label: String? = nil
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
        self.bitrateKbps = bitrateKbps
        self.artist = artist
        self.title = title
        self.album = album
        self.genre = genre
        self.bpm = bpm
        self.musicalKey = musicalKey
        self.comment = comment
        self.length = length
        self.label = label
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
