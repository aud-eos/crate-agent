import Foundation

/// One thing a file needs before the library is finished. Its mask bit is `1 << rawValue`.
enum ChecklistItem: Int, CaseIterable, Hashable, Sendable {
    case inCrate, cuePoints, beatgridChecked, metadata, quality, versions, duplicate
}

/// A metadata field the metadata item requires. Its mask bit is `1 << rawValue`.
enum MetadataField: Int, CaseIterable, Hashable, Sendable {
    case artist, title, genre, bpm, key

    var column: String {
        switch self {
        case .artist: "artist"
        case .title: "title"
        case .genre: "genre"
        case .bpm: "bpm"
        case .key: "musical_key"
        }
    }
}

enum ChecklistError: LocalizedError, Equatable {
    case unexpectedBits(mask: Int)
    case incompleteRow(fileID: Int64)

    var errorDescription: String? {
        switch self {
        case let .unexpectedBits(mask): "The library checklist read an unknown item mask (\(mask))."
        case let .incompleteRow(fileID): "The library checklist for file \(fileID) is incomplete."
        }
    }
}

enum ChecklistMask {
    static func bit<Item: RawRepresentable>(_ item: Item) -> Int where Item.RawValue == Int {
        1 << item.rawValue
    }

    /// The items a stored mask names; any bit no item names is an unexpected state.
    static func decode<Item: CaseIterable & Hashable & RawRepresentable>(_ mask: Int, as _: Item.Type) throws -> Set<Item>
        where Item.RawValue == Int
    {
        var remaining = mask
        var items: Set<Item> = []
        for item in Item.allCases where mask & bit(item) != 0 {
            items.insert(item)
            remaining &= ~bit(item)
        }
        guard remaining == 0 else { throw ChecklistError.unexpectedBits(mask: mask) }
        return items
    }
}

/// A file's checklist as the Library projection computed it. SQL is the only
/// source of Finished and the Still needs count.
struct FileChecklist: Hashable, Sendable {
    let failing: Set<ChecklistItem>
    let unknown: Set<ChecklistItem>
    let missingMetadata: Set<MetadataField>
    let isProtected: Bool
    let isFinished: Bool
    let stillNeedsCount: Int
}

enum ChecklistChip: String, CaseIterable, Identifiable, Sendable {
    case needsWork, notInCrate, noCues, gridUnchecked, lowQuality, neverPlayed, tooManyVersions, finished

    var id: String {
        rawValue
    }

    enum Match: Hashable, Sendable {
        case failing(ChecklistItem), needsWork, finished, neverPlayed
    }

    /// What the chip matches: one item's failure, or a whole-file state.
    var match: Match {
        switch self {
        case .needsWork: .needsWork
        case .notInCrate: .failing(.inCrate)
        case .noCues: .failing(.cuePoints)
        case .gridUnchecked: .failing(.beatgridChecked)
        case .lowQuality: .failing(.quality)
        case .neverPlayed: .neverPlayed
        case .tooManyVersions: .failing(.versions)
        case .finished: .finished
        }
    }
}

/// The checklist rules, as SQL over the Library projection's aliases.
enum LibraryChecklist {
    static let minimumLossyBitrateKbps = 256
    static let losslessExtensions: Set<String> = ["flac", "wav", "aif", "aiff"]
    static let maximumFamilyVersions = 4
    static let refreshThrottle: DispatchQueue.SchedulerTimeType.Stride = .seconds(2)
    static let observedTables = [SeratoLibraryFacts.factsTable, SeratoLibraryFacts.membershipTable, SeratoLibraryFacts.stampTable,
                                 SeratoAnalysisStore.table, ChecklistDuplicates.table, KeeperMarks.table, SeratoPlayCounts.table]

    /// The alias every projection CTE joins `checklist_files` under.
    static let alias = "checklist"

    private static func flag(_ condition: String, _ item: ChecklistItem) -> String {
        "(CASE WHEN \(condition) THEN \(ChecklistMask.bit(item)) ELSE 0 END)"
    }

    private static var losslessSQL: String {
        "(" + losslessExtensions.sorted().map { pathExtension in "files.path LIKE '%.\(pathExtension)'" }.joined(separator: " OR ") + ")"
    }

    private static var missingMetadataSQL: String {
        "(" + MetadataField.allCases.map { field in
            "(CASE WHEN NULLIF(TRIM(files.\(field.column)), '') IS NULL THEN \(ChecklistMask.bit(field)) ELSE 0 END)"
        }.joined(separator: " | ") + ")"
    }

    /// The CTEs that compute each file's placement-independent checklist in
    /// `checklist_files`, for the files `scope` admits that are not retired.
    /// `checklist_facts` reads each fact once through primary-key joins; a file is
    /// protected when its recording key is a kept one (`KeeperMarks`), and only
    /// its own valid mark suppresses the duplicate item.
    static func filesCTEs(scope: String) -> String {
        let fact = "facts"
        let analysis = "analysis"
        let marks = KeeperMarks.table
        let failing = [
            flag("has_crate_stamp AND NOT in_crate", .inCrate),
            flag("cue_count = 0", .cuePoints),
            flag("beatgrid_locked = 0", .beatgridChecked),
            flag("missing_metadata != 0", .metadata),
            flag("bitrate_kbps < \(minimumLossyBitrateKbps)", .quality),
            flag("is_duplicate AND NOT has_own_mark", .duplicate),
        ].joined(separator: " | ")
        let unknown = [
            flag("NOT has_crate_stamp", .inCrate),
            flag("cue_count IS NULL", .cuePoints),
            flag("beatgrid_locked IS NULL", .beatgridChecked),
            flag("bitrate_kbps IS NULL AND NOT is_lossless", .quality),
        ].joined(separator: " | ")
        return """
        kept_recording_keys AS MATERIALIZED (\(KeeperMarks.keptRecordingKeysSQL)),
        checklist_facts AS MATERIALIZED (
            SELECT files.id AS file_id, \(KeeperMarks.recordingKeySQL) AS recording_key,
                   \(KeeperMarks.recordingKeySQL) IN kept_recording_keys AS is_protected,
                   COALESCE(\(KeeperMarks.validMarkSQL), 0) AS has_own_mark,
                   EXISTS (SELECT 1 FROM \(SeratoLibraryFacts.stampTable) WHERE source = '\(ChecklistSource.subcrates.rawValue)') AS has_crate_stamp,
                   EXISTS (SELECT 1 FROM \(SeratoLibraryFacts.membershipTable) AS crates WHERE crates.file_id = files.id) AS in_crate,
                   \(analysis).cue_count, \(analysis).beatgrid_marker_count,
                   \(fact).beatgrid_locked, \(fact).added_at AS date_added, \(fact).added_source AS date_added_source,
                   CASE WHEN EXISTS (SELECT 1 FROM \(SeratoLibraryFacts.stampTable) WHERE source = '\(ChecklistSource.history.rawValue)')
                        THEN COALESCE(plays.play_count, 0) END AS play_count, duplicates.file_id IS NOT NULL AS is_duplicate,
                   files.bitrate_kbps, \(losslessSQL) AS is_lossless, \(missingMetadataSQL) AS missing_metadata
            FROM files LEFT JOIN tracks ON tracks.id = files.track_id
            \(SeratoAnalysisStore.freshJoinSQL(as: analysis))
            LEFT JOIN \(SeratoLibraryFacts.factsTable) AS \(fact) ON \(fact).file_id = files.id
            LEFT JOIN \(SeratoPlayCounts.table) AS plays ON plays.file_id = files.id
            LEFT JOIN \(ChecklistDuplicates.table) AS duplicates ON duplicates.file_id = files.id
            LEFT JOIN \(marks) ON \(marks).file_id = files.id
            WHERE \(scope) AND \(FileProcessingEligibility.activeSQL)
        ),
        checklist_files AS MATERIALIZED (
            SELECT file_id, recording_key, is_protected, missing_metadata, beatgrid_marker_count, date_added, date_added_source, play_count,
                   \(failing) AS failing, \(unknown) AS unknown
            FROM checklist_facts
        )
        """
    }

    /// Joins a projection CTE's files to their checklist; files outside it get NULL columns.
    static var joinSQL: String {
        "LEFT JOIN checklist_files AS \(alias) ON \(alias).file_id = files.id"
    }

    /// The versions bit: a family over the limit flags every file whose recording isn't the main row's, unless it is kept.
    static func versionsBitSQL(versions: String, headRecordingKey: String) -> String {
        flag("\(versions) > \(maximumFamilyVersions) AND \(alias).recording_key != \(headRecordingKey) AND NOT \(alias).is_protected", .versions)
    }

    /// Every failing bit, given the placement-dependent versions bit.
    static func failingSQL(versionsBit: String) -> String {
        "(\(alias).failing | \(versionsBit))"
    }

    static func isFinishedSQL(failing: String) -> String {
        "(\(alias).is_protected OR (\(failing) = 0 AND \(alias).unknown = 0))"
    }

    /// Set bits in `failing | unknown`, or 0 for a protected file.
    static func stillNeedsSQL(failing: String) -> String {
        let needs = "(\(failing) | \(alias).unknown)"
        let count = ChecklistItem.allCases.map { item in "((\(needs) >> \(item.rawValue)) & 1)" }.joined(separator: " + ")
        return "(CASE WHEN \(alias).is_protected THEN 0 ELSE \(count) END)"
    }

    /// Whether a file matches `chip`, as 0 or 1; a file without a checklist matches none.
    static func chipSQL(_ chip: ChecklistChip, failing: String, isFinished: String, playCount: String) -> String {
        let predicate = switch chip.match {
        case .needsWork: "NOT \(isFinished)"
        case .finished: isFinished
        case .neverPlayed: "\(playCount) = 0"
        case let .failing(item): "(\(failing) & \(ChecklistMask.bit(item))) != 0"
        }
        return "COALESCE(\(predicate), 0)"
    }
}
