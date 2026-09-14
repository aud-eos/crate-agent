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

    var error: String? { hasCurrentOutcome ? storedError : nil }

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasCurrentOutcome
    }

    mutating func publish(_ outcome: Result<AutoTagFileSearch.Results, Error>, for completedQuery: String) {
        guard completedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        self.completedQuery = completedQuery
        switch outcome {
        case .success(let results):
            storedResults = results
            storedError = nil
        case .failure(let error):
            storedResults = .empty
            storedError = error.localizedDescription
        }
    }
}

/// Bounded file search behind the Auto-Tag panel's selection stage.
///
/// Matches artist/title/path (not album — `LibraryBrowserView`'s
/// broader match is a different surface with a different job) and
/// never returns more than `resultCap` rows, so picking tracks to
/// scan never materializes the whole library into memory or into a
/// SwiftUI `List`. Path is included so files with NO artist and NO
/// title — exactly the files that most need auto-tagging, and which
/// an artist/title-only search could never surface — stay selectable
/// by filename (finding #4001064044). An empty (or whitespace-only)
/// query matches nothing — the selection stage prompts the user to
/// search rather than falling back to "show everything".
///
/// Returns `BrowserRow` — already the library's lightweight files
/// projection (id/path/artist/title/album/bpm/musicalKey) used by
/// `LibraryBrowserView` — rather than a bespoke type. The selection
/// list only needs a handful of display fields, and `BrowserRow`
/// already is that shape.
enum AutoTagFileSearch {
    /// Hard cap on rows a single search returns. Mirrors
    /// `LibraryBrowserView.visibleRowCap`'s reasoning at a smaller
    /// number: the selection list is a picker, not a browser, so a
    /// tighter cap keeps every search snappy even on a cold cache.
    static let resultCap = 200

    struct Results {
        let matches: [BrowserRow]
        let totalMatchCount: Int

        static let empty = Results(matches: [], totalMatchCount: 0)

        /// True when more rows matched than we returned — drives the
        /// "showing first N of M" note in the selection list.
        var isCapped: Bool {
            totalMatchCount > matches.count
        }
    }

    /// Runs on the caller's `GRDB.Database` — call from within a
    /// `database.writer.read` block, off the main actor.
    static func search(query: String, in db: GRDB.Database) throws -> Results {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return .empty }

        // SQLite LIKE with `COLLATE NOCASE` does case-insensitive
        // matching on ASCII, matching LibraryBrowserView's existing
        // approach. `ESCAPE '\'` plus escapeLikeMetacharacters below
        // makes a literal "%" or "_" typed by the user match itself
        // instead of being interpreted as a LIKE wildcard.
        let whereClause = """
        WHERE (COALESCE(artist, '') LIKE ? ESCAPE '\\' COLLATE NOCASE)
           OR (COALESCE(title, '') LIKE ? ESCAPE '\\' COLLATE NOCASE)
           OR (COALESCE(path, '') LIKE ? ESCAPE '\\' COLLATE NOCASE)
        """
        let pattern = "%\(escapeLikeMetacharacters(trimmedQuery))%"

        let matches = try BrowserRow.fetchAll(
            db,
            sql: """
            SELECT id, path, artist, title, album, bpm, musical_key
            FROM files
            \(whereClause)
            ORDER BY artist, title
            LIMIT ?
            """,
            arguments: [pattern, pattern, pattern, resultCap]
        )

        let totalMatchCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM files \(whereClause)",
            arguments: [pattern, pattern, pattern]
        ) ?? matches.count

        return Results(matches: matches, totalMatchCount: totalMatchCount)
    }

    /// Escapes SQLite LIKE metacharacters (`%`, `_`, and the escape
    /// character itself) in user-typed search text so a literal
    /// "50%" or "a_b" matches those characters instead of being
    /// interpreted as LIKE wildcards.
    static func escapeLikeMetacharacters(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
