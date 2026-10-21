@testable import CrateAgent
import GRDB
import XCTest

/// The per-file checklist the Library projection computes from stored facts,
/// over a real WAL database with one file per case and facts seeded in SQL.
final class LibraryChecklistTests: XCTestCase {
    private var directory: URL!
    private var database: LibraryDatabase!
    private var pool: DatabasePool!
    private var fileIDs: [String: Int64] = [:]

    /// Everything a complete file has; each case removes or changes one fact.
    private struct Seed {
        var title: String
        var artist = "Artist"
        var genre: String? = "House"
        var bitrateKbps: Int? = 320
        var pathExtension = "mp3"
        var inCrate = true
        var cueCount: Int?? = .some(4)
        var beatgridLocked: Bool?? = .some(true)
        var addedAt: Int64? = 100
        var addedSource = DateAddedSource.serato
        var playCount: Int?
        var duplicateGroup: String?
        var trackID: Int64?
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryChecklist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try LibraryDatabase.openWAL(at: directory.appendingPathComponent("library.sqlite"))
        pool = try XCTUnwrap(database.writer as? DatabasePool)
        fileIDs = try await pool.write { connection in try Self.seed(connection) }
    }

    override func tearDown() async throws {
        try pool.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testChecklistReportsEachItemFromStoredFacts() async throws {
        let rows = try await checklistsByTitle(LibraryBrowseQuery())
        XCTAssertEqual(rows["Uncrated"]?.failing, [.inCrate])
        XCTAssertEqual(rows["Unread"]?.unknown, [.cuePoints, .beatgridChecked])
        XCTAssertEqual(rows["Unread"]?.failing, [])
        XCTAssertEqual(rows["NoCues"]?.failing, [.cuePoints])
        XCTAssertEqual(rows["UnreadableCues"]?.unknown, [.cuePoints])
        XCTAssertEqual(rows["GridUnlocked"]?.failing, [.beatgridChecked])
        XCTAssertEqual(rows["NoGenre"]?.missingMetadata, [.genre])
        XCTAssertEqual(rows["NoGenre"]?.failing, [.metadata])
        XCTAssertEqual(rows["Lossy192"]?.failing, [.quality])
        XCTAssertEqual(rows["FlacNoBitrate"]?.failing, [])
        XCTAssertEqual(rows["FlacNoBitrate"]?.unknown, [])
        XCTAssertEqual(rows["Mp3NoBitrate"]?.unknown, [.quality])
        XCTAssertEqual(rows["Dupe"]?.failing, [.duplicate])
        XCTAssertEqual(rows["Complete"]?.isFinished, true)
        XCTAssertEqual(rows["Unread"]?.isFinished, false)
        XCTAssertEqual(rows["Unread"]?.stillNeedsCount, 2)
        XCTAssertEqual(rows["Uncrated"]?.stillNeedsCount, 1)

        // A chip filters on every file's checklist; a page shows only its own files' checklists.
        let collapsed = try await self.rows(LibraryBrowseQuery())
        let families = Set(collapsed.compactMap { row in row.familyRole == .main ? row.familyId : nil })
        let expanded = try await self.rows(LibraryBrowseQuery(expandedFamilies: families))
        XCTAssertEqual(expanded.count, 31)
        let chipCounts = try await LibraryPagedSnapshot.open(pool: pool, query: LibraryBrowseQuery()).chipCounts()
        for chip in ChecklistChip.allCases {
            let matching = try expanded.filter { row in
                let checklist = try XCTUnwrap(row.checklist())
                return switch chip.match {
                case .needsWork: !checklist.isFinished
                case .finished: checklist.isFinished
                case .neverPlayed: row.playCount == 0
                case let .failing(item): checklist.failing.contains(item)
                }
            }
            // The count covers every file, a family's main row included.
            XCTAssertEqual(chipCounts[chip], .files(matching.count), chip.rawValue)
            let shown = matching.filter { row in row.familyRole != .main }
            let filtered = try await titles(LibraryBrowseQuery(chip: chip))
            XCTAssertEqual(filtered.sorted(), shown.map { row in row.title ?? row.path }.sorted(), chip.rawValue)
        }
    }

    func testRetiredFilesHaveNoChecklistAndCountTowardNoChip() async throws {
        let retired = try await rows(LibraryBrowseQuery(filter: .removedFromSerato))
        XCTAssertEqual(retired.map(\.title), ["Retired"])
        XCTAssertNil(try retired.first?.checklist())
        let snapshot = try await LibraryPagedSnapshot.open(pool: pool, query: .init(filter: .removedFromSerato))
        let counts = try await snapshot.chipCounts()
        XCTAssertEqual(Set(counts.values), [.files(0)])
    }

    func testKeeperIsFinishedButOnlyItsOwnMarkHidesDuplicate() async throws {
        let rows = try await checklistsByTitle(.init())
        XCTAssertEqual(rows["KeptLossyDupe"]?.isFinished, true)
        XCTAssertEqual(rows["KeptLossyDupe"]?.failing, [.quality])
        XCTAssertEqual(rows["KeptLossyDupe"]?.stillNeedsCount, 0)
        XCTAssertEqual(rows["KeptSiblingDupe"]?.isFinished, true)
        XCTAssertEqual(rows["KeptSiblingDupe"]?.failing, [.duplicate])
    }

    func testTooManyVersionsFlagsOnlyNonMainVersionsOfFamiliesOverTheLimit() async throws {
        let flagged = try await titles(.init(chip: .tooManyVersions))
        XCTAssertEqual(flagged, ["V2", "V3", "V4", "V5"])
        let main = try await rows(.init()).first { row in row.title == "V1" }
        XCTAssertEqual(main?.familyFileCount, 6)
        XCTAssertEqual(main?.familyFilesNeedingWork, 4)
    }

    func testChipsCombineWithSearchAndCountFilesInScope() async throws {
        let snapshot = try await LibraryPagedSnapshot.open(pool: pool, query: .init(search: "Artist A", chip: .notInCrate))
        let counts = try await snapshot.chipCounts()
        XCTAssertEqual(counts[.notInCrate], .files(2))
        XCTAssertEqual(counts[.finished], .files(1))
        XCTAssertEqual(counts[.needsWork], .files(2))
        let found = try await titles(.init(search: "Artist A", chip: .notInCrate))
        XCTAssertEqual(found, ["A Uncrated 1", "A Uncrated 2"])
    }

    func testDateAddedFallsBackToFirstIndexedAndMissingValuesSortLast() async throws {
        let dated = try await ids(.init(search: "Dated", sort: .init(column: .dateAdded, ascending: false)))
        XCTAssertEqual(dated, [fileIDs["Dated Serato Newest"], fileIDs["Dated Indexed Older"], fileIDs["Dated No Facts"]])
        let played = try await ids(.init(sort: .init(column: .myPlays, ascending: false)))
        XCTAssertEqual(Array(played.prefix(2)), [fileIDs["Played 9"], fileIDs["Played 2"]])
    }

    func testPopularitySortsKnownScoresFirstAndUnknownLast() async throws {
        let low = try XCTUnwrap(fileIDs["Played 2"])
        let high = try XCTUnwrap(fileIDs["Played 9"])
        try await pool.write { connection in
            try PopularityStore.record([
                PopularityObservation(recordingKey: "file:\(low)", source: .deezer, observedAt: 100, value: 200_000),
                PopularityObservation(recordingKey: "file:\(high)", source: .deezer, observedAt: 100, value: 800_000),
            ], now: 100, in: connection)
            try PopularityStore.seedHot([(recordingKey: "file:\(low)", hot: 90)], now: 100, in: connection)
        }
        let ascending = try await ids(.init(sort: .init(column: .popularity, ascending: true)))
        XCTAssertEqual(Array(ascending.prefix(2)), [low, high])
        let descending = try await ids(.init(sort: .init(column: .popularity, ascending: false)))
        XCTAssertEqual(Array(descending.prefix(2)), [high, low])
        let hottest = try await rows(.init(sort: .init(column: .hot, ascending: false)))
        XCTAssertEqual(hottest.first?.id, low)
        XCTAssertEqual(hottest.first?.popularityHot, 90)
        XCTAssertEqual(hottest.first?.popularityAllTime, 20)
        XCTAssertEqual(hottest.first?.popularityDetail, "Deezer rank 200,000")
        XCTAssertNil(hottest.last?.popularityHot)
    }

    func testPrepareRankOrdersMostPromisingFirstAndNoSignalLast() async throws {
        let popular = try XCTUnwrap(fileIDs["Played 2"])
        let played = try XCTUnwrap(fileIDs["Played 9"])
        let unplayed = try XCTUnwrap(fileIDs["Complete"])
        try await pool.write { connection in
            try PopularityStore.record([PopularityObservation(recordingKey: "file:\(popular)", source: .deezer, observedAt: 100, value: 950_000)],
                                       now: 100, in: connection)
            try PopularityStore.seedHot([(recordingKey: "file:\(popular)", hot: 5)], now: 100, in: connection)
            try connection.execute(sql: "DELETE FROM checklist_source_stamps WHERE source = ?", arguments: [ChecklistSource.history.rawValue])
        }
        // Plays are unknown until History has been read, so only popularity ranks: 95 + 5 for Played 2, nothing for the rest.
        let unread = try await rows(.init(sort: .init(column: .prepareRank, ascending: false)))
        XCTAssertEqual(unread.first?.id, popular)
        XCTAssertEqual(unread.first?.prepareRankSortKey, 100)
        XCTAssertEqual(unread.last?.prepareRankSortKey, -Double.infinity, "No signal sorts last in both directions")
        let unreadAscending = try await ids(.init(sort: .init(column: .prepareRank, ascending: true)))
        XCTAssertEqual(unreadAscending.first, popular, "Ascending still puts the unranked rows last")

        try await pool.write { connection in try SeratoLibraryFacts.writeStamp(.history, "{}", in: connection) }
        let read = try await rows(.init(sort: .init(column: .prepareRank, ascending: false)))
        XCTAssertEqual(Array(read.prefix(2).map(\.id)), [popular, played], "95 + 5 + 2 plays × 10 beats 9 plays × 10")
        XCTAssertEqual(read.first?.prepareRankSortKey, 120)
        XCTAssertEqual(read.first { row in row.id == unplayed }?.prepareRankSortKey, 0, "A played-count of 0 is a known signal")
        let standalone = read.filter { row in row.familyId == nil }.map(\.prepareRankSortKey)
        XCTAssertEqual(standalone, standalone.sorted(by: >), "SQL order matches the Swift formula")
    }

    func testPlaysAndUnreadSourcesChipCountsAreUnknownAndNeverPlayedMatchesNothingUntilHistoryHasBeenRead() async throws {
        try await pool.write { connection in
            try connection.execute(sql: "DELETE FROM checklist_source_stamps WHERE source IN (?, ?)",
                                   arguments: [ChecklistSource.history.rawValue, ChecklistSource.subcrates.rawValue])
        }
        var plays = try await playsByTitle()
        XCTAssertEqual(plays["Complete"], .some(nil))
        XCTAssertEqual(plays["Played 9"], .some(nil))
        let unreadCounts = try await LibraryPagedSnapshot.open(pool: pool, query: .init()).chipCounts()
        XCTAssertEqual(unreadCounts[.neverPlayed], .unknown)
        XCTAssertEqual(unreadCounts[.notInCrate], .unknown)
        let unreadNeverPlayed = try await titles(.init(chip: .neverPlayed))
        XCTAssertEqual(unreadNeverPlayed, [])

        try await pool.write { connection in try SeratoLibraryFacts.writeStamp(.history, "{}", in: connection) }
        plays = try await playsByTitle()
        XCTAssertEqual(plays["Complete"], .some(0))
        XCTAssertEqual(plays["Played 9"], .some(9))
        let readNeverPlayed = try await titles(.init(chip: .neverPlayed))
        XCTAssertTrue(readNeverPlayed.contains("Complete"))
    }

    // MARK: - Helpers

    private func playsByTitle() async throws -> [String: Int?] {
        var plays: [String: Int?] = [:]
        for row in try await rows(LibraryBrowseQuery()) {
            plays[row.title ?? row.path] = row.playCount
        }
        return plays
    }

    private func rows(_ query: LibraryBrowseQuery) async throws -> [BrowserRow] {
        let snapshot = try await LibraryPagedSnapshot.open(pool: pool, query: query)
        return try await snapshot.rows(in: 0 ..< snapshot.count())
    }

    private func checklistsByTitle(_ query: LibraryBrowseQuery) async throws -> [String: FileChecklist] {
        var checklists: [String: FileChecklist] = [:]
        for row in try await rows(query) {
            checklists[row.title ?? row.path] = try row.checklist()
        }
        return checklists
    }

    /// Titles of the matching rows, leaving out a family's main row shown only as context.
    private func titles(_ query: LibraryBrowseQuery) async throws -> [String] {
        try await rows(query).filter { row in row.familyRole != .main }.map { row in row.title ?? row.path }
    }

    private func ids(_ query: LibraryBrowseQuery) async throws -> [Int64?] {
        try await rows(query).map(\.id)
    }

    private static func seed(_ connection: GRDB.Database) throws -> [String: Int64] {
        var ids: [String: Int64] = [:]
        var inode: Int64 = 0
        func add(_ seed: Seed) throws {
            inode += 1
            var file = FileRecord(path: "/Music/\(seed.title).\(seed.pathExtension)", volumeUuid: "volume", inode: inode, fileSize: 10, mtime: 5,
                                  trackId: seed.trackID, bitrateKbps: seed.bitrateKbps, artist: seed.artist, title: seed.title,
                                  genre: seed.genre, bpm: "124", musicalKey: "8A")
            file.libraryMembership = .active
            file.fileAvailability = .available
            try file.insert(connection)
            let fileID = try XCTUnwrap(file.id)
            ids[seed.title] = fileID
            if seed.inCrate {
                try connection.execute(sql: "INSERT INTO serato_crate_memberships (file_id, crate_name) VALUES (?, 'Warmup')", arguments: [fileID])
            }
            if case let .some(cueCount) = seed.cueCount {
                try connection.execute(sql: """
                INSERT INTO file_serato_analysis (file_id, file_size, mtime, inode, modified_nanoseconds, changed_seconds, changed_nanoseconds,
                                                  cue_count, beatgrid_marker_count, failure)
                VALUES (?, 10, 5, ?, 0, 5, 0, ?, 1, ?)
                """, arguments: [fileID, inode, cueCount, cueCount == nil ? "malformed: bad Markers2" : nil])
            }
            if case let .some(locked) = seed.beatgridLocked {
                try connection.execute(sql: "INSERT INTO serato_track_facts (file_id, beatgrid_locked, added_at, added_source) VALUES (?, ?, ?, ?)",
                                       arguments: [fileID, locked, seed.addedAt, seed.addedSource])
            }
            if let playCount = seed.playCount {
                try connection.execute(sql: "INSERT INTO serato_play_counts (file_id, play_count) VALUES (?, ?)", arguments: [fileID, playCount])
            }
            if let group = seed.duplicateGroup {
                try connection.execute(sql: "INSERT INTO checklist_duplicate_members (file_id, group_key) VALUES (?, ?)", arguments: [fileID, group])
            }
        }
        func track(mbid: String?, family: Int64?, name: String) throws -> Int64 {
            var track = TrackRecord(fingerprintHash: Data(name.utf8), musicbrainzRecordingId: mbid, workId: family)
            try track.insert(connection)
            return try XCTUnwrap(track.id)
        }
        for source in ChecklistSource.allCases {
            try connection.execute(sql: "INSERT INTO checklist_source_stamps (source, stamp) VALUES (?, '{}')", arguments: [source.rawValue])
        }

        try add(Seed(title: "Complete"))
        try add(Seed(title: "Uncrated", inCrate: false))
        try add(Seed(title: "Unread", cueCount: .none, beatgridLocked: .none))
        try add(Seed(title: "NoCues", cueCount: .some(0)))
        try add(Seed(title: "UnreadableCues", cueCount: .some(nil)))
        try add(Seed(title: "GridUnlocked", beatgridLocked: .some(false)))
        try add(Seed(title: "NoGenre", genre: " \t\u{00A0}"))
        try add(Seed(title: "Lossy192", bitrateKbps: 192))
        try add(Seed(title: "FlacNoBitrate", bitrateKbps: nil, pathExtension: "flac"))
        try add(Seed(title: "Mp3NoBitrate", bitrateKbps: nil))
        try add(Seed(title: "Dupe", duplicateGroup: "dupes"))
        try add(Seed(title: "Retired"))
        try connection.execute(sql: "UPDATE files SET library_membership = 'retired' WHERE title = 'Retired'")

        let keptLossy = try track(mbid: "rec-kept", family: nil, name: "kept-lossy")
        let keptSibling = try track(mbid: "rec-kept", family: nil, name: "kept-sibling")
        try add(Seed(title: "KeptLossyDupe", bitrateKbps: 192, duplicateGroup: "kept", trackID: keptLossy))
        try add(Seed(title: "KeptSiblingDupe", duplicateGroup: "kept", trackID: keptSibling))
        try connection.execute(sql: "INSERT INTO keeper_marks (file_id, marked_revision, marked_at) VALUES (?, 0, 1)", arguments: [ids["KeptLossyDupe"]])

        var overLimit = SongFamilyRecord()
        try overLimit.insert(connection)
        let mainMP3 = try track(mbid: "rec-v1", family: overLimit.id, name: "v1-mp3")
        let mainFLAC = try track(mbid: "rec-v1", family: overLimit.id, name: "v1-flac")
        try add(Seed(title: "V1", trackID: mainMP3))
        try add(Seed(title: "V1 FLAC", pathExtension: "flac", trackID: mainFLAC))
        for version in 2 ... 5 {
            try add(Seed(title: "V\(version)", trackID: track(mbid: nil, family: overLimit.id, name: "v\(version)")))
        }
        try connection.execute(sql: "UPDATE works SET representative_track_id = ? WHERE id = ?", arguments: [mainMP3, overLimit.id])
        var atLimit = SongFamilyRecord()
        try atLimit.insert(connection)
        for version in 1 ... 4 {
            try add(Seed(title: "W\(version)", trackID: track(mbid: nil, family: atLimit.id, name: "w\(version)")))
        }

        try add(Seed(title: "A Uncrated 1", artist: "Artist A", inCrate: false))
        try add(Seed(title: "A Uncrated 2", artist: "Artist A", inCrate: false))
        try add(Seed(title: "A Complete", artist: "Artist A"))

        try add(Seed(title: "Dated Serato Newest", addedAt: 2000))
        try add(Seed(title: "Dated Indexed Older", addedAt: 1000, addedSource: .indexed))
        try add(Seed(title: "Dated No Facts", beatgridLocked: .none))
        try add(Seed(title: "Played 9", playCount: 9))
        try add(Seed(title: "Played 2", playCount: 2))
        return ids
    }
}
