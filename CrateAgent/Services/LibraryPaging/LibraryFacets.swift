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

enum BPMRangeError: LocalizedError, Equatable {
    case notANumber
    case negative
    case reversed

    var errorDescription: String? {
        switch self {
        case .notANumber: LibraryChecklistMessages.bpmNotNumber
        case .negative: LibraryChecklistMessages.bpmNegative
        case .reversed: LibraryChecklistMessages.bpmReversed
        }
    }
}

extension LibraryFacets {
    /// An open lower end; BPM 0 never matches, so it adds no bound.
    static let openLowerBPM = 0.0
    static let openUpperBPM = Double.greatestFiniteMagnitude

    /// The inclusive range typed into the two BPM fields. An empty field, or a lower end of 0, is an open end,
    /// and two open ends are no range, so the result always reads back from `bpmText`.
    static func bpmRange(lower lowerText: String, upper upperText: String) throws -> ClosedRange<Double>? {
        let lower = try bpm(lowerText) ?? openLowerBPM
        let upper = try bpm(upperText) ?? openUpperBPM
        guard lower <= upper else { throw BPMRangeError.reversed }
        return lower == openLowerBPM && upper == openUpperBPM ? nil : lower ... upper
    }

    /// The field text that `bpmRange(lower:upper:)` reads back as `range`; an open end is empty.
    static func bpmText(_ range: ClosedRange<Double>?) -> (lower: String, upper: String) {
        guard let range else { return ("", "") }
        return (range.lowerBound == openLowerBPM ? "" : text(range.lowerBound), range.upperBound == openUpperBPM ? "" : text(range.upperBound))
    }

    /// Nil for an empty field; a finite, non-negative number, or an error.
    private static func bpm(_ text: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value.isFinite else { throw BPMRangeError.notANumber }
        guard value >= 0 else { throw BPMRangeError.negative }
        return value
    }

    /// Plain digits that `Double(_:)` reads back, whatever the locale.
    private static func text(_ bpm: Double) -> String {
        bpm == bpm.rounded() && bpm < 1_000_000 ? String(Int(bpm)) : String(bpm)
    }
}

/// One genre as the user sees it: every stored spelling that differs only in case, width or
/// whitespace, shown as its most frequent spelling. The facet matches `storedValues` exactly.
struct GenreOption: Hashable, Sendable {
    let value: String
    let storedValues: Set<String>
    let count: Int

    /// Trimmed, whitespace collapsed, and folded for case and width; diacritics stay distinct.
    static func normalized(_ genre: String) -> String {
        genre.split(whereSeparator: BlankText.isWhitespace).joined(separator: " ").folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// Groups each distinct stored genre and its file count by normalized form, ordered by display value; blank genres join no group.
    static func grouped(_ stored: [(value: String, count: Int)]) -> [GenreOption] {
        Dictionary(grouping: stored) { genre in normalized(genre.value) }.filter { group in !group.key.isEmpty }.values.compactMap { spellings -> GenreOption? in
            guard let commonest = spellings.max(by: { lhs, rhs in lhs.count != rhs.count ? lhs.count < rhs.count : lhs.value > rhs.value })
            else { return nil }
            return GenreOption(value: commonest.value, storedValues: Set(spellings.map(\.value)),
                               count: spellings.reduce(0) { total, genre in total + genre.count })
        }.sorted { lhs, rhs in lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending }
    }
}

/// The values the facets can choose from in a status scope: each genre with its file count, and each
/// stored key string grouped by the Camelot key it parses to. A key string no notation parses joins no key.
struct LibraryFacetOptions: Equatable, Sendable {
    let genres: [GenreOption]
    let keys: [CamelotKey: Set<String>]

    /// Distinct non-blank genres and keys of the files `filter` admits, one pass each.
    static func load(in database: GRDB.Database, filter: LibraryStatusFilter) throws -> LibraryFacetOptions {
        let genreRows = try GRDB.Row.fetchAll(database, sql: """
        SELECT files.genre, COUNT(*) FROM files
        WHERE \(filter.predicate) AND NOT \(BlankText.isBlankSQL("files.genre")) GROUP BY files.genre
        """)
        let genres = try GenreOption.grouped(genreRows.map { row -> (value: String, count: Int) in
            guard let value: String = row[0], let count: Int = row[1] else { throw PagingError.incompletePage }
            return (value, count)
        })
        let keyValues = try String.fetchAll(database, sql: """
        SELECT DISTINCT files.musical_key FROM files WHERE \(filter.predicate) AND NOT \(BlankText.isBlankSQL("files.musical_key"))
        """)
        var keys: [CamelotKey: Set<String>] = [:]
        for value in keyValues {
            if let key = CamelotKey(parsing: value) {
                keys[key, default: []].insert(value)
            }
        }
        return LibraryFacetOptions(genres: genres, keys: keys)
    }

    /// Every stored key string that parses to a key compatible with `key`.
    func keyValues(compatibleWith key: CamelotKey) -> Set<String> {
        key.compatibleKeys.reduce(into: Set<String>()) { values, compatible in values.formUnion(keys[compatible] ?? []) }
    }
}
