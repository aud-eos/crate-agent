import Foundation
import GRDB

struct LibraryBrowseSort: Hashable, Sendable {
    enum Column: String, Sendable {
        case artist, title, bpm, musicalKey, album, path, stillNeeds, dateAdded, myPlays

        /// The sort key over `files` and the projection's `checklist` join, given the file's failing bits.
        func sql(_ table: String, failing: String) -> String {
            switch self {
            case .artist: "COALESCE(\(table).artist, '')"
            case .title: "COALESCE(\(table).title, '')"
            case .bpm: "COALESCE(\(table).bpm, '')"
            case .musicalKey: "COALESCE(\(table).musical_key, '')"
            case .album: "COALESCE(\(table).album, '')"
            case .path: "\(table).path"
            case .stillNeeds: LibraryChecklist.stillNeedsSQL(failing: failing)
            case .dateAdded: "\(LibraryChecklist.alias).date_added"
            case .myPlays: "\(LibraryChecklist.alias).play_count"
            }
        }

        /// Checklist columns read every file's checklist, and files without the value
        /// (no checklist, or no date added) sort last in both directions.
        var isChecklist: Bool {
            switch self {
            case .artist, .title, .bpm, .musicalKey, .album, .path: false
            case .stillNeeds, .dateAdded, .myPlays: true
            }
        }
    }

    var column: Column = .path
    var ascending = true

    /// Families sort by their main row's values and keep their alternates directly beneath it.
    var sql: String {
        let direction = ascending ? "ASC" : "DESC"
        let groupNulls = column.isChecklist ? "placed.group_key IS NULL ASC, " : ""
        let memberNulls = column.isChecklist ? "placed.sort_key IS NULL ASC, " : ""
        return "\(groupNulls)placed.group_key \(direction), placed.group_id ASC, placed.family_role ASC, \(memberNulls)placed.sort_key \(direction), placed.id ASC"
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
        case \BrowserRow.stillNeedsSortKey: column = .stillNeeds
        case \BrowserRow.dateAddedSortKey: column = .dateAdded
        case \BrowserRow.playCountSortKey: column = .myPlays
        default: column = .path
        }
    }
}

/// The Library projection: one row per standalone file, one main row per song
/// family with two or more live versions, and a family's alternates beneath it
/// while it is expanded or while a search or chip matches them. A file whose recording
/// has no live file is standalone. `placed` holds every file in the status scope with its
/// family placement; `in_scope` marks the files the result counts (every match,
/// plus the main row of each family that has a matching member). Each row carries its
/// file's checklist, computed in SQL (`LibraryChecklist`).
struct LibraryBrowseQuery: Hashable, Sendable {
    var filter: LibraryStatusFilter = .active
    var search = ""
    var chip: ChecklistChip?
    var sort = LibraryBrowseSort()
    var expandedFamilies: Set<Int64> = []
    /// Whether Select all also selects the eligible alternates of in-scope families.
    var includeAlternates = false

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearching: Bool {
        !trimmedSearch.isEmpty
    }

    /// While searching or filtering, every matching alternate is shown, whatever the saved disclosure.
    var isFiltering: Bool {
        isSearching || chip != nil
    }

    private var arguments: StatementArguments {
        let expanded = expandedFamilies.sorted().map(String.init).joined(separator: ",")
        return ["search": trimmedSearch, "expanded": "[\(expanded)]"]
    }

    /// Whether ordering or filtering reads the checklist, so every file's is computed before the page.
    /// Otherwise only the page's files and their families' members get one.
    private var ordersByChecklist: Bool {
        chip != nil || sort.column.isChecklist
    }

    /// Whether file `id` matches the search and chip, as 0 or 1.
    private func matchesSQL(_ id: String, failing: String) -> String {
        var terms: [String] = []
        if isSearching {
            terms.append("\(id) IN (SELECT id FROM matched_files)")
        }
        if let chip {
            terms.append(LibraryChecklist.chipSQL(chip, failing: failing, isFinished: LibraryChecklist.isFinishedSQL(failing: failing),
                                                  playCount: "\(LibraryChecklist.alias).play_count"))
        }
        return terms.isEmpty ? "1" : "(" + terms.joined(separator: " AND ") + ")"
    }

    /// Every failing bit of a file in `checklist`, with the versions bit from its family's live version count and main recording.
    private static func failingSQL(versions: String, headRecordingKey: String) -> String {
        LibraryChecklist.failingSQL(versionsBit: LibraryChecklist.versionsBitSQL(versions: versions, headRecordingKey: headRecordingKey))
    }

    /// A search runs its text match once per file, in `matched_files`, however often the passes below test it.
    /// With `withChecklist`, each file's checklist is computed once, in `checklist_files`, from primary-key joins.
    /// `family_base` ranks family files into `heads`; `family_files` then evaluates `matches`, whose versions bit
    /// needs the head's recording. The outer pass over `files` only joins their results, so a library without
    /// families pays only primary-key joins per file. The CROSS JOINs pin `family_base` to the `tracks_work_id`
    /// index; without statistics SQLite otherwise scans `files`.
    private func placedSQL(withChecklist: Bool) -> String {
        let checklist = LibraryChecklist.alias
        let familyFailing = Self.failingSQL(versions: "live_families.versions", headRecordingKey: "heads.head_recording_key")
        let placedFailing = Self.failingSQL(versions: "families.versions", headRecordingKey: "heads.head_recording_key")
        let placedMatches = matchesSQL("files.id", failing: placedFailing)
        let placedSortKey = sort.column.sql("files", failing: placedFailing)
        let order = SongFamilyRepresentative.orderSQL(available: "available", saved: "saved_main", title: "title",
                                                      musicBrainzID: "recording_mbid", recording: "recording_id", file: "id")
        let familyColumns = """
        (\(FileProcessingEligibility.processableSQL)) AS available,
        COALESCE(works.representative_track_id = files.track_id, 0) AS saved_main
        """
        let live = SongFamilyMutation.liveTrackSQL
        let matchedFiles = isSearching
            ? "matched_files AS MATERIALIZED (SELECT id FROM files WHERE \(ListSearch.predicate(prefix: "files.", parameter: ":search"))),\n"
            : ""
        let checklistFiles = withChecklist ? LibraryChecklist.filesCTEs(scope: filter.predicate) + ",\n" : ""
        let checklistJoin = withChecklist ? LibraryChecklist.joinSQL : ""
        let familyChecklistJoin = withChecklist ? """
        JOIN live_families ON live_families.family_id = family_base.family_id JOIN heads ON heads.family_id = family_base.family_id
        LEFT JOIN checklist_files AS \(checklist) ON \(checklist).file_id = family_base.id
        """ : ""
        let placedChecklist = withChecklist ? """
        ,
        \(placedFailing) AS checklist_failing_mask, \(LibraryChecklist.isFinishedSQL(failing: placedFailing)) AS is_finished,
        \(checklist).play_count
        """ : ""
        return """
        WITH \(matchedFiles)\(checklistFiles)live_families AS MATERIALIZED (\(SongFamilyMutation.liveFamiliesSQL)),
        family_base AS MATERIALIZED (
            SELECT files.id, files.membership_revision, files.title, tracks.work_id AS family_id, files.track_id AS recording_id,
                   tracks.musicbrainz_recording_id AS recording_mbid, \(KeeperMarks.recordingKeySQL) AS recording_key,
                   \(sort.column.sql("files", failing: "\(checklist).failing")) AS sort_key, \(familyColumns)
            FROM live_families CROSS JOIN tracks ON tracks.work_id = live_families.family_id CROSS JOIN works ON works.id = tracks.work_id
            CROSS JOIN files ON files.track_id = tracks.id \(checklistJoin)
            WHERE \(live) AND \(filter.predicate)
        ),
        heads AS MATERIALIZED (
            SELECT family_id, id AS head_id, sort_key AS head_key, recording_key AS head_recording_key FROM (
                SELECT family_id, id, sort_key, recording_key, ROW_NUMBER() OVER (PARTITION BY family_id ORDER BY \(order)) AS position FROM family_base
            ) WHERE position = 1
        ),
        family_files AS MATERIALIZED (
            SELECT family_base.family_id, \(matchesSQL("family_base.id", failing: familyFailing)) AS matches
            FROM family_base \(familyChecklistJoin)
        ),
        families AS MATERIALIZED (
            SELECT family_files.family_id, live_families.versions, MAX(matches) AS matched
            FROM family_files JOIN live_families ON live_families.family_id = family_files.family_id GROUP BY family_files.family_id
        ),
        placed AS (
            SELECT \(BrowserRow.browserColumnsSQL), heads.family_id, files.track_id AS recording_id, \(familyColumns),
                   \(placedMatches) AS matches,
                   COALESCE(heads.head_id, files.id) AS group_id,
                   CASE WHEN heads.head_id IS NULL THEN 0 WHEN heads.head_id = files.id THEN 1 ELSE 2 END AS family_role,
                   families.versions AS family_versions, COALESCE(families.matched, 0) AS family_matched,
                   CASE WHEN heads.head_id = files.id THEN families.matched ELSE \(placedMatches) END AS in_scope,
                   COALESCE(heads.head_key, \(placedSortKey)) AS group_key, \(placedSortKey) AS sort_key\(placedChecklist)
            FROM files LEFT JOIN tracks ON tracks.id = files.track_id LEFT JOIN works ON works.id = tracks.work_id
            LEFT JOIN heads ON heads.family_id = works.id AND \(live) LEFT JOIN families ON families.family_id = heads.family_id
            \(checklistJoin)
            WHERE \(filter.predicate)
        )
        """
    }

    /// One page of rows with each file's checklist and its family's file counts. Without `ordersByChecklist`
    /// the checklist is computed only for the page's files and their families' members, after the page is cut.
    private func pageSQL() -> String {
        let checklist = LibraryChecklist.alias
        let page = "placed_page"
        let pageColumns = ["id", "family_id", "family_role", "group_key", "group_id", "sort_key"]
            .map { column in "placed.\(column)" }.joined(separator: ", ")
        let pageScope = """
        files.id IN (SELECT id FROM \(page) UNION ALL SELECT members.id FROM tracks CROSS JOIN files AS members ON members.track_id = tracks.id
                     WHERE tracks.work_id IN (SELECT family_id FROM \(page)))
        """
        let pageChecklist = ordersByChecklist ? "" : ",\n" + LibraryChecklist.filesCTEs(scope: "\(filter.predicate) AND \(pageScope)")
        let failing = Self.failingSQL(versions: "families.versions", headRecordingKey: "heads.head_recording_key")
        let finished = LibraryChecklist.isFinishedSQL(failing: failing)
        return """
        \(placedSQL(withChecklist: ordersByChecklist)),
        \(page) AS MATERIALIZED (
            SELECT \(pageColumns) FROM placed WHERE \(visibleSQL) ORDER BY \(sort.sql) LIMIT :limit OFFSET :offset
        )\(pageChecklist),
        page_family_counts AS (
            SELECT page_families.family_id, COUNT(\(finished)) AS file_count, SUM(CASE WHEN \(finished) = 0 THEN 1 ELSE 0 END) AS needing_work
            FROM (SELECT DISTINCT family_id FROM \(page) WHERE family_id IS NOT NULL) AS page_families
            CROSS JOIN tracks ON tracks.work_id = page_families.family_id CROSS JOIN files ON files.track_id = tracks.id
            JOIN families ON families.family_id = page_families.family_id JOIN heads ON heads.family_id = page_families.family_id
            \(LibraryChecklist.joinSQL)
            WHERE \(SongFamilyMutation.liveTrackSQL) AND \(filter.predicate)
            GROUP BY page_families.family_id
        )
        SELECT \(BrowserRow.browserColumnsSQL), \(page).family_id, \(page).family_role, families.versions AS family_versions,
               files.track_id AS recording_id, COALESCE(works.representative_track_id = files.track_id, 0) AS saved_main,
               \(failing) AS checklist_failing_mask, \(checklist).unknown AS checklist_unknown_mask,
               \(checklist).missing_metadata AS missing_metadata_mask, \(checklist).is_protected,
               \(finished) AS is_finished, \(LibraryChecklist.stillNeedsSQL(failing: failing)) AS still_needs_count,
               \(checklist).beatgrid_marker_count, \(checklist).date_added, \(checklist).date_added_source, \(checklist).play_count,
               page_family_counts.needing_work AS family_files_needing_work, page_family_counts.file_count AS family_file_count
        FROM \(page) JOIN files ON files.id = \(page).id LEFT JOIN tracks ON tracks.id = files.track_id LEFT JOIN works ON works.id = tracks.work_id
        LEFT JOIN heads ON heads.family_id = \(page).family_id LEFT JOIN families ON families.family_id = \(page).family_id
        LEFT JOIN checklist_files AS \(checklist) ON \(checklist).file_id = \(page).id
        LEFT JOIN page_family_counts ON page_family_counts.family_id = \(page).family_id
        ORDER BY \(sort.sql.replacingOccurrences(of: "placed.", with: "\(page)."))
        """
    }

    private var visibleSQL: String {
        let revealed = isFiltering ? "1" : "placed.family_id IN (SELECT value FROM json_each(:expanded))"
        return "placed.in_scope AND (placed.family_role != \(LibraryFamilyRole.alternate.rawValue) OR \(revealed))"
    }

    private func orderedSQL(_ columns: String) -> String {
        """
        \(placedSQL(withChecklist: ordersByChecklist))
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

    /// Visible rows, the rows Select all would select, and whether any family is shown.
    func counts(in database: GRDB.Database) throws -> (visible: Int, selectAll: Int, hasFamilies: Bool) {
        try counts(of: placements(in: database))
    }

    /// The same counts from placements already read, so a snapshot runs the projection once for them all.
    func counts(of placements: [LibraryFamilyPlacement]) -> (visible: Int, selectAll: Int, hasFamilies: Bool) {
        var visible = 0
        var selectAll = 0
        var hasFamilies = false
        for placement in placements where !placement.isHiddenBySearch {
            if isVisible(placement) {
                visible += 1
            }
            if isSelectedByAll(placement) {
                selectAll += 1
            }
            hasFamilies = hasFamilies || placement.role == .main
        }
        return (visible, selectAll, hasFamilies)
    }

    /// A counted file shows as a row unless it is the alternate of a family that is neither expanded nor searched,
    /// as `visibleSQL` pages them.
    func isVisible(_ placement: LibraryFamilyPlacement) -> Bool {
        !placement.isHiddenBySearch
            && (placement.role != .alternate || isFiltering || placement.familyId.map(expandedFamilies.contains) == true)
    }

    /// Select all takes main and standalone rows, plus eligible alternates when the query includes them.
    func isSelectedByAll(_ placement: LibraryFamilyPlacement) -> Bool {
        !placement.isHiddenBySearch && (placement.role != .alternate || (includeAlternates && placement.isEligible))
    }

    /// How many files in the query's scope without its chip each chip matches: the status scope and search, file by file.
    func chipCounts(in database: GRDB.Database) throws -> [ChecklistChip: Int] {
        var unfiltered = self
        unfiltered.chip = nil
        let sums = ChecklistChip.allCases.map { chip -> String in
            let matches = LibraryChecklist.chipSQL(chip, failing: "placed.checklist_failing_mask", isFinished: "placed.is_finished",
                                                   playCount: "placed.play_count")
            return "COALESCE(SUM(placed.matches AND \(matches)), 0)"
        }.joined(separator: ", ")
        guard let row = try GRDB.Row.fetchOne(database, sql: "\(unfiltered.placedSQL(withChecklist: true))\nSELECT \(sums) FROM placed", arguments: unfiltered.arguments)
        else { throw PagingError.incompletePage }
        return Dictionary(uniqueKeysWithValues: ChecklistChip.allCases.enumerated().map { position, chip -> (ChecklistChip, Int) in
            (chip, row[position])
        })
    }

    func rows(in database: GRDB.Database, range: Range<Int>) throws -> [BrowserRow] {
        try BrowserRow.fetchAll(database, sql: pageSQL(), arguments: page(range))
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

    /// Every counted file's family placement, in id order, with the members
    /// of shown families that the search hides, so a selection of them stays
    /// in scope for family commands.
    /// Read through a cursor by column position: every snapshot opens with this read, over every file.
    func placements(in database: GRDB.Database) throws -> [LibraryFamilyPlacement] {
        let rows = try GRDB.Row.fetchCursor(database, sql: """
        \(placedSQL(withChecklist: ordersByChecklist))
        SELECT id, membership_revision, family_id, family_role, available, NOT in_scope AS hidden_by_search FROM placed
        WHERE in_scope OR (family_role = \(LibraryFamilyRole.alternate.rawValue) AND family_matched) ORDER BY id
        """, arguments: arguments)
        var placements: [LibraryFamilyPlacement] = []
        while let row = try rows.next() {
            try placements.append(LibraryFamilyPlacement(identity: .init(id: row[0], revision: row[1]), familyId: row[2],
                                                         role: LibraryFamilyRole.decode(row[3]), isEligible: row[4], isHiddenBySearch: row[5]))
        }
        return placements
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
