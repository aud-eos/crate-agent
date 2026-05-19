import Foundation
import GRDB

/// Lightweight projection of a `files` row carrying only the columns
/// the library browser actually renders. Used by `LibraryBrowserView`'s
/// ValueObservation in place of full `FileRecord` decoding.
///
/// Why this exists: `FileRecord.fetchAll` returns every column,
/// including the `chromaprint_fingerprint` BLOB (~500 bytes/row) and
/// `lightweight_hash` BLOB (32 bytes/row). On a 32k-track library
/// that's ~17 MB of bytes per ValueObservation emission, plus the
/// Codable decode cost. Every FingerprintWorker batch fired the
/// observation and the resulting per-emission cost beach-balled the
/// UI even after #29's batched writes throttled the emission rate.
///
/// `BrowserRow` keeps only what the Table actually shows:
/// id + path + display metadata. Decode is dramatically lighter,
/// SwiftUI's update cycle stays responsive during heavy worker
/// activity.
///
/// Code paths that need the full record (rename dialog, hygiene
/// runners, mutations) still operate on `FileRecord` — they fetch
/// by id at the point of use.
public struct BrowserRow:
    Codable, FetchableRecord, Hashable, Identifiable, Sendable
{

    public static let databaseTableName = "files"
    public static let databaseColumnDecodingStrategy =
        DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public var id: Int64
    public var path: String
    public var artist: String?
    public var title: String?
    public var album: String?
    public var bpm: String?
    public var musicalKey: String?

    // MARK: - Display helpers

    public var filenameOnly: String {
        (path as NSString).lastPathComponent
    }

    public var folderPath: String {
        (path as NSString).deletingLastPathComponent
    }

    /// SwiftUI's `KeyPathComparator` needs a `Comparable` value;
    /// Optional<String> isn't Comparable. These projections return
    /// "" for nil so nil sorts first alphabetically.
    public var artistOrEmpty: String { artist ?? "" }
    public var titleOrEmpty: String { title ?? "" }
    public var albumOrEmpty: String { album ?? "" }
    public var bpmOrEmpty: String { bpm ?? "" }
    public var musicalKeyOrEmpty: String { musicalKey ?? "" }

    public init(
        id: Int64,
        path: String,
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        bpm: String? = nil,
        musicalKey: String? = nil
    ) {
        self.id = id
        self.path = path
        self.artist = artist
        self.title = title
        self.album = album
        self.bpm = bpm
        self.musicalKey = musicalKey
    }
}

extension BrowserRow {
    /// Explicit projection query so we never accidentally pull the
    /// BLOB columns. The column list mirrors the struct's properties
    /// (snake_case in SQL, camelCase in Swift via the decoding
    /// strategy above).
    public static let browserFetchSQL = """
        SELECT id, path, artist, title, album, bpm, musical_key
        FROM files
        """
}
