@testable import CrateAgent
import GRDB
import XCTest

final class PopularityStoreTests: XCTestCase {
    private let day: Int64 = 86400
    private let now: Int64 = 1_000_000_000

    func testRecordingLookupsDerivesAllTimeAndDetail() async throws {
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { connection in
            try PopularityStore.record([
                PopularityObservation(recordingKey: "k", source: .listenBrainz, observedAt: self.now, value: 9999),
                PopularityObservation(recordingKey: "k", source: .deezer, observedAt: self.now, value: 500_000),
            ], now: self.now, in: connection)
        }
        let score = try await database.writer.read { connection in
            try Row.fetchOne(connection, sql: "SELECT all_time, hot, detail FROM popularity_scores WHERE recording_key = 'k'")
        }
        let row = try XCTUnwrap(score)
        XCTAssertEqual(try XCTUnwrap(row["all_time"] as Double?), (log10(10000) / 7 * 100 + 50) / 2, accuracy: 0.01)
        XCTAssertNil(row["hot"] as Double?)
        XCTAssertEqual(row["detail"] as String?, "ListenBrainz 9,999 listens · Deezer rank 500,000")
    }

    func testHotNeedsSevenDaysBetweenObservations() async throws {
        let database = try LibraryDatabase.openInMemory()
        func hot() async throws -> Double? {
            try await database.writer.read { connection in
                try Double.fetchOne(connection, sql: "SELECT hot FROM popularity_scores WHERE recording_key = 'k'")
            }
        }
        try await database.writer.write { connection in
            try PopularityStore.record([
                PopularityObservation(recordingKey: "k", source: .listenBrainz, observedAt: self.now, value: 100),
                PopularityObservation(recordingKey: "k", source: .listenBrainz, observedAt: self.now + 6 * self.day, value: 150),
            ], now: self.now + 6 * self.day, in: connection)
        }
        let hotBeforeAWeek = try await hot()
        XCTAssertNil(hotBeforeAWeek)
        try await database.writer.write { connection in
            try PopularityStore.record([PopularityObservation(recordingKey: "k", source: .listenBrainz, observedAt: self.now + 8 * self.day, value: 200)],
                                       now: self.now + 8 * self.day, in: connection)
        }
        let hotAfterAWeek = try await hot()
        XCTAssertEqual(hotAfterAWeek, 100)
    }

    func testStaleKeysOrderOldestFirstAndSkipFresh() async throws {
        let database = try LibraryDatabase.openInMemory()
        let keys = try await database.writer.write { connection -> [String] in
            var track = TrackRecord(fingerprintHash: Data([1]), musicbrainzRecordingId: "mbid-1", isrc: "ISRC1", artist: "Canonical", title: "Song")
            try track.insert(connection)
            let fresh = try Self.insertFile(connection, title: "Fresh", trackID: nil)
            let stale = try Self.insertFile(connection, title: "Stale", trackID: nil)
            let unscored = try Self.insertFile(connection, title: "Unscored", trackID: track.id)
            try PopularityStore.record([PopularityObservation(recordingKey: "file:\(fresh)", source: .deezer, observedAt: self.now, value: 1)],
                                       now: self.now, in: connection)
            try PopularityStore.record([PopularityObservation(recordingKey: "file:\(stale)", source: .deezer, observedAt: self.now - 8 * self.day, value: 1)],
                                       now: self.now - 8 * self.day, in: connection)
            _ = unscored
            return ["file:\(fresh)", "file:\(stale)"]
        }
        let candidates = try await database.writer.read { connection in
            try PopularityStore.staleRecordingKeys(limit: 10, olderThan: self.now - PopularityScoring.refreshInterval, in: connection)
        }
        XCTAssertEqual(candidates.map(\.recordingKey), ["mbid-1", keys[1]])
        XCTAssertEqual(candidates.first, PopularityCandidate(recordingKey: "mbid-1", recordingMBID: "mbid-1", isrc: "ISRC1", artist: "Canonical", title: "Song"))
        XCTAssertEqual(candidates.last?.artist, "Artist")
    }

    func testSeedHotKeepsAllTime() async throws {
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { connection in
            try PopularityStore.record([PopularityObservation(recordingKey: "k", source: .deezer, observedAt: self.now, value: 500_000)], now: self.now, in: connection)
            try PopularityStore.seedHot([(recordingKey: "k", hot: 98), (recordingKey: "new", hot: 97)], now: self.now, in: connection)
        }
        let rows = try await database.writer.read { connection in
            try Row.fetchAll(connection, sql: "SELECT recording_key, all_time, hot FROM popularity_scores ORDER BY recording_key")
        }
        XCTAssertEqual(rows.map { row in row["recording_key"] as String }, ["k", "new"])
        XCTAssertEqual(rows[0]["all_time"] as Double?, 50)
        XCTAssertEqual(rows[0]["hot"] as Double?, 98)
        XCTAssertNil(rows[1]["all_time"] as Double?)
        XCTAssertEqual(rows[1]["hot"] as Double?, 97)
    }

    func testRecordingKeysMatchFoldedArtistAndTitleAcrossEncodings() async throws {
        let database = try LibraryDatabase.openInMemory()
        let keys = try await database.writer.write { connection -> [Int: [String]] in
            var track = TrackRecord(fingerprintHash: Data([2]), artist: "Röyksopp", title: "Eple")
            try track.insert(connection)
            _ = try Self.insertFile(connection, title: "Eple", artist: "Röyksopp", trackID: track.id)
            _ = try Self.insertFile(connection, title: "Eple (flac)", artist: "Röyksopp", trackID: track.id)
            let other = try Self.insertFile(connection, title: "Other", trackID: nil)
            _ = other
            return try PopularityStore.recordingKeys(matching: [(artist: "ROYKSOPP", title: "eple"), (artist: "Nobody", title: "Nothing")], in: connection)
        }
        XCTAssertEqual(keys, [0: ["track:1"]])
    }

    @discardableResult
    static func insertFile(_ connection: GRDB.Database, title: String, artist: String = "Artist", trackID: Int64?) throws -> Int64 {
        let inode = try Int64.fetchOne(connection, sql: "SELECT COALESCE(MAX(inode), 0) + 1 FROM files") ?? 1
        var file = FileRecord(path: "/Music/\(title).mp3", volumeUuid: "volume", inode: inode, fileSize: 10, mtime: 5,
                              trackId: trackID, artist: artist, title: title)
        file.libraryMembership = .active
        file.fileAvailability = .available
        try file.insert(connection)
        return try XCTUnwrap(file.id)
    }
}
