import Foundation
import GRDB

actor LibraryPagedSnapshot: PagedQuerySnapshot {
    typealias Row = BrowserRow
    nonisolated let signature: LibraryBrowseQuery
    private let reader: DatabaseSnapshot
    private let total: Int
    private let selectAllTotal: Int
    /// Whether any family main row is in scope; Library hides the family columns otherwise.
    nonisolated let hasFamilies: Bool
    /// Loaded once per snapshot so selection scopes and family counts don't re-run the projection per batch.
    private var cachedPlacements: [LibraryFamilyPlacement]?
    private var cachedSelectAll: [LibraryFamilyPlacement]?
    /// The snapshot never changes, so each family's members are read at most once.
    private var cachedFamilyMembers: [Int64: [LibraryFamilyPlacement]] = [:]

    private init(reader: DatabaseSnapshot, query: LibraryBrowseQuery, total: Int, selectAllTotal: Int, hasFamilies: Bool) {
        self.reader = reader
        signature = query
        self.total = total
        self.selectAllTotal = selectAllTotal
        self.hasFamilies = hasFamilies
    }

    static func open(pool: DatabasePool, query: LibraryBrowseQuery) async throws -> LibraryPagedSnapshot {
        try Task.checkCancellation()
        let reader = try pool.makeSnapshot()
        let counts = try reader.read { database in try query.counts(in: database) }
        try Task.checkCancellation()
        return LibraryPagedSnapshot(reader: reader, query: query, total: counts.visible, selectAllTotal: counts.selectAll, hasFamilies: counts.hasFamilies)
    }

    func count() -> Int {
        total
    }

    func selectAllCount() -> Int {
        selectAllTotal
    }

    func rows(in range: Range<Int>) throws -> [BrowserRow] {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, range.upperBound <= total else { throw PagingError.invalidRange }
        return try reader.read { database in try signature.rows(in: database, range: range) }
    }

    func index(of id: Int64) throws -> Int? {
        try Task.checkCancellation()
        return try reader.read { database in try signature.index(of: id, in: database) }
    }

    /// Every counted file, including alternates of collapsed families, so hidden selections stay in scope.
    func identities(after id: Int64?, limit: Int) throws -> [PagedIdentity<Int64>] {
        try slice(placements(), after: id, limit: limit)
    }

    /// The files Select all selects: main and standalone rows, plus eligible alternates when the query includes them.
    func selectAllIdentities(after id: Int64?, limit: Int) throws -> [PagedIdentity<Int64>] {
        if cachedSelectAll == nil {
            let includeAlternates = signature.includeAlternates
            cachedSelectAll = try placements().filter { placement in
                placement.role != .alternate || (includeAlternates && placement.isEligible)
            }
        }
        return try slice(cachedSelectAll ?? [], after: id, limit: limit)
    }

    func familyMembers(_ familyIds: Set<Int64>) throws -> [Int64: [LibraryFamilyPlacement]] {
        let missing = familyIds.subtracting(cachedFamilyMembers.keys)
        if !missing.isEmpty {
            try Task.checkCancellation()
            let loaded = try reader.read { database in try signature.familyPlacements(missing, in: database) }
            for familyID in missing {
                cachedFamilyMembers[familyID] = []
            }
            for placement in loaded {
                if let familyID = placement.familyId, missing.contains(familyID) {
                    cachedFamilyMembers[familyID, default: []].append(placement)
                }
            }
        }
        return cachedFamilyMembers.filter { familyID, _ in familyIds.contains(familyID) }
    }

    func identities(in range: Range<Int>) throws -> [PagedIdentity<Int64>] {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, range.upperBound <= total else { throw PagingError.invalidRange }
        return try reader.read { database in try signature.identities(in: database, range: range) }
    }

    nonisolated func identity(for row: BrowserRow) -> PagedIdentity<Int64> {
        .init(id: row.id, revision: row.membershipRevision)
    }

    private func placements() throws -> [LibraryFamilyPlacement] {
        try Task.checkCancellation()
        if let cachedPlacements {
            return cachedPlacements
        }
        let loaded = try reader.read { database in try signature.placements(in: database) }
        cachedPlacements = loaded
        return loaded
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
