import Foundation
import GRDB

struct LibraryBrowseSort: Hashable, Sendable {
    enum Column: String, Sendable {
        case artist, title, bpm, musicalKey, album, path
        func sql(_ table: String) -> String {
            switch self {
            case .artist: "COALESCE(\(table).artist, '')"
            case .title: "COALESCE(\(table).title, '')"
            case .bpm: "COALESCE(\(table).bpm, '')"
            case .musicalKey: "COALESCE(\(table).musical_key, '')"
            case .album: "COALESCE(\(table).album, '')"
            case .path: "\(table).path"
            }
        }
    }

    var column: Column = .path
    var ascending = true

    /// Families sort by their main row's values and keep their alternates directly beneath it.
    var sql: String {
        let direction = ascending ? "ASC" : "DESC"
        return "placed.group_key \(direction), placed.group_id ASC, placed.family_role ASC, placed.sort_key \(direction), placed.id ASC"
    }

    init(column: Column = .path, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }

    init(comparator: KeyPathComparator<BrowserRow>?) {
        ascending = comparator?.order != .reverse
        switch comparator?.keyPath {
        case \BrowserRow.artistOrEmpty: column = .artist
        case \BrowserRow.titleOrEmpty: column = .title
        case \BrowserRow.bpmOrEmpty: column = .bpm
        case \BrowserRow.musicalKeyOrEmpty: column = .musicalKey
        case \BrowserRow.albumOrEmpty: column = .album
        default: column = .path
        }
    }
}

/// The Library projection: one row per standalone file, one main row per song
/// family with two or more live versions, and a family's alternates beneath it
/// while it is expanded or while a search matches them. A file whose recording
/// has no live file is standalone. `placed` holds every file in the status scope with its
/// family placement; `in_scope` marks the files the result counts (every match,
/// plus the main row of each family that has a matching member).
struct LibraryBrowseQuery: Hashable, Sendable {
    var filter: LibraryStatusFilter = .active
    var search = ""
    var sort = LibraryBrowseSort()
    var expandedFamilies: Set<Int64> = []
    /// Whether Select all also selects the eligible alternates of in-scope families.
    var includeAlternates = false

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// While searching, every matching alternate is shown, whatever the saved disclosure.
    var isSearching: Bool {
        !trimmedSearch.isEmpty
    }

    private var arguments: StatementArguments {
        let expanded = expandedFamilies.sorted().map(String.init).joined(separator: ",")
        return ["search": trimmedSearch, "expanded": "[\(expanded)]"]
    }

    /// Family files are ranked in small CTEs; the outer pass over `files` only joins their results,
    /// so a library without families pays only primary-key joins per file. The CROSS JOINs pin
    /// `family_files` to the `tracks_work_id` index; without statistics SQLite otherwise scans `files`.
    private var placedSQL: String {
        let matches = isSearching ? ListSearch.predicate(prefix: "files.", parameter: ":search") : "1"
        let sortKey = sort.column.sql("files")
        let order = SongFamilyRepresentative.orderSQL(available: "available", saved: "saved_main", title: "title",
                                                      musicBrainzID: "recording_mbid", recording: "recording_id", file: "id")
        let familyColumns = """
        (\(FileProcessingEligibility.processableSQL)) AS available,
        COALESCE(works.representative_track_id = files.track_id, 0) AS saved_main,
        (\(matches)) AS matches
        """
        let live = SongFamilyMutation.liveTrackSQL
        return """
        WITH live_families AS MATERIALIZED (\(SongFamilyMutation.liveFamiliesSQL)),
        family_files AS MATERIALIZED (
            SELECT files.id, files.membership_revision, files.title, tracks.work_id AS family_id, files.track_id AS recording_id,
                   tracks.musicbrainz_recording_id AS recording_mbid, \(sortKey) AS sort_key, \(familyColumns)
            FROM live_families CROSS JOIN tracks ON tracks.work_id = live_families.family_id CROSS JOIN works ON works.id = tracks.work_id
            CROSS JOIN files ON files.track_id = tracks.id
            WHERE \(live) AND \(filter.predicate)
        ),
        families AS (
            SELECT family_files.family_id, live_families.versions, MAX(matches) AS matched
            FROM family_files JOIN live_families ON live_families.family_id = family_files.family_id GROUP BY family_files.family_id
        ),
        heads AS (
            SELECT family_id, id AS head_id, sort_key AS head_key FROM (
                SELECT family_id, id, sort_key, ROW_NUMBER() OVER (PARTITION BY family_id ORDER BY \(order)) AS position FROM family_files
            ) WHERE position = 1
        ),
        placed AS (
            SELECT \(BrowserRow.browserColumnsSQL), heads.family_id, files.track_id AS recording_id, \(familyColumns),
                   COALESCE(heads.head_id, files.id) AS group_id,
                   CASE WHEN heads.head_id IS NULL THEN 0 WHEN heads.head_id = files.id THEN 1 ELSE 2 END AS family_role,
                   families.versions AS family_versions, COALESCE(families.matched, 0) AS family_matched,
                   CASE WHEN heads.head_id = files.id THEN families.matched ELSE (\(matches)) END AS in_scope,
                   COALESCE(heads.head_key, \(sortKey)) AS group_key, \(sortKey) AS sort_key
            FROM files LEFT JOIN tracks ON tracks.id = files.track_id LEFT JOIN works ON works.id = tracks.work_id
            LEFT JOIN heads ON heads.family_id = works.id AND \(live) LEFT JOIN families ON families.family_id = heads.family_id
            WHERE \(filter.predicate)
        )
        """
    }

    private static let rowColumns = (BrowserRow.browserColumnsSQL.replacingOccurrences(of: "files.", with: "placed.")
        + ", placed.family_id, placed.family_role, placed.family_versions, placed.recording_id, placed.saved_main")

    private var visibleSQL: String {
        let revealed = isSearching ? "1" : "placed.family_id IN (SELECT value FROM json_each(:expanded))"
        return "placed.in_scope AND (placed.family_role != \(LibraryFamilyRole.alternate.rawValue) OR \(revealed))"
    }

    private func orderedSQL(_ columns: String) -> String {
        """
        \(placedSQL)
        SELECT \(columns) FROM placed
        WHERE \(visibleSQL) ORDER BY \(sort.sql)
        """
    }

    private func page(_ range: Range<Int>) throws -> StatementArguments {
        guard range.lowerBound >= 0 else { throw PagingError.invalidRange }
        var page = arguments
        page += ["limit": range.count, "offset": range.lowerBound]
        return page
    }

    /// Visible rows, the rows Select all would select, and whether any family is shown, in one pass.
    func counts(in database: GRDB.Database) throws -> (visible: Int, selectAll: Int, hasFamilies: Bool) {
        let alternates = includeAlternates ? "placed.available" : "0"
        guard let row = try GRDB.Row.fetchOne(database, sql: """
        \(placedSQL)
        SELECT COUNT(*) FILTER (WHERE \(visibleSQL)) AS visible,
               COUNT(*) FILTER (WHERE placed.in_scope AND (placed.family_role != \(LibraryFamilyRole.alternate.rawValue) OR \(alternates))) AS select_all,
               COUNT(*) FILTER (WHERE placed.in_scope AND placed.family_role = \(LibraryFamilyRole.main.rawValue)) > 0 AS has_families
        FROM placed
        """, arguments: arguments) else {
            throw PagingError.incompletePage
        }
        return (row["visible"], row["select_all"], row["has_families"])
    }

    func rows(in database: GRDB.Database, range: Range<Int>) throws -> [BrowserRow] {
        try BrowserRow.fetchAll(database, sql: orderedSQL(Self.rowColumns) + " LIMIT :limit OFFSET :offset", arguments: page(range))
    }

    func identities(in database: GRDB.Database, range: Range<Int>) throws -> [PagedIdentity<Int64>] {
        try GRDB.Row.fetchAll(database, sql: orderedSQL("placed.id, placed.membership_revision") + " LIMIT :limit OFFSET :offset", arguments: page(range))
            .map { row in .init(id: row["id"], revision: row["membership_revision"]) }
    }

    func index(of id: Int64, in database: GRDB.Database) throws -> Int? {
        var lookup = arguments
        lookup += ["id": id]
        return try Int.fetchOne(database, sql: """
        SELECT position FROM (\(orderedSQL("placed.id, ROW_NUMBER() OVER (ORDER BY \(sort.sql)) - 1 AS position"))) WHERE id = :id
        """, arguments: lookup)
    }

    /// Counted members of the given families, read from the family CTEs alone.
    func familyPlacements(_ familyIds: Set<Int64>, in database: GRDB.Database) throws -> [LibraryFamilyPlacement] {
        var lookup = arguments
        lookup += ["families": "[" + familyIds.sorted().map(String.init).joined(separator: ",") + "]"]
        return try GRDB.Row.fetchAll(database, sql: """
        \(placedSQL)
        SELECT family_files.id, family_files.membership_revision, family_files.family_id, family_files.available,
               family_files.id = heads.head_id AS is_head, family_files.matches
        FROM family_files JOIN heads ON heads.family_id = family_files.family_id JOIN families ON families.family_id = family_files.family_id
        WHERE family_files.family_id IN (SELECT value FROM json_each(:families))
          AND families.matched
        ORDER BY family_files.id
        """, arguments: lookup).map { row in
            LibraryFamilyPlacement(identity: .init(id: row["id"], revision: row["membership_revision"]), familyId: row["family_id"],
                                   role: row["is_head"] ? .main : .alternate, isEligible: row["available"],
                                   isHiddenBySearch: !(row["is_head"] as Bool) && !(row["matches"] as Bool))
        }
    }

    /// Every counted file's family placement, in id order, with the members
    /// of shown families that the search hides, so a selection of them stays
    /// in scope for family commands.
    func placements(in database: GRDB.Database) throws -> [LibraryFamilyPlacement] {
        try GRDB.Row.fetchAll(database, sql: """
        \(placedSQL)
        SELECT id, membership_revision, family_id, family_role, available, NOT in_scope AS hidden_by_search FROM placed
        WHERE in_scope OR (family_role = \(LibraryFamilyRole.alternate.rawValue) AND family_matched) ORDER BY id
        """, arguments: arguments).map { row in
            try LibraryFamilyPlacement(identity: .init(id: row["id"], revision: row["membership_revision"]), familyId: row["family_id"],
                                       role: LibraryFamilyRole.decode(row["family_role"]), isEligible: row["available"],
                                       isHiddenBySearch: row["hidden_by_search"])
        }
    }
}

public enum LibraryFamilyRole: Int, Codable, Sendable {
    case standalone = 0, main = 1, alternate = 2

    static func decode(_ rawValue: Int) throws -> Self {
        guard let role = Self(rawValue: rawValue) else { throw PagingError.incompletePage }
        return role
    }
}

struct LibraryFamilyPlacement: Equatable, Sendable {
    let identity: PagedIdentity<Int64>
    let familyId: Int64?
    let role: LibraryFamilyRole
    /// Processable now. Only eligible alternates join a selection through a family control or Select all.
    let isEligible: Bool
    /// A member of a shown family that the search doesn't match. Only "Also
    /// select N hidden" selects it, never the checkbox or Select all.
    let isHiddenBySearch: Bool
}
