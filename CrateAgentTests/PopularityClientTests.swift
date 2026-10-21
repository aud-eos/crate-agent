@testable import CrateAgent
import XCTest

final class PopularityClientTests: XCTestCase {
    func testListenCountsPostsIDsAndParsesCounts() async throws {
        let body = Data(#"[{"recording_mbid":"mbid-a","total_listen_count":123,"total_user_count":4},{"recording_mbid":"mbid-b","total_listen_count":null}]"#.utf8)
        let loader = StubLoader(status: 200, body: body)
        let client = ListenBrainzClient(loader: loader, limiter: .noop, appVersion: "test")

        let counts = try await client.listenCounts(recordingMBIDs: ["mbid-a", "mbid-b"])

        XCTAssertEqual(counts, ["mbid-a": 123])
        let request = try XCTUnwrap(loader.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.listenbrainz.org/1/popularity/recording")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data(#"{"recording_mbids":["mbid-a","mbid-b"]}"#.utf8))
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("crate-agent/test") == true)
    }

    func testDeezerTrackByISRCReturnsNilOnErrorBody() async throws {
        let loader = StubLoader(status: 200, body: Data(#"{"error":{"type":"DataException","message":"no data","code":800}}"#.utf8))
        let client = DeezerClient(loader: loader, limiter: .noop)

        let track = try await client.track(isrc: "GBAYE0601498")

        XCTAssertNil(track)
        XCTAssertEqual(loader.lastRequest?.url?.absoluteString, "https://api.deezer.com/track/isrc:GBAYE0601498")

        let quota = DeezerClient(loader: StubLoader(status: 200, body: Data(#"{"error":{"type":"Exception","message":"Quota limit exceeded","code":4}}"#.utf8)), limiter: .noop)
        do {
            _ = try await quota.track(isrc: "GBAYE0601498")
            XCTFail("A quota envelope is a failure, not a missing track")
        } catch let error as LookupError {
            XCTAssertEqual(error, .rateLimited)
        }
    }

    func testDeezerSearchQuotesArtistAndTitle() async throws {
        let body = Data(#"{"data":[{"id":3135556,"title":"Harder, Better, Faster, Stronger","artist":{"id":27,"name":"Daft Punk"},"rank":850000}],"total":1}"#.utf8)
        let loader = StubLoader(status: 200, body: body)
        let client = DeezerClient(loader: loader, limiter: .noop)

        let track = try await client.search(artist: "Daft + Punk", title: "Harder, \"Better\", Faster, Stronger")

        XCTAssertEqual(track, DeezerTrack(id: 3_135_556, title: "Harder, Better, Faster, Stronger", artist: "Daft Punk", rank: 850_000))
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(loader.lastRequest?.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { item in item.name == "q" }?.value, #"artist:"Daft + Punk" track:"Harder, Better, Faster, Stronger""#)
        XCTAssertTrue(loader.lastRequest?.url?.absoluteString.contains("Daft%20%2B%20Punk") == true, "A plus must survive form decoding")
        XCTAssertEqual(query.first { item in item.name == "limit" }?.value, "1")
    }

    func testDeezerChartParsesRanks() async throws {
        let body = Data(#"{"data":[{"id":1,"title":"One","artist":{"id":1,"name":"A"},"rank":999000},{"id":2,"title":"Two","artist":{"id":2,"name":"B"},"rank":998000}],"total":2}"#.utf8)
        let loader = StubLoader(status: 200, body: body)
        let client = DeezerClient(loader: loader, limiter: .noop)

        let chart = try await client.chart(limit: 2)

        XCTAssertEqual(chart.map(\.title), ["One", "Two"])
        XCTAssertEqual(loader.lastRequest?.url?.absoluteString, "https://api.deezer.com/chart/0/tracks?limit=2")
    }
}
