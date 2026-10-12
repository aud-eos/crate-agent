import Foundation
import GRDB

enum ListSearch {
    static let prompt = "Search artist, title, album, or path"
    static let clearLabel = "Clear search"
    static let functionName = "list_contains"
    static var trackPredicate: String {
        predicate()
    }

    static func predicate(prefix: String = "", parameter: String = "?") -> String {
        "(" + ["artist", "title", "album", "path"].map { field in
            "\(functionName)(\(prefix)\(field), \(parameter))"
        }.joined(separator: " OR ") + ")"
    }

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
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
