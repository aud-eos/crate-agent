import Foundation
import GRDB

actor LibraryPagedSnapshot: PagedQuerySnapshot {
    typealias Row = BrowserRow
    nonisolated let signature: LibraryBrowseQuery
    private let reader: DatabaseSnapshot
    private let selectAllTotal: Int
    /// Whether any family main row is in scope; Library hides the family columns otherwise.
    nonisolated let hasFamilies: Bool
    /// Read once when the snapshot opens, in id order: the counts, selection scopes and
    /// family members all come from it (#258).
    private let placements: [LibraryFamilyPlacement]
    /// The visible placements in display order, from the same read, so a page reads
    /// only its own rows and never runs the projection over every file again.
    private let visible: [PagedIdentity<Int64>]
    private var cachedSelectAll: [LibraryFamilyPlacement]?
    private var cachedFamilyMembers: [Int64: [LibraryFamilyPlacement]]?

    private init(reader: DatabaseSnapshot, query: LibraryBrowseQuery, placements ordered: [LibraryFamilyPlacement]) {
        self.reader = reader
        signature = query
        placements = ordered.sorted { first, second in first.identity.id < second.identity.id }
        visible = ordered.filter(query.isVisible).map(\.identity)
        let counts = query.counts(of: ordered)
        selectAllTotal = counts.selectAll
        hasFamilies = counts.hasFamilies
    }

    static func open(pool: DatabasePool, query: LibraryBrowseQuery) async throws -> LibraryPagedSnapshot {
        try Task.checkCancellation()
        let reader = try pool.makeSnapshot()
        let placements = try reader.read { database in try query.placements(in: database) }
        try Task.checkCancellation()
        return LibraryPagedSnapshot(reader: reader, query: query, placements: placements)
    }

    func count() -> Int {
        visible.count
    }

    func selectAllCount() -> Int {
        selectAllTotal
    }

    func rows(in range: Range<Int>) throws -> [BrowserRow] {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, range.upperBound <= visible.count else { throw PagingError.invalidRange }
        let ids = visible[range].map(\.id)
        return try reader.read { database in try signature.rows(in: database, ids: ids) }
    }

    /// How many files each chip matches in the scope this snapshot shows without its chip.
    func chipCounts() throws -> [ChecklistChip: ChecklistChipCount] {
        try Task.checkCancellation()
        return try reader.read { database in try signature.chipCounts(in: database) }
    }

    /// Whether Serato History has been read at least once, so play counts and Never played are known.
    func playCountsKnown() throws -> Bool {
        try Task.checkCancellation()
        return try reader.read { database in try SeratoLibraryFacts.hasStamp(.history, in: database) }
    }

    /// The genres and keys the facets can choose from in this snapshot's status scope.
    func facetOptions() throws -> LibraryFacetOptions {
        try Task.checkCancellation()
        return try reader.read { database in try LibraryFacetOptions.load(in: database, filter: signature.filter) }
    }

    func index(of id: Int64) throws -> Int? {
        visible.firstIndex { identity in identity.id == id }
    }

    /// Every counted file, including alternates of collapsed families and
    /// shown families' members a search or filter hides, so those selections stay in scope.
    func identities(after id: Int64?, limit: Int) throws -> [PagedIdentity<Int64>] {
        try slice(placements, after: id, limit: limit)
    }

    /// The files Select all selects: main and standalone rows, plus eligible alternates when the query includes them.
    func selectAllIdentities(after id: Int64?, limit: Int) throws -> [PagedIdentity<Int64>] {
        if cachedSelectAll == nil {
            cachedSelectAll = placements.filter(signature.isSelectedByAll)
        }
        return try slice(cachedSelectAll ?? [], after: id, limit: limit)
    }

    /// Each requested family's counted members, in id order; a family the snapshot does not count has none.
    func familyMembers(_ familyIds: Set<Int64>) throws -> [Int64: [LibraryFamilyPlacement]] {
        try Task.checkCancellation()
        let byFamily = cachedFamilyMembers ?? placements.reduce(into: [Int64: [LibraryFamilyPlacement]]()) { members, placement in
            if let familyID = placement.familyId {
                members[familyID, default: []].append(placement)
            }
        }
        cachedFamilyMembers = byFamily
        return Dictionary(uniqueKeysWithValues: familyIds.map { familyID in (familyID, byFamily[familyID] ?? []) })
    }

    func identities(in range: Range<Int>) throws -> [PagedIdentity<Int64>] {
        guard range.lowerBound >= 0, range.upperBound <= visible.count else { throw PagingError.invalidRange }
        return Array(visible[range])
    }

    nonisolated func identity(for row: BrowserRow) -> PagedIdentity<Int64> {
        .init(id: row.id, revision: row.membershipRevision)
    }

    private func slice(_ placements: [LibraryFamilyPlacement], after id: Int64?, limit: Int) throws -> [PagedIdentity<Int64>] {
        try Task.checkCancellation()
        guard limit > 0 else { throw PagingError.invalidRange }
        let start = id.map { identifier in placements.partitioningIndex { placement in placement.identity.id > identifier } } ?? 0
        return placements[start...].prefix(limit).map(\.identity)
    }
}

private extension Array {
    /// First index whose element satisfies `predicate`, for a predicate that is false then true across the array.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}
