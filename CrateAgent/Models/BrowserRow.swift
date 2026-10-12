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
    public var libraryMembership: LibraryMembership
    public var membershipRevision: Int64
    public var fileAvailability: FileAvailability
    public var processingBlockReason: String? = nil

    public var canProcess: Bool {
        processingBlockReason == nil && FileProcessingEligibility.isProcessable(membership: libraryMembership, availability: fileAvailability)
    }

    public var statusText: String {
        if let processingBlockReason {
            return processingBlockReason
        }
        let membership = libraryMembership.displayTitle
        return fileAvailability == .available ? membership : "\(membership) · \(fileAvailability.displayTitle)"
    }

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
    public var artistOrEmpty: String {
        artist ?? ""
    }

    public var titleOrEmpty: String {
        title ?? ""
    }

    public var albumOrEmpty: String {
        album ?? ""
    }

    public var bpmOrEmpty: String {
        bpm ?? ""
    }

    public var musicalKeyOrEmpty: String {
        musicalKey ?? ""
    }

    public init(
        id: Int64,
        path: String,
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        bpm: String? = nil,
        musicalKey: String? = nil,
        libraryMembership: LibraryMembership = .legacyUnverified,
        fileAvailability: FileAvailability = .unknown,
        membershipRevision: Int64 = 0
    ) {
        self.membershipRevision = membershipRevision
        self.id = id
        self.path = path
        self.artist = artist
        self.title = title
        self.album = album
        self.bpm = bpm
        self.musicalKey = musicalKey
        self.libraryMembership = libraryMembership
        self.fileAvailability = fileAvailability
    }
}

public extension BrowserRow {
    static let browserColumnsSQL = "files.id, files.path, files.artist, files.title, files.album, files.bpm, files.musical_key, files.library_membership, files.file_availability, files.membership_revision"

    /// Explicit projection query so we never accidentally pull the
    /// BLOB columns. The column list mirrors the struct's properties
    /// (snake_case in SQL, camelCase in Swift via the decoding
    /// strategy above).
    static let browserFetchSQL = """
    SELECT \(browserColumnsSQL)
    FROM files
    """
}

extension LibraryMembership {
    var displayTitle: String {
        switch self {
        case .active: "In Serato"
        case .pendingImport: "Import pending"
        case .legacyUnverified: "Membership unverified"
        case .retired: "Removed from Serato"
        }
    }
}

extension FileAvailability {
    var displayTitle: String {
        switch self {
        case .unknown: "Availability unknown"
        case .available: "Available"
        case .missing: "File missing"
        case .trashed: "In Trash"
        case .offline: "Volume offline"
        case .inaccessible: "Access denied"
        }
    }
}

extension BrowserRow {
    func applyingConflictScope(_ readiness: LibrarySyncReadiness?) -> Self {
        var row = self
        row.processingBlockReason = readiness?.conflictPath(for: SeratoConflictTarget(fileIDs: [id], paths: [path])).map(SeratoConflictMessages.blocked)
        return row
    }
}
