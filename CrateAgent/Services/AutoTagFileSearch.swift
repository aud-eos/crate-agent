import GRDB

struct AutoTagSearchState {
    var query = "" {
        didSet {
            guard query.trimmingCharacters(in: .whitespacesAndNewlines)
                != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            completedQuery = nil
            storedResults = .empty
            storedError = nil
        }
    }

    private var completedQuery: String?
    private var storedResults = AutoTagFileSearch.Results.empty
    private var storedError: String?

    private var hasCurrentOutcome: Bool {
        completedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var results: AutoTagFileSearch.Results {
        hasCurrentOutcome ? storedResults : .empty
    }

    var error: String? {
        hasCurrentOutcome ? storedError : nil
    }

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasCurrentOutcome
    }

    mutating func beginSearch() {
        completedQuery = nil
        storedResults = .empty
        storedError = nil
    }

    mutating func publish(_ outcome: Result<AutoTagFileSearch.Results, Error>, for completedQuery: String) {
        guard completedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        self.completedQuery = completedQuery
        switch outcome {
        case let .success(results):
            storedResults = results
            storedError = nil
        case let .failure(error):
            storedResults = .empty
            storedError = error.localizedDescription
        }
    }
}

enum AutoTagFileSearch {
    static let resultCap = 200

    struct Results {
        let matches: [BrowserRow]
        let totalMatchCount: Int
        var page = 0

        var hasNextPage: Bool {
            page < (max(totalMatchCount, 1) - 1) / AutoTagFileSearch.resultCap
        }

        static let empty = Results(matches: [], totalMatchCount: 0)

        var isCapped: Bool {
            totalMatchCount > matches.count
        }
    }

    /// Runs on the caller's `GRDB.Database` — call from within a
    /// `database.writer.read` block, off the main actor.
    static func search(query: String, page: Int = 0, in db: GRDB.Database) throws -> Results {
        guard page >= 0, page <= Int.max / resultCap else { throw SearchError.invalidPage }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return .empty }

        let whereClause = "WHERE \(FileProcessingEligibility.activeSQL) AND \(ListSearch.trackPredicate)"
        let pattern = trimmedQuery

        let matches = try BrowserRow.fetchAll(
            db,
            sql: """
            \(BrowserRow.browserFetchSQL)
            \(whereClause)
            ORDER BY artist, title, id
            LIMIT :limit OFFSET :offset
            """,
            arguments: ["query": pattern, "limit": resultCap, "offset": page * resultCap]
        )

        let totalMatchCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM files \(whereClause)",
            arguments: ["query": pattern]
        ) ?? matches.count

        return Results(matches: matches, totalMatchCount: totalMatchCount, page: page)
    }

    private enum SearchError: Error { case invalidPage }
}
