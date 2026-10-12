import Foundation
import GRDB

/// Lightweight projection of a `files` row used by the Library
/// Cleanup panels. Drops BLOB columns (`chromaprint_fingerprint`,
/// `lightweight_hash`) and integer identity fields the hygiene
/// analyzers don't need (`volume_uuid`, `inode`, `file_size`,
/// `mtime`, `track_id`, `bitrate_kbps`, `fingerprint_status`).
///
/// On a 32k-track library each panel's `rescan()` previously paid
/// the full `FileRecord.fetchAll` cost — ~17 MB of BLOB decode plus
/// Codable overhead — every time the user opened a tab or clicked
/// Rescan. `HygieneFileRow` cuts that to just the metadata columns
/// the analyzers and runners actually touch.
///
/// Conforms to `HygieneFileSource` (declared in `LibraryHygiene.swift`)
/// alongside `FileRecord`, so the analyzers + runner are generic
/// over the protocol and accept either type. Tests that pass full
/// `FileRecord` values keep working unchanged.
public struct HygieneFileRow:
    Codable, FetchableRecord, Hashable, Identifiable, Sendable
{

    public static let databaseTableName = "files"
    public static let databaseColumnDecodingStrategy =
        DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public var id: Int64?
    public var membershipRevision: Int64
    public var path: String
    public var artist: String?
    public var title: String?
    public var album: String?
    public var genre: String?
    public var bpm: String?
    public var musicalKey: String?
    public var comment: String?
    public var length: String?
    public var label: String?

    /// Explicit projection SQL so we never accidentally pull BLOBs.
    /// The column list matches the property names (snake_case in SQL,
    /// camelCase in Swift via the decoding strategy above).
    public static let hygieneFetchSQL = """
        SELECT id, membership_revision, path, artist, title, album, genre, bpm, musical_key, comment, length, label
        FROM files
        WHERE \(FileProcessingEligibility.processableSQL)
        """

    public init(
        id: Int64? = nil,
        path: String,
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        bpm: String? = nil,
        musicalKey: String? = nil,
        comment: String? = nil,
        length: String? = nil,
        label: String? = nil,
        membershipRevision: Int64 = 0
    ) {
        self.id = id
        self.membershipRevision = membershipRevision
        self.path = path
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
}
