import Foundation
import GRDB

/// What the duplicate finder, keeper picker, panel and resolver read
/// from a file. `FileRecord` and the BLOB-free `DuplicateFileRow`
/// both conform, mirroring the `HygieneFileSource` pattern.
public protocol DuplicateFileSource: SeratoConflictTargetFile, Hashable, Sendable {
    var membershipRevision: Int64 { get }
    var artist: String? { get }
    var title: String? { get }
    var album: String? { get }
    var fileSize: Int64 { get }
    var mtime: Int64 { get }
    var bitrateKbps: Int? { get }
    var fingerprintStatus: FingerprintStatus { get }
    var identity: FileMetadata { get }
    /// Plays Serato History attributes to this file; a keeper tiebreak.
    var seratoPlayCount: Int { get }
}

extension FileRecord: DuplicateFileSource {
    /// `files` rows do not carry the derived History cache; only
    /// `DuplicateFileRow`, which the Duplicates scan fetches, joins it.
    public var seratoPlayCount: Int {
        0
    }
}

/// One member of a duplicate group, fetched by
/// `DuplicateFinder.findDuplicates(in:mode:)`. Carries the reviewed
/// membership revision and physical identity so the resolver can
/// reject a group whose files changed after review, but never the
/// Chromaprint fingerprint BLOB.
public struct DuplicateFileRow: DuplicateFileSource, Identifiable {
    public let id: Int64?
    public let membershipRevision: Int64
    public let path: String
    public let volumeUuid: String
    public let inode: Int64
    public let fileSize: Int64
    public let mtime: Int64
    public let lightweightHash: Data?
    public let bitrateKbps: Int?
    public let artist: String?
    public let title: String?
    public let album: String?
    public let fingerprintStatus: FingerprintStatus
    public let seratoPlayCount: Int

    static let columnsSQL = """
    files.id, files.membership_revision, files.path, files.volume_uuid, files.inode, files.file_size, files.mtime,
    files.lightweight_hash, files.bitrate_kbps, files.artist, files.title, files.album, files.fingerprint_status,
    (SELECT play_count FROM serato_play_counts WHERE serato_play_counts.file_id = files.id) AS serato_play_count
    """

    public var identity: FileMetadata {
        FileMetadata(path: path, volumeUuid: volumeUuid, inode: inode, fileSize: fileSize, mtime: mtime, lightweightHash: lightweightHash)
    }

    init(row: Row) throws {
        id = row["id"]
        membershipRevision = row["membership_revision"]
        path = row["path"]
        volumeUuid = row["volume_uuid"]
        inode = row["inode"]
        fileSize = row["file_size"]
        mtime = row["mtime"]
        lightweightHash = row["lightweight_hash"]
        bitrateKbps = row["bitrate_kbps"]
        artist = row["artist"]
        title = row["title"]
        album = row["album"]
        let status: String = row["fingerprint_status"]
        guard let fingerprintStatus = FingerprintStatus(rawValue: status) else {
            throw DuplicateScanError.unknownFingerprintStatus(status)
        }
        self.fingerprintStatus = fingerprintStatus
        seratoPlayCount = row["serato_play_count"] ?? 0
    }
}

enum DuplicateScanError: LocalizedError, Equatable {
    case unknownFingerprintStatus(String)

    var errorDescription: String? {
        switch self {
        case let .unknownFingerprintStatus(status): "Unknown fingerprint status \(status) in the duplicate scan."
        }
    }
}
