import Foundation
import GRDB

/// One row in the `tracks` table — canonical recording identity.
///
/// Keyed by Chromaprint fingerprint hash (the day-1 Approach 3
/// commitment). A `tracks` row may have zero `files` rows pointing at
/// it (Pillar C placeholder for a wishlist track), one (the typical
/// case), or many (FLAC + MP3 320 of the same recording, etc.).
///
/// `acoustidId` and `musicbrainzRecordingId` are populated by Pillar B
/// (auto-tagging); they live in this schema from SP-1 so we don't pay
/// a migration cost when the auto-tagger lands.
public struct TrackRecord: Codable, FetchableRecord, MutablePersistableRecord,
    Hashable, Identifiable
{
    public static let databaseTableName = "tracks"
    public static let databaseColumnDecodingStrategy =
        DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy =
        DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var fingerprintHash: Data
    public var acoustidId: String?
    public var musicbrainzRecordingId: String?
    public var musicbrainzReleaseId: String?
    public var musicbrainzArtistId: String?
    public var isrc: String?
    public var artist: String?
    public var title: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var year: Int?
    public var bpm: Double?
    public var workId: Int64?
    public var isPlaceholder: Bool

    public init(
        id: Int64? = nil,
        fingerprintHash: Data,
        acoustidId: String? = nil,
        musicbrainzRecordingId: String? = nil,
        musicbrainzReleaseId: String? = nil,
        musicbrainzArtistId: String? = nil,
        isrc: String? = nil,
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        bpm: Double? = nil,
        workId: Int64? = nil,
        isPlaceholder: Bool = false
    ) {
        self.id = id
        self.fingerprintHash = fingerprintHash
        self.acoustidId = acoustidId
        self.musicbrainzRecordingId = musicbrainzRecordingId
        self.musicbrainzReleaseId = musicbrainzReleaseId
        self.musicbrainzArtistId = musicbrainzArtistId
        self.isrc = isrc
        self.artist = artist
        self.title = title
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.bpm = bpm
        self.workId = workId
        self.isPlaceholder = isPlaceholder
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension TrackRecord {
    /// D-C: a 120s-capped fingerprint can collide across two different recordings. Re-identifying
    /// a row that already names a different recording is a collision only while another file
    /// depends on it; a file correcting its own row is a legitimate re-match. Returns the
    /// recording the collision would overwrite.
    func conflictingRecording(replacingWith incomingRecordingMBID: String, otherFilesReference: () throws -> Bool) rethrows -> String? {
        guard let existingRecordingMBID = musicbrainzRecordingId, existingRecordingMBID != incomingRecordingMBID,
              try otherFilesReference() else { return nil }
        return existingRecordingMBID
    }

    /// Whether an identity source (AcoustID, MusicBrainz, ISRC) has claimed this row.
    var hasRecordingIdentity: Bool {
        acoustidId != nil || musicbrainzRecordingId != nil || musicbrainzReleaseId != nil
            || musicbrainzArtistId != nil || isrc != nil
    }

    /// A row holding only its fingerprint (and possibly a song family), as
    /// fingerprint grouping creates it and match undo leaves it.
    var isBare: Bool {
        self == TrackRecord(id: id, fingerprintHash: fingerprintHash, workId: workId)
    }
}
