@testable import CrateAgent
import GRDB
import XCTest

@MainActor
final class PopularityServiceTests: XCTestCase {
    private let now: Int64 = 1_000_000_000

    func testRefreshLooksUpEnabledSourcesAndStoresScores() async throws {
        let fixture = try await Fixture(seedTracks: true)
        fixture.preferences.preferences.setPopularitySource(.listenBrainz, enabled: true)
        fixture.preferences.preferences.setPopularitySource(.deezer, enabled: true)
        fixture.loader.respond(host: "api.listenbrainz.org") { _ in #"[{"recording_mbid":"mbid-1","total_listen_count":9999}]"# }
        fixture.loader.respond(host: "api.deezer.com") { url in
            switch url.path {
            case "/track/isrc:ISRC1": return #"{"id":1,"title":"Song","artist":{"id":1,"name":"Canonical"},"rank":500000}"#
            case "/search": return #"{"data":[{"id":2,"title":"Other","artist":{"id":2,"name":"Artist"},"rank":250000}],"total":1}"#
            case "/chart/0/tracks": return #"{"data":[],"total":0}"#
            default: XCTFail("Unexpected Deezer path \(url.path)"); return "{}"
            }
        }
        let service = fixture.service(now: now)

        await service.refresh()

        XCTAssertEqual(service.status, .refreshed(count: 2))
        let requests = fixture.loader.requests
        XCTAssertEqual(requests.filter { request in request.url?.host == "api.listenbrainz.org" }.count, 1)
        XCTAssertEqual(requests.compactMap(\.url?.path).filter { path in path.hasPrefix("/track/isrc:") }, ["/track/isrc:ISRC1"])
        XCTAssertEqual(requests.compactMap(\.url?.path).filter { path in path == "/search" }.count, 1)
        let scores = try await fixture.scores()
        XCTAssertEqual(scores["mbid-1"]?.allTime ?? 0, (log10(10000) / 7 * 100 + 50) / 2, accuracy: 0.01)
        XCTAssertEqual(scores["file:\(fixture.otherFileID)"]?.allTime, 25)
        let stamped = try await fixture.database.writer.read { connection in try SeratoLibraryFacts.hasStamp(.popularity, in: connection) }
        XCTAssertTrue(stamped)
    }

    func testDisabledSourcesSendNothing() async throws {
        let fixture = try await Fixture(seedTracks: true)
        let service = fixture.service(now: now)

        await service.refresh()

        XCTAssertEqual(service.status, .off)
        XCTAssertTrue(fixture.loader.requests.isEmpty)
        let scores = try await fixture.scores()
        XCTAssertTrue(scores.isEmpty)
    }

    func testOfflineKeepsPreviousScores() async throws {
        let fixture = try await Fixture(seedTracks: true)
        fixture.preferences.preferences.setPopularitySource(.deezer, enabled: true)
        try await fixture.database.writer.write { connection in
            try PopularityStore.record([PopularityObservation(recordingKey: "mbid-1", source: .deezer, observedAt: self.now - 30 * 86400, value: 400_000)],
                                       now: self.now - 30 * 86400, in: connection)
        }
        fixture.loader.offline = true
        let service = fixture.service(now: now)

        await service.refresh()

        guard case .failed = service.status else { return XCTFail("Expected a failed status, got \(service.status)") }
        let scores = try await fixture.scores()
        XCTAssertEqual(scores["mbid-1"]?.allTime, 40)
    }

    func testSearchHitWithAnotherArtistIsIgnored() async throws {
        let fixture = try await Fixture(seedTracks: false)
        fixture.preferences.preferences.setPopularitySource(.deezer, enabled: true)
        fixture.loader.respond(host: "api.deezer.com") { url in
            url.path == "/search" ? #"{"data":[{"id":9,"title":"Other","artist":{"id":9,"name":"Somebody Else"},"rank":900000}],"total":1}"# : #"{"data":[],"total":0}"#
        }
        let service = fixture.service(now: now)

        await service.refresh()

        XCTAssertEqual(service.status, .refreshed(count: 1))
        let scores = try await fixture.scores()
        XCTAssertNil(scores["file:\(fixture.otherFileID)"]?.allTime)
        XCTAssertNotNil(scores["file:\(fixture.otherFileID)"], "A recording no source answered is still marked as looked up")
    }

    func testChartSeedReachesEveryEncodingOfARecording() async throws {
        let fixture = try await Fixture(seedTracks: true)
        fixture.preferences.preferences.setPopularitySource(.deezer, enabled: true)
        fixture.loader.respond(host: "api.deezer.com") { url in
            switch url.path {
            case "/chart/0/tracks":
                #"{"data":[{"id":1,"title":"X","artist":{"id":1,"name":"A"},"rank":1},{"id":2,"title":"Y","artist":{"id":2,"name":"B"},"rank":1},{"id":3,"title":"song","artist":{"id":3,"name":"CANONICAL"},"rank":1}],"total":3}"#
            case "/search": #"{"data":[],"total":0}"#
            default: #"{"error":{"type":"DataException","message":"no data","code":800}}"#
            }
        }
        let service = fixture.service(now: now)

        await service.refresh()

        let hot = try await fixture.database.writer.read { connection in
            try Row.fetchAll(connection, sql: """
            SELECT files.title, COALESCE(scores.hot, scores.chart_hot) AS hot FROM files LEFT JOIN tracks ON tracks.id = files.track_id
            LEFT JOIN popularity_scores AS scores ON scores.recording_key = \(KeeperMarks.recordingKeySQL) ORDER BY files.id
            """).map { row in (row["title"] as String, row["hot"] as Double?) }
        }
        XCTAssertEqual(hot.map(\.0), ["Song", "Song (flac)", "Other"])
        XCTAssertEqual(hot.map(\.1), [98, 98, nil])
        XCTAssertEqual(fixture.preferences.preferences.popularityChartSeededAt, now)
    }

    @MainActor
    private final class Fixture {
        let database: LibraryDatabase
        let preferences: IsolatedPreferences
        let loader = RoutingLoader()
        private(set) var otherFileID: Int64 = 0

        /// `Song` and `Song (flac)` share a recording with an MBID and ISRC; `Other` has neither.
        init(seedTracks: Bool) async throws {
            database = try LibraryDatabase.openInMemory()
            preferences = try IsolatedPreferences()
            otherFileID = try await database.writer.write { connection in
                if seedTracks {
                    var track = TrackRecord(fingerprintHash: Data([1]), musicbrainzRecordingId: "mbid-1", isrc: "ISRC1", artist: "Canonical", title: "Song")
                    try track.insert(connection)
                    try PopularityStoreTests.insertFile(connection, title: "Song", artist: "Canonical", trackID: track.id)
                    try PopularityStoreTests.insertFile(connection, title: "Song (flac)", artist: "Canonical", trackID: track.id)
                }
                return try PopularityStoreTests.insertFile(connection, title: "Other", trackID: nil)
            }
        }

        func service(now: Int64) -> PopularityService {
            PopularityService(database: database, preferences: preferences.preferences, readiness: nil,
                              listenBrainz: ListenBrainzClient(loader: loader, limiter: .noop, appVersion: "test"),
                              deezer: DeezerClient(loader: loader, limiter: .noop), now: { now })
        }

        func scores() async throws -> [String: (allTime: Double?, hot: Double?)] {
            try await database.writer.read { connection in
                var scores: [String: (allTime: Double?, hot: Double?)] = [:]
                for row in try Row.fetchAll(connection, sql: "SELECT recording_key, all_time, hot FROM popularity_scores") {
                    scores[row["recording_key"]] = (row["all_time"], row["hot"])
                }
                return scores
            }
        }
    }

    /// Answers by host, records every request, and can go offline.
    private final class RoutingLoader: URLLoading, @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: (URL) -> String] = [:]
        private var recorded: [URLRequest] = []
        var offline = false

        var requests: [URLRequest] {
            lock.withLock { recorded }
        }

        func respond(host: String, _ handler: @escaping (URL) -> String) {
            lock.withLock { handlers[host] = handler }
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url!
            let handler: ((URL) -> String)? = lock.withLock {
                recorded.append(request)
                return offline ? nil : handlers[url.host ?? ""]
            }
            if offline {
                throw URLError(.notConnectedToInternet)
            }
            guard let handler else {
                XCTFail("No stub for \(url)")
                throw URLError(.badURL)
            }
            return (Data(handler(url).utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}
