import Foundation
import GRDB

struct LibraryBrowseSort: Hashable, Sendable {
    enum Column: String, Sendable {
        case artist, title, bpm, musicalKey, album, path
        var sql: String {
            switch self {
            case .artist: "COALESCE(files.artist, '')"
            case .title: "COALESCE(files.title, '')"
            case .bpm: "COALESCE(files.bpm, '')"
            case .musicalKey: "COALESCE(files.musical_key, '')"
            case .album: "COALESCE(files.album, '')"
            case .path: "files.path"
            }
        }
    }

    var column: Column = .path
    var ascending = true
    var sql: String {
        "\(column.sql) \(ascending ? "ASC" : "DESC"), files.id ASC"
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

struct LibraryBrowseQuery: Hashable, Sendable {
    var filter: LibraryStatusFilter = .active
    var search = ""
    var sort = LibraryBrowseSort()

    var predicate: String {
        filter.predicate + (search.isEmpty ? "" : " AND \(ListSearch.trackPredicate)")
    }

    var arguments: StatementArguments {
        guard !search.isEmpty else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return [query, query, query, query]
    }

    func count(in database: GRDB.Database) throws -> Int {
        guard let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM files WHERE \(predicate)", arguments: arguments) else {
            throw PagingError.incompletePage
        }
        return count
    }

    func rows(in database: GRDB.Database, range: Range<Int>) throws -> [BrowserRow] {
        guard range.lowerBound >= 0 else { throw PagingError.invalidRange }
        return try BrowserRow.fetchAll(database, sql: BrowserRow.browserFetchSQL + " WHERE \(predicate) ORDER BY \(sort.sql) LIMIT ? OFFSET ?",
                                       arguments: arguments + [range.count, range.lowerBound])
    }
}
