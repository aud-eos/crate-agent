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
            var nextInode: Int64 = 0
            func add(_ title: String, artist: String, family: Int64?, availability: FileAvailability = .available) throws -> Int64 {
                nextInode += 1
                var trackID: Int64?
                if let family {
                    var track = TrackRecord(fingerprintHash: Data(title.utf8), title: title, workId: family)
                    try track.insert(connection)
                    trackID = track.id
                }
                var file = FileRecord(path: "/Music/\(title).mp3", volumeUuid: "volume", inode: nextInode, fileSize: 1, mtime: 1,
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
        let mainSelection = try await store.selectedIdentities(in: mainRows, limit: 10)
        XCTAssertEqual(Set(mainSelection.map(\.id)), [main, standalone])

        let withAlternates = try await LibraryPagedSnapshot.open(pool: pool, query: LibraryBrowseQuery(includeAlternates: true))
        try await store.setScope(withAlternates, selected: true)
        let all = try await store.selectedIdentities(in: mainRows, limit: 10)
        XCTAssertEqual(Set(all.map(\.id)), [main, standalone, instrumental])
        let summary = try await store.summary(in: mainRows)
        XCTAssertEqual(summary.hidden, 0)
        XCTAssertEqual(summary.scopeSelected, summary.scopeCount)

        try await store.setScope(mainRows, selected: false)
        let cleared = try await store.selectedIdentities(in: mainRows, limit: 10)
        XCTAssertEqual(cleared, [])
        await store.close()
    }

    @MainActor
    func testFamilyCommandsTargetTheClickedRowUnlessItIsSelectedThenTheShownSelection() async throws {
        let model = try LibraryBrowserModel(database: database)
        defer { model.stop() }
        await model.start()
        await pagingEventually { model.results.row(at: 0) != nil }
        let snapshot = try XCTUnwrap(model.results.snapshot)
        let mainRow = try XCTUnwrap(model.results.cachedRows.first { row in row.id == main })
        model.selection.set([snapshot.identity(for: mainRow), .init(id: instrumental, revision: 0), .init(id: standalone, revision: 0)], selected: true)
        await pagingEventually { model.selection.summary?.total == 3 && !model.selection.isBusy }

        model.selection.set([snapshot.identity(for: mainRow)], selected: false)
        await pagingEventually { !model.selection.visibleSelectedIDs.contains(self.main) }
        let unselected = try await model.familyActionTarget(for: mainRow)
        XCTAssertEqual(unselected.files.map(\.id), [main])

        model.selection.set([snapshot.identity(for: mainRow)], selected: true)
        var searching = model.query
        searching.search = "Song"
        model.setQuery(searching)
        await pagingEventually {
            model.results.totalCount == 3 && model.results.row(at: 0) != nil && model.selection.visibleSelectedIDs.contains(self.main)
        }
        let shownMain = try XCTUnwrap(model.results.cachedRows.first { row in row.id == main })
        let selected = try await model.familyActionTarget(for: shownMain)
        XCTAssertEqual(Set(selected.files.map(\.id)), [main, instrumental])
    }

    @MainActor
    func testAFileThatChangedAfterItWasShownRefusesTheFamilyCommand() async throws {
        let engine = OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }),
                                     seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")))
        let actions = LibraryFamilyActions(families: SongFamilyService(engine: engine, database: database))
        let shown = try await rows(LibraryBrowseQuery(expandedFamilies: [familyID]))
        let mainRow = try XCTUnwrap(shown.first { row in row.id == main })
        let target = LibraryFamilyActionTarget(clicked: mainRow, files: [.init(id: main, revision: 0), .init(id: instrumental, revision: 0)])
        try await pool.write { connection in
            try connection.execute(sql: "UPDATE files SET membership_revision = membership_revision + 1 WHERE id = ?", arguments: [self.instrumental])
        }

        await XCTAssertThrowsErrorAsync(try await actions.perform(.remove, on: target)) { error in
            guard case FileProcessingEligibilityError.superseded(self.instrumental) = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let family = try await pool.read { connection in try Int64.fetchAll(connection, sql: "SELECT id FROM tracks WHERE work_id = ?", arguments: [self.familyID]) }
        XCTAssertEqual(family.count, 3)
    }

    func testAFamilyLeftWithOneLiveVersionIsShownAsStandaloneRowsWithoutFamilyCommands() async throws {
        try await pool.write { connection in
            try connection.execute(sql: "UPDATE files SET library_membership = ? WHERE id IN (?, ?)",
                                   arguments: [LibraryMembership.retired.rawValue, self.instrumental, self.missingAcapella])
        }
        let active = try await rows(LibraryBrowseQuery(expandedFamilies: [familyID]))
        XCTAssertEqual(active.map(\.familyId), [nil, nil])
        let mainRow = try XCTUnwrap(active.first { row in row.id == main })
        XCTAssertEqual(LibraryFamilyAction.allCases.filter { action in action.applies(to: mainRow, targetCount: 1) }, [])

        let removed = try await rows(LibraryBrowseQuery(filter: .removedFromSerato, expandedFamilies: [familyID]))
        XCTAssertEqual(Set(removed.map(\.id)), [instrumental, missingAcapella])
        XCTAssertEqual(removed.map(\.familyId), [nil, nil])
    }

    func testASelectedFileThatChangedSinceItWasSelectedRefusesTheCommandByName() async throws {
        let store = try LibrarySelectionStore(database: database)
        try await store.set([.init(id: main, revision: 0), .init(id: instrumental, revision: 0)], selected: true)
        try await pool.write { connection in
            try connection.execute(sql: "UPDATE files SET membership_revision = membership_revision + 1 WHERE id = ?", arguments: [self.instrumental])
        }
        let snapshot = try await LibraryPagedSnapshot.open(pool: pool, query: LibraryBrowseQuery(expandedFamilies: [familyID]))

        await XCTAssertThrowsErrorAsync(try await store.selectedIdentities(in: snapshot, limit: 10)) { error in
            XCTAssertEqual(error as? LibrarySelectionError, .changedSinceSelected(files: ["Song (Instrumental)"]))
        }
        await store.close()
    }

    private func rows(_ query: LibraryBrowseQuery) async throws -> [BrowserRow] {
        let snapshot = try await LibraryPagedSnapshot.open(pool: pool, query: query)
        return try await snapshot.rows(in: 0 ..< snapshot.count())
    }
}
