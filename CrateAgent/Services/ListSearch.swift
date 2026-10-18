import Foundation
import GRDB

enum ListSearch {
    static let prompt = "Search artist, title, album, or path"
    static let clearLabel = "Clear search"
    static let functionName = "list_contains"
    static var trackPredicate: String {
        predicate()
    }

    /// ASCII text, most of a library, is matched by SQLite itself; the Swift
    /// fold runs only for a field or search with other characters, whose byte
    /// length differs from its character length. Calling into Swift for every
    /// row is what took a searched 30,000-file Library view over its budget.
    static func predicate(prefix: String = "", parameter: String = ":query") -> String {
        let text = "(" + ["artist", "title", "album", "path"].map { field in "COALESCE(\(prefix)\(field), '')" }
            .joined(separator: " || char(10) || ") + ")"
        let folds = "length(CAST(\(text) AS BLOB)) != length(\(text)) OR length(CAST(\(parameter) AS BLOB)) != length(\(parameter))"
        return "(instr(lower(\(text)), lower(\(parameter))) > 0 OR ((\(folds)) AND \(functionName)(\(text), \(parameter))))"
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
