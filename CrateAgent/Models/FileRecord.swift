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
    public var libraryMembership: LibraryMembership = .legacyUnverified
    public var fileAvailability: FileAvailability = .unknown
    public var seratoLibraryId: String?
    public var retiredAt: Int64?
    public var membershipRevision: Int64 = 0

    public var libraryState: FileLibraryState {
        FileLibraryState(membership: libraryMembership, availability: fileAvailability, libraryID: seratoLibraryId, retiredAt: retiredAt)
    }

    public var path: String
    public var volumeUuid: String
    public var inode: Int64
    public var fileSize: Int64
    public var mtime: Int64
    public var lightweightHash: Data?
    public var chromaprintFingerprint: Data?
    public var fingerprintStatus: FingerprintStatus
    /// The file's on-disk size + mtime at the moment its current
    /// `chromaprintFingerprint` was computed — the freshness basis the
    /// auto-tagger compares the live file against before trusting a stored
    /// fingerprint for a lookup. Written whenever the fingerprint is
    /// (re)computed on demand (`AutoTaggerService`), so a recompute no longer
    /// leaves the basis pinned to the stale index snapshot (which made every
    /// later scan of an edited file re-decode its audio forever). Nil for rows
    /// fingerprinted before migration #009 or by the background worker;
    /// callers fall back to `fileSize`/`mtime` (the index-time snapshot, which
    /// for those rows IS the fingerprint's basis) when these are nil.
    public var fingerprintedSize: Int64?
    public var fingerprintedMtime: Int64?
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
        fingerprintedSize: Int64? = nil,
        fingerprintedMtime: Int64? = nil,
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
        self.fingerprintedSize = fingerprintedSize
        self.fingerprintedMtime = fingerprintedMtime
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

    /// Whether any file OTHER than `excludingFileId` links to `trackId`.
    /// The shared reference-count probe behind both the D-C collision guard
    /// (in `applyMusicBrainzMatch`) and the reference-aware undo teardown
    /// (in `applyRevertMusicBrainzMatch`): a fingerprint-keyed track row
    /// (invariant #4) may be shared by FLAC+MP3 of one recording, so both
    /// paths must know whether another file still depends on it.
    public static func hasOtherFilesReferencingTrack(
        _ trackId: Int64?,
        excluding excludingFileId: Int64,
        in db: GRDB.Database
    ) throws -> Bool {
        try FileRecord
            .filter(Column("track_id") == trackId && Column("id") != excludingFileId)
            .fetchCount(db) > 0
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
