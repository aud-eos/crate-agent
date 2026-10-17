@testable import CrateAgent
import XCTest

final class MusicBrainzClientTests: XCTestCase {
    func testLightweightDetailsDecodeVersionDurationCreditsAndCacheCanonicalAlias() async throws {
        let loader = MusicBrainzSequenceLoader(bodies: [Data(#"{"id":"canonical","title":"Song","length":245123,"disambiguation":"extended mix","artist-credit":[{"name":"Artist A","joinphrase":" feat. ","artist":{"id":"artist-a","name":"Artist A"}},{"name":"Artist B","artist":{"id":"artist-b","name":"Artist B"}}]}"#.utf8)])
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: .memory(), appVersion: "test")
        let details = try await client.recordingDetails(mbid: "old-id")
        XCTAssertEqual(details.id, "canonical")
        XCTAssertEqual(details.title, "Song")
        XCTAssertEqual(details.creditedArtistName, "Artist A feat. Artist B")
        XCTAssertEqual(details.disambiguation, "extended mix")
        XCTAssertEqual(details.durationMilliseconds, 245_123)
        let cachedAlias = try await client.recordingDetails(mbid: "old-id")
        let cachedCanonical = try await client.recordingDetails(mbid: "canonical")
        XCTAssertEqual(cachedAlias, details)
        XCTAssertEqual(cachedCanonical, details)
        XCTAssertEqual(loader.requests.count, 1)
        let request = try XCTUnwrap(loader.requests.first)
        let query = try XCTUnwrap(try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "inc" }?.value, "artist-credits")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("crate-agent/test") == true)
    }

    func testSparseDetailsStayUnknownAndNeverPoisonCompleteRecordingCache() async throws {
        let loader = MusicBrainzSequenceLoader(bodies: [
            Data(#"{"id":"recording","title":"Sparse"}"#.utf8),
            Data(#"{"id":"recording","title":"Complete","length":123000,"disambiguation":"album version","releases":[{"id":"release","title":"Album"}]}"#.utf8),
        ])
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: .memory())
        let sparse = try await client.recordingDetails(mbid: "recording")
        XCTAssertNil(sparse.disambiguation)
        XCTAssertNil(sparse.durationMilliseconds)
        XCTAssertTrue(sparse.creditedArtistName.isEmpty)
        let complete = try await client.recording(mbid: "recording")
        XCTAssertEqual(complete.releases.count, 1)
        let refreshed = try await client.recordingDetails(mbid: "recording")
        XCTAssertEqual(refreshed.title, "Complete")
        XCTAssertEqual(refreshed.disambiguation, "album version")
        XCTAssertEqual(refreshed.durationMilliseconds, 123_000)
        XCTAssertEqual(loader.requests.count, 2)
    }

    func testInvalidDetailsFailWithoutCachingAndRetryCanSucceed() async throws {
        let loader = MusicBrainzSequenceLoader(bodies: [Data(#"{"title":"Missing identity"}"#.utf8), Data(#"{"id":"canonical","title":"Good"}"#.utf8)])
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: .memory())
        await XCTAssertThrowsErrorAsync(try await client.recordingDetails(mbid: "alias"))
        let details = try await client.recordingDetails(mbid: "alias")
        XCTAssertEqual(details.id, "canonical")
        XCTAssertEqual(loader.requests.count, 2)
    }

    private func fixture(_ name: String) -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            XCTFail("Missing fixture: \(name)")
            return Data()
        }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    func testLoadsShortReleasePagesBeforeCachingCompleteRecording() async throws {
        let embedded = (0 ..< 25).map { releaseJSON(index: $0, year: "2001") }
        let loader = try MusicBrainzSequenceLoader(bodies: [
            jsonData(["id": "canonical", "title": "Song", "releases": embedded]),
            jsonData(["release-count": 27, "release-offset": 0, "releases": Array(embedded.prefix(10))]),
            jsonData(["release-count": 27, "release-offset": 10, "releases": Array(embedded.dropFirst(10))]),
            jsonData(["release-count": 27, "release-offset": 25, "releases": [releaseJSON(index: 25, year: "1980"), releaseJSON(index: 26, year: "1990")]]),
        ])
        let cache = LookupCache.memory()
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: cache, appVersion: "test")
        let recording = try await client.recording(mbid: "old-id")
        XCTAssertEqual(recording.releases.count, 27)
        XCTAssertEqual(recording.releaseGroup?.firstReleaseDate, "1980")
        XCTAssertTrue(recording.releases.contains { $0.id == "release-26" })
        let requests = loader.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.dropFirst().map { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "offset" }!.value!
        }, ["0", "10", "25"])
        for request in requests.dropFirst() {
            let query = try XCTUnwrap(try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(query.first { $0.name == "recording" }?.value, "canonical")
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "100")
            XCTAssertEqual(query.first { $0.name == "inc" }?.value, "release-groups")
            XCTAssertTrue(try XCTUnwrap(request.value(forHTTPHeaderField: "User-Agent")?.contains("crate-agent/test")))
        }
        let cached = try await client.recording(mbid: "old-id")
        XCTAssertEqual(cached, recording)
        let canonicalCached = try await client.recording(mbid: "canonical")
        XCTAssertEqual(canonicalCached, recording)
        XCTAssertEqual(loader.requests.count, 4)
    }

    func testLegacyPartialCacheIsNotReused() async throws {
        let cache = LookupCache.memory()
        try cache.store(jsonData(["id": "old-id", "title": "Stale", "releases": []]), forKey: "mb:old-id")
        let loader = try MusicBrainzSequenceLoader(bodies: [jsonData(["id": "canonical", "title": "Fresh", "releases": []])])
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: cache)
        let recording = try await client.recording(mbid: "old-id")
        XCTAssertEqual(recording.title, "Fresh")
        XCTAssertEqual(loader.requests.count, 1)
    }

    func testMissingCanonicalIDFailsInsteadOfCachingUnverifiableIdentity() async throws {
        let cache = LookupCache.memory()
        let loader = try MusicBrainzSequenceLoader(bodies: [jsonData(["title": "Song", "releases": []])])
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: cache)
        await XCTAssertThrowsErrorAsync(try await client.recording(mbid: "old-id"))
        XCTAssertNil(cache.data(forKey: MusicBrainzClient.cacheKey(forMBID: "old-id")))
    }

    func testChangingOrOverlappingReleasePagesFailWithoutCaching() async throws {
        let embedded = (0 ..< 25).map { releaseJSON(index: $0, year: "2001") }
        for secondPage in [
            ["release-count": 28, "release-offset": 25, "releases": [releaseJSON(index: 25, year: "1980")]],
            ["release-count": 27, "release-offset": 0, "releases": [releaseJSON(index: 25, year: "1980")]],
            ["release-count": 27, "release-offset": 25, "releases": [embedded[0], embedded[1]]],
        ] {
            let cache = LookupCache.memory()
            let loader = try MusicBrainzSequenceLoader(bodies: [
                jsonData(["id": "canonical", "title": "Song", "releases": embedded]),
                jsonData(["release-count": 27, "release-offset": 0, "releases": embedded]),
                jsonData(secondPage),
            ])
            let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: cache)
            await XCTAssertThrowsErrorAsync(try await client.recording(mbid: "old-id"))
            XCTAssertNil(cache.data(forKey: MusicBrainzClient.cacheKey(forMBID: "old-id")))
        }
    }

    func testIncompleteReleaseBrowseNeverPoisonsCache() async throws {
        let cache = LookupCache.memory()
        let loader = try MusicBrainzSequenceLoader(bodies: [
            jsonData(["id": "canonical", "title": "Song", "releases": (0 ..< 25).map { releaseJSON(index: $0, year: "2001") }]),
            jsonData(["release-count": 27, "release-offset": 0, "releases": []]),
        ])
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: cache)
        await XCTAssertThrowsErrorAsync(try await client.recording(mbid: "old-id"))
        XCTAssertNil(cache.data(forKey: MusicBrainzClient.cacheKey(forMBID: "old-id")))
    }

    private func releaseJSON(index: Int, year: String) -> [String: Any] {
        ["id": "release-\(index)", "title": "Edition \(index)", "status": "Official", "date": year,
         "release-group": ["id": "group-\(index)", "first-release-date": year]]
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testFetchesRecordingAndSetsUserAgent() async throws {
        let loader = StubLoader(status: 200, body: fixture("mb_recording.json"))
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: .memory(), appVersion: "1.2.3")

        let recording = try await client.recording(mbid: "f3d1e2a0-5b2b-4b8e-9b8a-7a3e2f8c9d10")

        XCTAssertEqual(recording.title, "Voodoo Ray")
        XCTAssertFalse(recording.releases.isEmpty)
        XCTAssertNotNil(recording.releaseGroup)
        XCTAssertTrue(
            loader.lastRequest?.value(forHTTPHeaderField: "User-Agent")?.contains("crate-agent/1.2.3") ?? false
        )
    }

    func testCacheHitSkipsNetwork() async throws {
        let loader = StubLoader(status: 200, body: fixture("mb_recording.json"))
        let cache = LookupCache.memory()
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: cache, appVersion: "1.2.3")

        _ = try await client.recording(mbid: "f3d1e2a0-5b2b-4b8e-9b8a-7a3e2f8c9d10")
        _ = try await client.recording(mbid: "f3d1e2a0-5b2b-4b8e-9b8a-7a3e2f8c9d10")

        XCTAssertEqual(loader.callCount, 1)
    }

    func testDecodeFailureThrowsInsteadOfEmptyRecording() async {
        let loader = StubLoader(status: 200, body: Data("not json".utf8))
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: .memory(), appVersion: "1.2.3")

        await XCTAssertThrowsErrorAsync(try await client.recording(mbid: "abc")) {
            guard case .transport = $0 as? LookupError else {
                XCTFail("expected .transport, got \($0)")
                return
            }
        }
    }

    func testCorruptCacheEntryIsEvictedAndFallsThroughToNetwork() async throws {
        // Same as AcoustIDClientTests' equivalent: a cached recording that
        // no longer decodes must be treated as a MISS — evicted and
        // re-fetched — not replayed as a permanent decode failure.
        let mbid = "f3d1e2a0-5b2b-4b8e-9b8a-7a3e2f8c9d10"
        let cache = LookupCache.memory()
        let cacheKey = MusicBrainzClient.cacheKey(forMBID: mbid)
        cache.store(Data("not valid json".utf8), forKey: cacheKey)
        let loader = StubLoader(status: 200, body: fixture("mb_recording.json"))
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: cache, appVersion: "1.2.3")

        let recording = try await client.recording(mbid: mbid)

        XCTAssertEqual(loader.callCount, 1, "the corrupt hit must fall through to the network")
        XCTAssertEqual(recording.title, "Voodoo Ray")
        XCTAssertNotEqual(cache.data(forKey: cacheKey), Data("not valid json".utf8), "the healthy response must be re-cached over the corrupt bytes")
    }

    func testSearchSendsEscapedPhraseQueryDecodesHitsAndCachesOnlyNonEmptyResults() async throws {
        let loader = MusicBrainzSequenceLoader(bodies: [Data(#"{"recordings":[]}"#.utf8), fixture("mb_recording_search.json")])
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: .memory())

        let empty = try await client.searchRecordings(artist: #"A "Guy""#, title: "Voodoo + Ray")
        XCTAssertTrue(empty.isEmpty)
        let hits = try await client.searchRecordings(artist: #"A "Guy""#, title: "Voodoo + Ray")
        _ = try await client.searchRecordings(artist: #"A "Guy""#, title: "Voodoo + Ray")

        XCTAssertEqual(loader.requests.count, 2, "An empty answer is retried; a non-empty one is served from the cache")
        let components = try XCTUnwrap(loader.requests.first?.url.flatMap { url in URLComponents(url: url, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(components.path, "/ws/2/recording")
        XCTAssertTrue(components.percentEncodedQuery?.contains("Voodoo%20%2B%20Ray") == true, "A literal + must not become a space")
        XCTAssertEqual(components.queryItems?.first { item in item.name == "query" }?.value, #"recording:"Voodoo + Ray" AND artist:"A \"Guy\"""#)
        XCTAssertEqual(hits.map(\.title), ["Voodoo Ray", "Voodoo Ray (Intro)", "Voodoo Ray (Remix)"])
        XCTAssertEqual(hits[1].disambiguation, "DJ intro edit")
        XCTAssertEqual(hits[0].creditedArtistName, "A Guy Called Gerald")
    }

    func testMalformedSearchBodyFailsAsTransport() async {
        let loader = StubLoader(status: 200, body: Data(#"{"recordings":[{"title":"No identity"}]}"#.utf8))
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: .memory(), appVersion: "1.2.3")
        await XCTAssertThrowsErrorAsync(try await client.searchRecordings(artist: "Artist", title: "Song")) {
            guard case .transport = $0 as? LookupError else { return XCTFail("expected .transport, got \($0)") }
        }
    }

    func testNotFoundMapsToTransportError() async {
        let loader = StubLoader(status: 404, body: Data())
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: .memory(), appVersion: "1.2.3")

        await XCTAssertThrowsErrorAsync(try await client.recording(mbid: "missing-mbid")) {
            guard case .transport = $0 as? LookupError else {
                XCTFail("expected .transport, got \($0)")
                return
            }
        }
    }
}

final class MusicBrainzSequenceLoader: URLLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let bodies: [Data]
    private var storedRequests: [URLRequest] = []

    init(bodies: [Data]) {
        self.bodies = bodies
    }

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try lock.withLock {
            let index = storedRequests.count
            storedRequests.append(request)
            guard index < bodies.count else { throw URLError(.badServerResponse) }
            return bodies[index]
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
