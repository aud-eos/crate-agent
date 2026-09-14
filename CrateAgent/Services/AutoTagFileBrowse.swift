import Foundation
import GRDB

enum AutoTagBrowseFilter: String, CaseIterable, Identifiable {
    case either
    case missingMetadata
    case unmatched

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .either: "Missing library fields or not matched"
        case .missingMetadata: "Missing library fields"
        case .unmatched: "Not matched to MusicBrainz"
        }
    }
}

enum AutoTagFileBrowse {
    static let pageSize = 200

    struct Results {
        let matches: [BrowserRow]
        let totalMatchCount: Int
        let page: Int

        var hasNextPage: Bool {
            page < (max(totalMatchCount, 1) - 1) / AutoTagFileBrowse.pageSize
        }

        static let empty = Results(matches: [], totalMatchCount: 0, page: 0)
    }

    static func browse(filter: AutoTagBrowseFilter = .either, page: Int = 0, in db: GRDB.Database) throws -> Results {
        let (offset, overflow) = page.multipliedReportingOverflow(by: pageSize)
        guard page >= 0, !overflow else { throw BrowseError.invalidPage }
        let missingFields = ["files.artist", "files.title", "files.album"]
            .map { column in "trim(COALESCE(\(column), ''), :whitespace) = ''" }
            .joined(separator: " OR ")
        let unmatched = "trim(COALESCE(tracks.musicbrainz_recording_id, ''), :whitespace) = ''"
        let predicate: String
        switch filter {
        case .either: predicate = "(\(missingFields)) OR (\(unmatched))"
        case .missingMetadata: predicate = missingFields
        case .unmatched: predicate = unmatched
        }
        let source = """
        FROM files LEFT JOIN tracks ON tracks.id = files.track_id
        WHERE \(predicate)
        """
        let countArguments: StatementArguments = ["whitespace": whitespaceCharacters]
        guard let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) \(source)", arguments: countArguments) else {
            throw BrowseError.missingCount
        }
        let matches = try BrowserRow.fetchAll(
            db,
            sql: """
            SELECT files.id, files.path, files.artist, files.title, files.album, files.bpm, files.musical_key
            \(source)
            ORDER BY files.artist, files.title, files.id
            LIMIT :limit OFFSET :offset
            """,
            arguments: ["whitespace": whitespaceCharacters, "limit": pageSize, "offset": offset]
        )
        return Results(matches: matches, totalMatchCount: total, page: page)
    }

    /// SQLite's default trim handles ASCII space only. Match Unicode whitespace
    /// in SQL so opening the browser never materializes every file in Swift.
    private static let whitespaceCharacters = "\t\n\u{b}\u{c}\r \u{85}\u{a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}"

    private enum BrowseError: LocalizedError {
        case invalidPage
        case missingCount

        var errorDescription: String? {
            switch self {
            case .invalidPage: "The requested Auto-Tag browser page is invalid."
            case .missingCount: "The library did not return an Auto-Tag browser count."
            }
        }
    }
}
