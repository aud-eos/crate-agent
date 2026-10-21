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
/// decode cost. Every FingerprintWorker batch fired the
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
    FetchableRecord, Hashable, Identifiable, Sendable
{
    public static let databaseTableName = "files"

    public var id: Int64
    public var path: String
    public var artist: String?
    public var title: String?
    public var album: String?
    public var genre: String?
    public var bpm: String?
    public var musicalKey: String?
    public var bitrateKbps: Int?
    public var libraryMembership: LibraryMembership
    public var membershipRevision: Int64
    public var fileAvailability: FileAvailability
    public var processingBlockReason: String?
    /// Song-family placement, present only in the Library projection.
    public var familyId: Int64?
    public var familyRole: LibraryFamilyRole?
    /// Distinct recordings of the family in the current status scope.
    public var familyVersions: Int?
    public var recordingId: Int64?
    /// Whether this file's recording is the family's saved manual main version.
    public var savedMain: Bool?
    /// The checklist columns, present only in the Library projection and only for files that are not retired.
    var checklistFailingMask: Int?
    var checklistUnknownMask: Int?
    var missingMetadataMask: Int?
    var isProtected: Bool?
    var isFinished: Bool?
    var stillNeedsCount: Int?
    var beatgridMarkerCount: Int?
    /// Unix seconds.
    var dateAdded: Int64?
    var dateAddedSource: DateAddedSource?
    /// 0 when Serato History has no play of the file; nil until History has ever been read.
    var playCount: Int?
    /// Popularity scores, 0 to 100; nil until a source looked the recording up.
    var popularityAllTime: Double?
    var popularityHot: Double?
    var popularityDetail: String?
    /// Files of the row's family in the status scope that are not Finished, and all of them.
    var familyFilesNeedingWork: Int?
    var familyFileCount: Int?

    /// Reads each column by name; a column the query doesn't select is nil.
    /// Hand-written because synthesized `Decodable` cost about 4x as much per row on a Library page.
    public init(row: Row) throws {
        id = row["id"]
        path = row["path"]
        artist = row["artist"]
        title = row["title"]
        album = row["album"]
        genre = row["genre"]
        bpm = row["bpm"]
        musicalKey = row["musical_key"]
        bitrateKbps = row["bitrate_kbps"]
        libraryMembership = try Self.decode(LibraryMembership.self, column: "library_membership", in: row)
        membershipRevision = row["membership_revision"]
        fileAvailability = try Self.decode(FileAvailability.self, column: "file_availability", in: row)
        familyId = row["family_id"]
        familyRole = try (row["family_role"] as Int?).map(LibraryFamilyRole.decode)
        familyVersions = row["family_versions"]
        recordingId = row["recording_id"]
        savedMain = row["saved_main"]
        checklistFailingMask = row["checklist_failing_mask"]
        checklistUnknownMask = row["checklist_unknown_mask"]
        missingMetadataMask = row["missing_metadata_mask"]
        isProtected = row["is_protected"]
        isFinished = row["is_finished"]
        stillNeedsCount = row["still_needs_count"]
        beatgridMarkerCount = row["beatgrid_marker_count"]
        dateAdded = row["date_added"]
        dateAddedSource = try (row["date_added_source"] as String?).map { stored in
            try Self.decode(DateAddedSource.self, rawValue: stored, column: "date_added_source")
        }
        playCount = row["play_count"]
        popularityAllTime = row["popularity_all_time"]
        popularityHot = row["popularity_hot"]
        popularityDetail = row["popularity_detail"]
        familyFilesNeedingWork = row["family_files_needing_work"]
        familyFileCount = row["family_file_count"]
    }

    private static func decode<Value: RawRepresentable>(_: Value.Type, column: String, in row: Row) throws -> Value where Value.RawValue == String {
        try decode(Value.self, rawValue: row[column], column: column)
    }

    private static func decode<Value: RawRepresentable>(_: Value.Type, rawValue: String?, column: String) throws -> Value where Value.RawValue == String {
        guard let rawValue, let value = Value(rawValue: rawValue) else {
            throw BrowserRowError.unexpectedValue(column: column, value: rawValue)
        }
        return value
    }

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

    /// Comparator identities for the checklist columns; the database sorts them, nulls last.
    var stillNeedsSortKey: Int {
        stillNeedsCount ?? Int.max
    }

    var dateAddedSortKey: Int64 {
        dateAdded ?? Int64.min
    }

    var playCountSortKey: Int {
        playCount ?? Int.min
    }

    var popularitySortKey: Double {
        popularityAllTime ?? -Double.infinity
    }

    var hotSortKey: Double {
        popularityHot ?? -Double.infinity
    }

    /// Whether the Library projection computed a checklist for this file; retired files have none.
    var hasChecklist: Bool {
        checklistFailingMask != nil
    }

    /// The file's checklist, or nil outside the Library projection and for retired files.
    func checklist() throws -> FileChecklist? {
        guard let checklistFailingMask else { return nil }
        guard let checklistUnknownMask, let missingMetadataMask, let isProtected, let isFinished, let stillNeedsCount else {
            throw ChecklistError.incompleteRow(fileID: id)
        }
        return try FileChecklist(failing: ChecklistMask.decode(checklistFailingMask, as: ChecklistItem.self),
                                 unknown: ChecklistMask.decode(checklistUnknownMask, as: ChecklistItem.self),
                                 missingMetadata: ChecklistMask.decode(missingMetadataMask, as: MetadataField.self),
                                 isProtected: isProtected, isFinished: isFinished, stillNeedsCount: stillNeedsCount)
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
    static let browserColumnsSQL = "files.id, files.path, files.artist, files.title, files.album, files.genre, files.bpm, files.musical_key, files.bitrate_kbps, files.library_membership, files.file_availability, files.membership_revision"

    /// Explicit projection query so we never accidentally pull the
    /// BLOB columns. `init(row:)` reads these columns by their snake_case names.
    static let browserFetchSQL = """
    SELECT \(browserColumnsSQL)
    FROM files
    """
}

enum BrowserRowError: LocalizedError, Equatable {
    case unexpectedValue(column: String, value: String?)

    var errorDescription: String? {
        switch self {
        case let .unexpectedValue(column, value): "The library row's \(column) has an unexpected value (\(value ?? "none"))."
        }
    }
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
