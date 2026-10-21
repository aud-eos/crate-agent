import Foundation
import GRDB

struct LibraryBrowseSort: Hashable, Sendable {
    enum Column: String, Sendable {
        case artist, title, bpm, musicalKey, album, path, stillNeeds, dateAdded, myPlays, popularity, hot, prepareRank

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
            case .popularity: "\(LibraryChecklist.alias).popularity_all_time"
            case .hot: "\(LibraryChecklist.alias).popularity_hot"
            case .prepareRank: PrepareRanking.sql(LibraryChecklist.alias)
            }
        }

        /// Checklist columns read every file's checklist, and files without the value
        /// (no checklist, or no date added) sort last in both directions.
        var isChecklist: Bool {
            switch self {
            case .artist, .title, .bpm, .musicalKey, .album, .path: false
            case .stillNeeds, .dateAdded, .myPlays, .popularity, .hot, .prepareRank: true
            }
        }
    }

    var column: Column = .path
    var ascending = true

    /// Families sort by their main row's values and keep their alternates directly beneath it.
    /// `table` is the alias that carries `group_key`, `group_id`, `family_role`, `sort_key` and `id`.
    func sql(_ table: String = "placed") -> String {
        let direction = ascending ? "ASC" : "DESC"
        let groupNulls = column.isChecklist ? "\(table).group_key IS NULL ASC, " : ""
        let memberNulls = column.isChecklist ? "\(table).sort_key IS NULL ASC, " : ""
        return "\(groupNulls)\(table).group_key \(direction), \(table).group_id ASC, \(table).family_role ASC, "
            + "\(memberNulls)\(table).sort_key \(direction), \(table).id ASC"
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
        case \BrowserRow.popularitySortKey: column = .popularity
        case \BrowserRow.hotSortKey: column = .hot
        case \BrowserRow.prepareRankSortKey: column = .prepareRank
        default: column = .path
        }
    }
}

/// The Library projection: one row per standalone file, one main row per song
/// family with two or more live versions, and a family's alternates beneath it
/// while it is expanded or while a search, chip or facet matches them. A file whose recording
/// has no live file is standalone. `placed` holds every file in the status scope with its
/// family placement; `in_scope` marks the files the result counts (every match,
/// plus the main row of each family that has a matching member). Each row carries its
/// file's checklist, computed in SQL (`LibraryChecklist`).
struct LibraryBrowseQuery: Hashable, Sendable {
    var filter: LibraryStatusFilter = .active
    var search = ""
    var chip: ChecklistChip?
    var facets = LibraryFacets()
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
        isSearching || chip != nil || !facets.isEmpty
    }

    /// Whether a search or facet narrows the files, through `matched_files`.
    private var narrowsFiles: Bool {
        isSearching || !facets.isEmpty
    }

    private func arguments() throws -> StatementArguments {
        var arguments: StatementArguments = ["search": trimmedSearch]
        try arguments += facets.arguments()
        return arguments
    }

    /// Whether ordering or filtering reads the checklist, so the placements compute every file's.
    /// A page always computes only its own files' and their families' members' checklists.
    private var ordersByChecklist: Bool {
        chip != nil || sort.column.isChecklist
    }

    /// Whether file `id` matches the search, facets and chip, as 0 or 1.
    private func matchesSQL(_ id: String, failing: String) -> String {
        var terms: [String] = []
        if narrowsFiles {
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

    /// A search and the facets run their match once per file, in `matched_files`, however often the passes below test it.
    /// With `withChecklist`, each file's checklist is computed once, in `checklist_files`, from primary-key joins.
    /// `family_base` ranks family files into `heads`; `family_files` then evaluates `matches`, whose versions bit
    /// needs the head's recording. The outer pass over `files` only joins their results, so a library without
    /// families pays only primary-key joins per file. The CROSS JOINs pin `family_base` to the `tracks_work_id`
    /// index; without statistics SQLite otherwise scans `files`. `families`, a query of family ids, limits the families placed.
    private func placedSQL(withChecklist: Bool, families: String? = nil) -> String {
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
        let fileMatches = (isSearching ? [ListSearch.predicate(prefix: "files.", parameter: ":search")] : []) + facets.predicates
        let matchedFiles = narrowsFiles
            ? "matched_files AS MATERIALIZED (SELECT id FROM files WHERE \(fileMatches.joined(separator: " AND "))),\n"
            : ""
        let liveFamilies = families.map { scope in
            "SELECT family_id, versions FROM (\(SongFamilyMutation.liveFamiliesSQL)) WHERE family_id IN (\(scope))"
        } ?? SongFamilyMutation.liveFamiliesSQL
        let checklistFiles = withChecklist ? LibraryChecklist.filesCTEs(scope: filter.predicate) + ",\n" : ""
        let checklistJoin = withChecklist ? LibraryChecklist.joinSQL : ""
        let familyChecklistJoin = withChecklist ? """
        JOIN live_families ON live_families.family_id = family_base.family_id JOIN heads ON heads.family_id = family_base.family_id
        LEFT JOIN checklist_files AS \(checklist) ON \(checklist).file_id = family_base.id
        """ : ""
        let placedChecklist = withChecklist ? """
        ,
        \(placedFailing) AS checklist_failing_mask, \(LibraryChecklist.isFinishedSQL(failing: placedFailing)) AS is_finished,
        \(checklist).play_count, \(checklist).popularity_all_time, \(checklist).popularity_hot
        """ : ""
        return """
        WITH \(matchedFiles)\(checklistFiles)live_families AS MATERIALIZED (\(liveFamilies)),
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

    /// The rows for `ids`, in that order, with each file's checklist and its family's file counts. The placements
    /// already ordered and filtered the files, so only the page's families are placed, through the status scope's
    /// projection without the search, facets or chip, and only their files get a checklist.
    private func pageSQL() -> String {
        let checklist = LibraryChecklist.alias
        let page = "placed_page"
        let pageScope = """
        files.id IN (SELECT id FROM \(page) UNION ALL SELECT members.id FROM tracks CROSS JOIN files AS members ON members.track_id = tracks.id
                     WHERE tracks.work_id IN (SELECT family_id FROM \(page)))
        """
        let pageFamilies = "SELECT tracks.work_id FROM json_each(:page) AS ids JOIN files ON files.id = ids.value JOIN tracks ON tracks.id = files.track_id"
        let failing = Self.failingSQL(versions: "families.versions", headRecordingKey: "heads.head_recording_key")
        let finished = LibraryChecklist.isFinishedSQL(failing: failing)
        return """
        \(LibraryBrowseQuery(filter: filter).placedSQL(withChecklist: false, families: pageFamilies)),
        \(page) AS MATERIALIZED (
            SELECT ids.key AS position, placed.id, placed.family_id, placed.family_role FROM json_each(:page) AS ids CROSS JOIN placed ON placed.id = ids.value
        ),
        \(LibraryChecklist.filesCTEs(scope: "\(filter.predicate) AND \(pageScope)")),
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
               \(checklist).popularity_all_time, \(checklist).popularity_hot, \(checklist).popularity_detail,
               page_family_counts.needing_work AS family_files_needing_work, page_family_counts.file_count AS family_file_count
        FROM \(page) JOIN files ON files.id = \(page).id LEFT JOIN tracks ON tracks.id = files.track_id LEFT JOIN works ON works.id = tracks.work_id
        LEFT JOIN heads ON heads.family_id = \(page).family_id LEFT JOIN families ON families.family_id = \(page).family_id
        LEFT JOIN checklist_files AS \(checklist) ON \(checklist).file_id = \(page).id
        LEFT JOIN page_family_counts ON page_family_counts.family_id = \(page).family_id
        ORDER BY \(page).position
        """
    }

    /// Visible rows, the rows Select all would select, and whether any family is shown, from placements
    /// already read, so a snapshot runs the projection once for them all.
    func counts(of placements: [LibraryFamilyPlacement]) -> (visible: Int, selectAll: Int, hasFamilies: Bool) {
        var visible = 0
        var selectAll = 0
        var hasFamilies = false
        for placement in placements where !placement.isHiddenByFilter {
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

    /// A counted file shows as a row unless it is the alternate of a family that is neither expanded nor filtered.
    func isVisible(_ placement: LibraryFamilyPlacement) -> Bool {
        !placement.isHiddenByFilter
            && (placement.role != .alternate || isFiltering || placement.familyId.map(expandedFamilies.contains) == true)
    }

    /// Select all takes main and standalone rows, plus eligible alternates when the query includes them.
    func isSelectedByAll(_ placement: LibraryFamilyPlacement) -> Bool {
        !placement.isHiddenByFilter && (placement.role != .alternate || (includeAlternates && placement.isEligible))
    }

    /// How many files in the query's scope without its chip each chip matches: the status scope, search and facets, file by file.
    /// A chip whose source has never been read is unknown, not 0.
    func chipCounts(in database: GRDB.Database) throws -> [ChecklistChip: ChecklistChipCount] {
        var unfiltered = self
        unfiltered.chip = nil
        let sums = ChecklistChip.allCases.map { chip -> String in
            let matches = LibraryChecklist.chipSQL(chip, failing: "placed.checklist_failing_mask", isFinished: "placed.is_finished",
                                                   playCount: "placed.play_count")
            return "COALESCE(SUM(placed.matches AND \(matches)), 0)"
        }.joined(separator: ", ")
        guard let row = try GRDB.Row.fetchOne(database, sql: "\(unfiltered.placedSQL(withChecklist: true))\nSELECT \(sums) FROM placed", arguments: unfiltered.arguments())
        else { throw PagingError.incompletePage }
        let unread = try Set(ChecklistSource.allCases.filter { source in try !SeratoLibraryFacts.hasStamp(source, in: database) })
        return Dictionary(uniqueKeysWithValues: ChecklistChip.allCases.enumerated().map { position, chip -> (ChecklistChip, ChecklistChipCount) in
            (chip, chip.source.map(unread.contains) == true ? .unknown : .files(row[position]))
        })
    }

    /// The rows for `ids`, in that order. Every id must be a visible placement read at the same snapshot.
    func rows(in database: GRDB.Database, ids: [Int64]) throws -> [BrowserRow] {
        let page = "[" + ids.map(String.init).joined(separator: ",") + "]"
        let rows = try BrowserRow.fetchAll(database, sql: pageSQL(), arguments: ["page": page])
        guard rows.map(\.id) == ids else { throw PagingError.incompletePage }
        return rows
    }

    /// Every counted file's family placement, in display order, with the members
    /// of shown families that the search or filters hide, so a selection of them stays
    /// in scope for family commands. The visible ones, in this order, are the pages.
    /// Read through a cursor by column position: every snapshot opens with this read, over every file.
    func placements(in database: GRDB.Database) throws -> [LibraryFamilyPlacement] {
        let rows = try GRDB.Row.fetchCursor(database, sql: """
        \(placedSQL(withChecklist: ordersByChecklist))
        SELECT id, membership_revision, family_id, family_role, available, NOT in_scope AS hidden_by_filter FROM placed
        WHERE in_scope OR (family_role = \(LibraryFamilyRole.alternate.rawValue) AND family_matched) ORDER BY \(sort.sql())
        """, arguments: arguments())
        var placements: [LibraryFamilyPlacement] = []
        while let row = try rows.next() {
            try placements.append(LibraryFamilyPlacement(identity: .init(id: row[0], revision: row[1]), familyId: row[2],
                                                         role: LibraryFamilyRole.decode(row[3]), isEligible: row[4], isHiddenByFilter: row[5]))
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
    /// A member of a shown family that the search or filters don't match. Only
    /// "Also select N hidden" selects it, never the checkbox or Select all.
    let isHiddenByFilter: Bool
}
