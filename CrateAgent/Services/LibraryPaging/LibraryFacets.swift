import Foundation
import GRDB

/// The Library's genre, BPM-range and compatible-key filters, matched in SQL against stored values.
/// An empty facet adds no predicate. `keyValues` holds the stored key strings that `compatibleKey`
/// resolves to through `LibraryFacetOptions`; with a key chosen and none resolved, nothing matches.
struct LibraryFacets: Hashable, Sendable {
    var genres: Set<String> = []
    var bpmRange: ClosedRange<Double>?
    var compatibleKey: CamelotKey?
    var keyValues: Set<String> = []

    var isEmpty: Bool {
        genres.isEmpty && bpmRange == nil && compatibleKey == nil
    }

    /// One predicate per chosen facet over `files`, using `arguments()`.
    var predicates: [String] {
        var terms: [String] = []
        if !genres.isEmpty {
            terms.append("files.genre IN (SELECT value FROM json_each(:genres))")
        }
        if bpmRange != nil {
            terms.append("CAST(files.bpm AS REAL) BETWEEN :bpm_min AND :bpm_max AND CAST(files.bpm AS REAL) > 0")
        }
        if compatibleKey != nil {
            terms.append("files.musical_key IN (SELECT value FROM json_each(:keys))")
        }
        return terms
    }

    func arguments() throws -> StatementArguments {
        try [
            "genres": Self.json(genres), "keys": Self.json(keyValues),
            "bpm_min": bpmRange?.lowerBound ?? 0, "bpm_max": bpmRange?.upperBound ?? 0,
        ]
    }

    private static func json(_ values: Set<String>) throws -> String {
        try String(decoding: JSONEncoder().encode(values.sorted()), as: UTF8.self)
    }
}

struct GenreOption: Hashable, Sendable {
    let value: String
    let count: Int
}

/// The values the facets can choose from in a status scope: each stored genre with its file count,
/// and each stored key string grouped by the Camelot key it parses to. Key strings no notation
/// parses are listed as unrecognized, never guessed.
struct LibraryFacetOptions: Equatable, Sendable {
    let genres: [GenreOption]
    let keys: [CamelotKey: Set<String>]
    let unrecognizedKeys: Set<String>

    /// Distinct non-blank genres and keys of the files `filter` admits, one pass each.
    static func load(in database: GRDB.Database, filter: LibraryStatusFilter) throws -> LibraryFacetOptions {
        let genreRows = try GRDB.Row.fetchAll(database, sql: """
        SELECT files.genre, COUNT(*) FROM files
        WHERE \(filter.predicate) AND NULLIF(TRIM(files.genre), '') IS NOT NULL GROUP BY files.genre
        """)
        let genres = try genreRows.map { row -> GenreOption in
            guard let value: String = row[0], let count: Int = row[1] else { throw PagingError.incompletePage }
            return GenreOption(value: value, count: count)
        }.sorted { lhs, rhs in lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending }
        let keyValues = try String.fetchAll(database, sql: """
        SELECT DISTINCT files.musical_key FROM files WHERE \(filter.predicate) AND NULLIF(TRIM(files.musical_key), '') IS NOT NULL
        """)
        var keys: [CamelotKey: Set<String>] = [:]
        var unrecognized: Set<String> = []
        for value in keyValues {
            if let key = CamelotKey(parsing: value) {
                keys[key, default: []].insert(value)
            } else {
                unrecognized.insert(value)
            }
        }
        return LibraryFacetOptions(genres: genres, keys: keys, unrecognizedKeys: unrecognized)
    }

    /// Every stored key string that parses to a key compatible with `key`.
    func keyValues(compatibleWith key: CamelotKey) -> Set<String> {
        key.compatibleKeys.reduce(into: Set<String>()) { values, compatible in values.formUnion(keys[compatible] ?? []) }
    }
}
