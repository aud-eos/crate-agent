import Foundation
import GRDB

actor LibraryPagedSnapshot: PagedQuerySnapshot {
    typealias Row = BrowserRow
    nonisolated let signature: LibraryBrowseQuery
    private let reader: DatabaseSnapshot
    private let total: Int

    private init(reader: DatabaseSnapshot, query: LibraryBrowseQuery, total: Int) {
        self.reader = reader
        signature = query
        self.total = total
    }

    static func open(pool: DatabasePool, query: LibraryBrowseQuery) async throws -> LibraryPagedSnapshot {
        try Task.checkCancellation()
        let reader = try pool.makeSnapshot()
        let total = try reader.read { database in try query.count(in: database) }
        try Task.checkCancellation()
        return LibraryPagedSnapshot(reader: reader, query: query, total: total)
    }

    func count() -> Int {
        total
    }

    func rows(in range: Range<Int>) throws -> [BrowserRow] {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, range.upperBound <= total else { throw PagingError.invalidRange }
        return try reader.read { database in try signature.rows(in: database, range: range) }
    }

    func index(of id: Int64) throws -> Int? {
        try Task.checkCancellation()
        return try reader.read { database in
            try Int.fetchOne(database, sql: """
            SELECT position FROM (
                SELECT files.id, ROW_NUMBER() OVER (ORDER BY \(signature.sort.sql)) - 1 AS position
                FROM files WHERE \(signature.predicate)
            ) WHERE id = ?
            """, arguments: signature.arguments + [id])
        }
    }

    func identities(after id: Int64?, limit: Int) throws -> [PagedIdentity<Int64>] {
        try Task.checkCancellation()
        guard limit > 0 else { throw PagingError.invalidRange }
        return try reader.read { database in
            let predicate = signature.predicate + (id == nil ? "" : " AND files.id > ?")
            var arguments = signature.arguments
            if let id {
                arguments += [id]
            }
            arguments += [limit]
            return try GRDB.Row.fetchAll(database, sql: "SELECT files.id, files.membership_revision FROM files WHERE \(predicate) ORDER BY files.id LIMIT ?", arguments: arguments)
                .map { row in .init(id: row["id"], revision: row["membership_revision"]) }
        }
    }

    func identities(in range: Range<Int>) throws -> [PagedIdentity<Int64>] {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, range.upperBound <= total else { throw PagingError.invalidRange }
        return try reader.read { database in
            try GRDB.Row.fetchAll(database, sql: "SELECT files.id, files.membership_revision FROM files WHERE \(signature.predicate) ORDER BY \(signature.sort.sql) LIMIT ? OFFSET ?", arguments: signature.arguments + [range.count, range.lowerBound])
                .map { row in .init(id: row["id"], revision: row["membership_revision"]) }
        }
    }

    nonisolated func identity(for row: BrowserRow) -> PagedIdentity<Int64> {
        .init(id: row.id, revision: row.membershipRevision)
    }
}
