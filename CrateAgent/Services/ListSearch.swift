import Foundation
import GRDB

enum ListSearch {
    static let prompt = "Search artist, title, album, or path"
    static let clearLabel = "Clear search"
    static let functionName = "list_contains"
    static var trackPredicate: String {
        predicate()
    }

    /// Pure-ASCII fields and searches, most of a library, are matched by
    /// SQLite itself, which equals the Swift fold for ASCII; anything else,
    /// detected by a byte length that differs from the character length, goes
    /// through the fold. Calling into Swift for every field of every row is
    /// what took a searched 30,000-file Library view over its budget.
    static func predicate(prefix: String = "", parameter: String = ":query") -> String {
        let asciiSearch = isASCII(parameter)
        return "(" + ["artist", "title", "album", "path"].map { field in
            let column = "\(prefix)\(field)"
            return "(CASE WHEN \(column) IS NULL THEN 0 WHEN \(asciiSearch) AND \(isASCII(column)) "
                + "THEN instr(lower(\(column)), lower(\(parameter))) > 0 ELSE \(functionName)(\(column), \(parameter)) END)"
        }.joined(separator: " OR ") + ")"
    }

    private static func isASCII(_ expression: String) -> String {
        "length(CAST(\(expression) AS BLOB)) = length(\(expression))"
    }

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func text(artist: String?, title: String?, album: String?, path: String) -> String {
        [artist ?? "", title ?? "", album ?? "", path].joined(separator: "\n")
    }

    static func index(_ files: [some HygieneFileSource]) -> [String: String] {
        files.reduce(into: [:]) { index, file in
            index[file.path, default: ""] += text(artist: file.artist, title: file.title, album: file.album, path: file.path) + "\n"
        }
    }

    static func register(in database: GRDB.Database) {
        database.add(function: DatabaseFunction(functionName, argumentCount: 2, pure: true) { values in
            guard let haystack = String.fromDatabaseValue(values[0]), let needle = String.fromDatabaseValue(values[1]) else { return false }
            return needle.isEmpty || normalized(haystack).contains(normalized(needle))
        })
    }
}
