@testable import CrateAgent
import GRDB
import XCTest

/// Unit tests for `AutoTagFileSearch` — the bounded, artist/title
/// search behind the Auto-Tag panel's selection stage. Exercises the
/// query logic directly against an in-memory database (mirrors
/// `AutoTaggerServiceTests`'s fixture style); the SwiftUI layer
/// (`AutoTaggerView`, `AutoTagSelectionRow`) is verified by build only.
final class AutoTagFileSearchTests: XCTestCase {
    private var inodeCounter: Int64 = 0

    private func makeDatabase() throws -> LibraryDatabase {
        try LibraryDatabase.openInMemory()
    }

    @discardableResult
    private func insertFile(
        in database: LibraryDatabase,
        artist: String?,
        title: String?
    ) throws -> Int64 {
        inodeCounter += 1
        var record = FileRecord(
            path: "/music/\(inodeCounter).mp3",
            volumeUuid: "VOL",
            inode: inodeCounter,
            fileSize: 1000,
            mtime: 0,
            artist: artist,
            title: title
        )
        try database.writer.write { db in
            try record.insert(db)
        }
        return try XCTUnwrap(record.id)
    }

    // MARK: - Empty query

    func testEmptyQueryMatchesNothing() throws {
        let database = try makeDatabase()
        try insertFile(in: database, artist: "Aphex Twin", title: "Windowlicker")

        let results = try database.writer.read { db in
            try AutoTagFileSearch.search(query: "   ", in: db)
        }

        XCTAssertEqual(results.matches, [])
        XCTAssertEqual(results.totalMatchCount, 0)
        XCTAssertFalse(results.isCapped)
    }

    // MARK: - Matching

    func testMatchesArtistCaseInsensitively() throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, artist: "Aphex Twin", title: "Windowlicker")
        try insertFile(in: database, artist: "Boards of Canada", title: "Roygbiv")

        let results = try database.writer.read { db in
            try AutoTagFileSearch.search(query: "aphex", in: db)
        }

        XCTAssertEqual(results.matches.map(\.id), [fileID])
        XCTAssertEqual(results.totalMatchCount, 1)
    }

    func testMatchesTitleCaseInsensitively() throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, artist: "Squarepusher", title: "My Red Hot Car")
        try insertFile(in: database, artist: "Boards of Canada", title: "Roygbiv")

        let results = try database.writer.read { db in
            try AutoTagFileSearch.search(query: "RED HOT", in: db)
        }

        XCTAssertEqual(results.matches.map(\.id), [fileID])
    }

    func testLikeMetacharactersMatchLiterally() throws {
        let database = try makeDatabase()
        let percentFileID = try insertFile(in: database, artist: "50% Off", title: nil)
        try insertFile(in: database, artist: "50 Cent", title: nil)

        let results = try database.writer.read { db in
            try AutoTagFileSearch.search(query: "50%", in: db)
        }

        XCTAssertEqual(results.matches.map(\.id), [percentFileID])
    }

    // MARK: - Cap

    func testResultsAreCappedAndReportTotalMatchCount() throws {
        let database = try makeDatabase()
        let overCapCount = AutoTagFileSearch.resultCap + 25
        for index in 0 ..< overCapCount {
            try insertFile(in: database, artist: "Capped Artist", title: "Track \(index)")
        }

        let results = try database.writer.read { db in
            try AutoTagFileSearch.search(query: "Capped", in: db)
        }

        XCTAssertEqual(results.matches.count, AutoTagFileSearch.resultCap)
        XCTAssertEqual(results.totalMatchCount, overCapCount)
        XCTAssertTrue(results.isCapped)
    }

    func testResultsUnderCapAreNotReportedAsCapped() throws {
        let database = try makeDatabase()
        try insertFile(in: database, artist: "Uncapped Artist", title: "Only Track")

        let results = try database.writer.read { db in
            try AutoTagFileSearch.search(query: "Uncapped", in: db)
        }

        XCTAssertEqual(results.matches.count, 1)
        XCTAssertEqual(results.totalMatchCount, 1)
        XCTAssertFalse(results.isCapped)
    }

    // MARK: - Non-matches

    func testNoMatchesReturnsEmptyResults() throws {
        let database = try makeDatabase()
        try insertFile(in: database, artist: "Boards of Canada", title: "Roygbiv")

        let results = try database.writer.read { db in
            try AutoTagFileSearch.search(query: "Nonexistent Query", in: db)
        }

        XCTAssertEqual(results.matches, [])
        XCTAssertEqual(results.totalMatchCount, 0)
    }
}
