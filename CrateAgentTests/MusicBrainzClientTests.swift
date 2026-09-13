@testable import CrateAgent
import XCTest

final class MusicBrainzClientTests: XCTestCase {
    private func fixture(_ name: String) -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            XCTFail("Missing fixture: \(name)")
            return Data()
        }
        return (try? Data(contentsOf: url)) ?? Data()
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
