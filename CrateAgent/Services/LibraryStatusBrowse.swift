import Foundation
import GRDB

enum LibraryStatusFilter: String, CaseIterable, Identifiable {
    case active, removedFromSerato, missing
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .active: "Active"
        case .removedFromSerato: LibraryMembership.retired.displayTitle
        case .missing: "Missing"
        }
    }

    var predicate: String {
        switch self {
        case .active: FileProcessingEligibility.activeSQL
        case .removedFromSerato: "files.library_membership = 'retired'"
        case .missing: "files.library_membership = 'active' AND files.file_availability != 'available'"
        }
    }

    var detail: String {
        switch self {
        case .active: "Current entries, including pending imports and unverified membership."
        case .removedFromSerato: "Retired entries keep their last normal path and History. Retirement does not move or restore audio."
        case .missing: "Serato still references these files. Offline volumes and access failures are shown separately."
        }
    }
}

enum LibraryStatusBrowse {
    struct Results: Equatable {
        let rows: [BrowserRow]
        let totalCount: Int
    }

    static func fetch(_ db: GRDB.Database, filter: LibraryStatusFilter = .active,
                      search: String = "", sortOrder: [KeyPathComparator<BrowserRow>] = [],
                      limit: Int = 1000, offset: Int = 0) throws -> Results
    {
        guard limit > 0, offset >= 0 else { throw BrowseError.invalidBounds }
        var predicate = filter.predicate
        var arguments: [DatabaseValueConvertible] = []
        if !search.isEmpty {
            predicate += " AND \(ListSearch.trackPredicate)"
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            arguments = [query, query, query, query]
        }
        guard let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE \(predicate)", arguments: StatementArguments(arguments)) else {
            throw BrowseError.missingCount
        }
        let order = LibraryBrowserView.orderByClause(for: sortOrder.first)
        arguments.append(contentsOf: [limit, offset])
        let rows = try BrowserRow.fetchAll(db, sql: BrowserRow.browserFetchSQL + " WHERE \(predicate) ORDER BY \(order), id ASC LIMIT ? OFFSET ?", arguments: StatementArguments(arguments))
        return Results(rows: rows, totalCount: count)
    }

    static func observation(filter: LibraryStatusFilter, search: String, sortOrder: [KeyPathComparator<BrowserRow>], limit: Int) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<Results>>> {
        ValueObservation.tracking { database in
            try fetch(database, filter: filter, search: search, sortOrder: sortOrder, limit: limit)
        }.removeDuplicates()
    }

    private enum BrowseError: LocalizedError {
        case invalidBounds, missingCount
        var errorDescription: String? {
            switch self {
            case .invalidBounds: "The requested library page is invalid."
            case .missingCount: "The library did not return a status count."
            }
        }
    }
}
