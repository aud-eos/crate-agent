@testable import CrateAgent
import GRDB
import XCTest

/// Library's song-family projection over a real WAL database: one main row per
/// family, alternates together beneath it, search-driven reveal, and the
/// selection scopes behind Select all and Include alternates.
final class LibraryFamilyProjectionTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var pool: DatabasePool!
    private var familyID: Int64 = 0
    private var main: Int64 = 0
    private var instrumental: Int64 = 0
    private var missingAcapella: Int64 = 0
    private var standalone: Int64 = 0

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryFamilies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try LibraryDatabase.openWAL(at: directory.appendingPathComponent("library.sqlite"))
        pool = try XCTUnwrap(database.writer as? DatabasePool)
        let ids = try await pool.write { connection in
            var family = SongFamilyRecord()
            try family.insert(connection)
            let familyID = try XCTUnwrap(family.id)
            func add(_ title: String, artist: String, family: Int64?, availability: FileAvailability = .available) throws -> Int64 {
                var trackID: Int64?
                if let family {
                    var track = TrackRecord(fingerprintHash: Data(title.utf8), title: title, workId: family)
                    try track.insert(connection)
                    trackID = track.id
                }
                var file = FileRecord(path: "/Music/\(title).mp3", volumeUuid: "volume", inode: Int64(title.hashValue), fileSize: 1, mtime: 1,
                                      trackId: trackID, artist: artist, title: title)
                file.libraryMembership = .active
                file.fileAvailability = availability
                try file.insert(connection)
                return try XCTUnwrap(file.id)
            }
            return try (familyID,
                        add("Song (Instrumental)", artist: "Zed", family: familyID),
                        add("Song (Original Mix)", artist: "Aaron", family: familyID),
                        add("Song (Acapella)", artist: "Zed", family: familyID, availability: .missing),
                        add("Other", artist: "Bob", family: nil))
        }
        (familyID, instrumental, main, missingAcapella, standalone) = ids
    }

    override func tearDown() async throws {
        try pool.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testFamiliesCollapseToTheirMainRowAndExpandBeneathItInSortOrder() async throws {
        var query = LibraryBrowseQuery(sort: .init(column: .artist))
        let collapsed = try await rows(query)
        XCTAssertEqual(collapsed.map(\.id), [main, standalone])
        XCTAssertEqual(collapsed.first?.familyVersions, 3)

        query.expandedFamilies = [familyID]
        let expanded = try await rows(query)
        XCTAssertEqual(expanded.map(\.id), [main, instrumental, missingAcapella, standalone])
        XCTAssertEqual(expanded.map(\.familyRole), [.main, .alternate, .alternate, .standalone])
    }

    func testSearchRevealsMatchingAlternatesWithTheirMainRowOnly() async throws {
        let matched = try await rows(LibraryBrowseQuery(search: "Instrumental"))
        XCTAssertEqual(matched.map(\.id), [main, instrumental])
        let standaloneOnly = try await rows(LibraryBrowseQuery(search: "Bob"))
        XCTAssertEqual(standaloneOnly.map(\.id), [standalone])
    }

    func testSelectAllTakesMainRowsAndOnlyEligibleAlternatesWhenIncluded() async throws {
        let store = try LibrarySelectionStore(database: database)
        let mainRows = try await LibraryPagedSnapshot.open(pool: pool, query: LibraryBrowseQuery())
        try await store.setScope(mainRows, selected: true)
        let mainSelection = try await store.selectedIDs(limit: 10)
        XCTAssertEqual(Set(mainSelection), [main, standalone])

        let withAlternates = try await LibraryPagedSnapshot.open(pool: pool, query: LibraryBrowseQuery(includeAlternates: true))
        try await store.setScope(withAlternates, selected: true)
        let all = try await store.selectedIDs(limit: 10)
        XCTAssertEqual(Set(all), [main, standalone, instrumental])
        let summary = try await store.summary(in: mainRows)
        XCTAssertEqual(summary.hidden, 0)
        XCTAssertEqual(summary.scopeSelected, summary.scopeCount)
        await store.close()
    }

    private func rows(_ query: LibraryBrowseQuery) async throws -> [BrowserRow] {
        let snapshot = try await LibraryPagedSnapshot.open(pool: pool, query: query)
        return try await snapshot.rows(in: 0 ..< snapshot.count())
    }
}
