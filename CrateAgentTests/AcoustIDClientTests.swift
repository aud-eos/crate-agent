@testable import CrateAgent
import XCTest

final class AcoustIDClientTests: XCTestCase {
    private func fixture(_ name: String) -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            XCTFail("Missing fixture: \(name)")
            return Data()
        }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    func testReturnsSortedResults() async throws {
        let loader = StubLoader(status: 200, body: fixture("acoustid_multi.json"))
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory())

        let results = try await client.lookup(fingerprintBase64: "F", durationSeconds: 200, apiKey: "K")

        XCTAssertEqual(results, results.sorted { $0.score > $1.score })
        XCTAssertEqual(results.count, 2)
    }

    func testUnauthorizedMapsToError() async {
        let client = AcoustIDClient(loader: StubLoader(status: 401, body: Data()), limiter: .noop, cache: .memory())

        await XCTAssertThrowsErrorAsync(try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "bad")) {
            XCTAssertEqual($0 as? LookupError, .unauthorized)
        }
    }

    func testCacheHitSkipsNetwork() async throws {
        let loader = StubLoader(status: 200, body: fixture("acoustid_multi.json"))
        let cache = LookupCache.memory()
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: cache)

        _ = try await client.lookup(fingerprintBase64: "F", durationSeconds: 200, apiKey: "K")
        _ = try await client.lookup(fingerprintBase64: "F", durationSeconds: 200, apiKey: "K")

        XCTAssertEqual(loader.callCount, 1)
    }

    func testStatusErrorBodyIsNotCachedAndRetriesOnNextCall() async throws {
        // AcoustID's documented failure mode: HTTP 200 with an in-body
        // "status": "error" — this must never be cached, or every
        // subsequent lookup for this fingerprint would replay the same
        // failure forever instead of hitting the network again.
        let errorBody = Data(#"{ "status": "error", "results": [] }"#.utf8)
        let loader = SequencedStubLoader(responses: [
            (status: 200, body: errorBody, headers: [:]),
            (status: 200, body: fixture("acoustid_multi.json"), headers: [:]),
        ])
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory())

        await XCTAssertThrowsErrorAsync(try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "K")) {
            guard case .transport = $0 as? LookupError else {
                XCTFail("expected .transport, got \($0)")
                return
            }
        }

        let results = try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "K")

        XCTAssertEqual(loader.callCount, 2, "the failed body must not have been cached — the second call should hit the network again")
        XCTAssertEqual(results.count, 2)
    }

    func testRetriesAfterRateLimitAndSucceedsWithoutRealDelay() async throws {
        let loader = SequencedStubLoader(responses: [
            (status: 429, body: Data(), headers: [:]),
            (status: 200, body: fixture("acoustid_multi.json"), headers: [:]),
        ])
        let sleeper = RecordingSleeper()
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory(), sleeper: sleeper)

        let results = try await client.lookup(fingerprintBase64: "F", durationSeconds: 200, apiKey: "K")

        XCTAssertEqual(loader.callCount, 2)
        XCTAssertEqual(sleeper.recordedDelays.count, 1)
        XCTAssertEqual(results.count, 2)
    }

    func testRetryHonorsRetryAfterHeader() async throws {
        let loader = SequencedStubLoader(responses: [
            (status: 429, body: Data(), headers: ["Retry-After": "2"]),
            (status: 200, body: fixture("acoustid_multi.json"), headers: [:]),
        ])
        let sleeper = RecordingSleeper()
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory(), sleeper: sleeper)

        _ = try await client.lookup(fingerprintBase64: "F", durationSeconds: 200, apiKey: "K")

        XCTAssertEqual(sleeper.recordedDelays, [2.0])
    }

    func testRateLimitExhaustsRetriesAndThrows() async {
        let loader = StubLoader(status: 429, body: Data())
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory(), sleeper: RecordingSleeper())

        await XCTAssertThrowsErrorAsync(try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "K")) {
            XCTAssertEqual($0 as? LookupError, .rateLimited)
        }
        XCTAssertEqual(loader.callCount, 4, "should have retried up to the default max attempts")
    }

    func testServerErrorMapsToError() async {
        let client = AcoustIDClient(loader: StubLoader(status: 500, body: Data()), limiter: .noop, cache: .memory())

        await XCTAssertThrowsErrorAsync(try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "K")) {
            XCTAssertEqual($0 as? LookupError, .server)
        }
    }

    func testServiceUnavailableExhaustsRetriesAndMapsToServerError() async {
        let loader = StubLoader(status: 503, body: Data())
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory(), sleeper: RecordingSleeper())

        await XCTAssertThrowsErrorAsync(try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "K")) {
            XCTAssertEqual($0 as? LookupError, .server)
        }
    }

    func testTransportErrorWrapsUnderlyingFailure() async {
        let client = AcoustIDClient(loader: ThrowingLoader(), limiter: .noop, cache: .memory())

        await XCTAssertThrowsErrorAsync(try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "K")) {
            guard case .transport = $0 as? LookupError else {
                XCTFail("expected .transport, got \($0)")
                return
            }
        }
    }

    func testConnectionWideURLErrorMapsToOffline() async {
        // A connection-wide URLError (offline/DNS/host unreachable) is
        // distinct from a per-request transport failure: it maps to `.offline`
        // so the auto-tagger halts the whole pass instead of retrying every
        // row against a dead connection (finding #3999114468).
        let client = AcoustIDClient(loader: OfflineLoader(), limiter: .noop, cache: .memory())

        await XCTAssertThrowsErrorAsync(try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "K")) {
            guard case .offline = $0 as? LookupError else {
                XCTFail("expected .offline, got \($0)")
                return
            }
        }
    }

    func testEmptyResultsIsAValidSuccessNotAFailure() async throws {
        let loader = StubLoader(status: 200, body: fixture("acoustid_empty.json"))
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory())

        let results = try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "K")

        XCTAssertTrue(results.isEmpty)
    }

    func testRequestBodyEncodesMetaOptionsSpaceSeparatedNotPlusJoined() async throws {
        // `meta=recordings+recordingids` is WRONG in a form-urlencoded body:
        // `+` decodes to a literal space server-side, so a "+" meant to
        // join two option names must reach the wire as a real space
        // (encoded as `+` or `%20`), never as a literal `+` byte
        // (`%2B`) — that would make AcoustID see one invalid option
        // "recordings+recordingids" instead of two valid ones.
        let loader = StubLoader(status: 200, body: fixture("acoustid_multi.json"))
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory())

        _ = try await client.lookup(fingerprintBase64: "F", durationSeconds: 200, apiKey: "K")

        let body = try XCTUnwrap(loader.lastRequest?.httpBody)
        let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(
            bodyString.contains("recordings%2Brecordingids"),
            "meta options must not be joined with a literal-escaped plus: \(bodyString)"
        )
        XCTAssertTrue(
            bodyString.contains("recordings+recordingids") || bodyString.contains("recordings%20recordingids"),
            "expected the two meta options separated by a space-encoding (+ or %20), got: \(bodyString)"
        )
    }

    func testRequestBodyStillEscapesLiteralPlusInFingerprint() async throws {
        // A literal "+" that's actually part of the base64 fingerprint (or
        // key) must still be escaped to %2B — only the meta separator is a
        // "real" space, not every "+" in the body.
        let loader = StubLoader(status: 200, body: fixture("acoustid_multi.json"))
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory())

        _ = try await client.lookup(fingerprintBase64: "AB+CD", durationSeconds: 200, apiKey: "K")

        let body = try XCTUnwrap(loader.lastRequest?.httpBody)
        let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(
            bodyString.contains("fingerprint=AB%2BCD"),
            "expected the literal + inside the fingerprint to stay percent-escaped, got: \(bodyString)"
        )
    }

    func testInvalidAPIKeyErrorBodyMapsToUnauthorized() async {
        // AcoustID answers a revoked/bad key with HTTP 200 and an in-body
        // error object — error code 4 is documented as "invalid API key".
        // This must map to .unauthorized, the same as an HTTP 401, so
        // AutoTaggerService stops the whole scan instead of retrying every
        // file against a key that will never work.
        let errorBody = Data(#"{ "status": "error", "error": { "code": 4, "message": "Invalid API key" } }"#.utf8)
        let client = AcoustIDClient(loader: StubLoader(status: 200, body: errorBody), limiter: .noop, cache: .memory())

        await XCTAssertThrowsErrorAsync(try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "bad")) {
            XCTAssertEqual($0 as? LookupError, .unauthorized)
        }
    }

    func testInvalidUserAPIKeyErrorBodyMapsToUnauthorized() async {
        // AcoustID distinguishes an invalid application key (code 4) from
        // an invalid *user* key (code 6) — both are auth problems and both
        // must halt the whole pass rather than retry per file.
        let errorBody = Data(#"{ "status": "error", "error": { "code": 6, "message": "Invalid user API key" } }"#.utf8)
        let client = AcoustIDClient(loader: StubLoader(status: 200, body: errorBody), limiter: .noop, cache: .memory())

        await XCTAssertThrowsErrorAsync(try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "bad")) {
            XCTAssertEqual($0 as? LookupError, .unauthorized)
        }
    }

    func testGenericInBodyErrorCodeMapsToTransportNotServer() async {
        // Any other in-body error code (e.g. an invalid fingerprint for
        // this one file) is a per-file data problem, not an auth or server
        // failure — it must map to .transport so AutoTaggerService fails
        // only this row and continues the batch, matching the pre-existing
        // (pre-#7-fix) behavior for every non-key in-body error.
        let errorBody = Data(#"{ "status": "error", "error": { "code": 3, "message": "Invalid fingerprint" } }"#.utf8)
        let client = AcoustIDClient(loader: StubLoader(status: 200, body: errorBody), limiter: .noop, cache: .memory())

        await XCTAssertThrowsErrorAsync(try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "secret-key")) {
            guard case let .transport(message) = $0 as? LookupError else {
                XCTFail("expected .transport, got \($0)")
                return
            }
            XCTAssertTrue(message.contains("3"), "expected the error code in the message, got: \(message)")
            XCTAssertFalse(message.contains("secret-key"), "the API key must never appear in an error message: \(message)")
        }
    }

    func testCacheKeyIncludesDurationSoDifferentDurationsDoNotCollide() async throws {
        // Fingerprints are capped at the first 120s, so two recordings that
        // share an identical opening but differ in total length can share
        // a fingerprint while needing different `duration` params. Keying
        // the cache on fingerprint alone would let the second lookup wrongly
        // reuse the first's cached candidates.
        let loader = SequencedStubLoader(responses: [
            (status: 200, body: fixture("acoustid_multi.json"), headers: [:]),
            (status: 200, body: fixture("acoustid_empty.json"), headers: [:]),
        ])
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory())

        let first = try await client.lookup(fingerprintBase64: "SAME", durationSeconds: 120, apiKey: "K")
        let second = try await client.lookup(fingerprintBase64: "SAME", durationSeconds: 240, apiKey: "K")

        XCTAssertEqual(loader.callCount, 2, "a different duration must not be served from the first duration's cache entry")
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(second.isEmpty)
    }

    func testCorruptCacheEntryIsEvictedAndFallsThroughToNetwork() async throws {
        // A cached entry that no longer decodes (truncated on disk, or
        // written by an older/incompatible model) must be treated as a
        // MISS — evicted and re-fetched — not as a permanent failure that
        // replays the same decode error on every future lookup.
        let cache = LookupCache.memory()
        let cacheKey = AcoustIDClient.cacheKey(forFingerprint: "F", durationSeconds: 200)
        cache.store(Data("not valid json".utf8), forKey: cacheKey)
        let loader = StubLoader(status: 200, body: fixture("acoustid_multi.json"))
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: cache)

        let results = try await client.lookup(fingerprintBase64: "F", durationSeconds: 200, apiKey: "K")

        XCTAssertEqual(loader.callCount, 1, "the corrupt hit must fall through to the network")
        XCTAssertEqual(results.count, 2)
        XCTAssertNotEqual(cache.data(forKey: cacheKey), Data("not valid json".utf8), "the healthy response must be re-cached over the corrupt bytes")
    }

    func testRequestBodyPinsResponseFormatToJSON() async throws {
        // AcoustID's default response format is JSON, but it's ambiguous
        // historically and decodeSortedResults unconditionally
        // JSON-decodes — pin it explicitly rather than rely on the
        // server-side default.
        let loader = StubLoader(status: 200, body: fixture("acoustid_multi.json"))
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory())

        _ = try await client.lookup(fingerprintBase64: "F", durationSeconds: 200, apiKey: "K")

        let body = try XCTUnwrap(loader.lastRequest?.httpBody)
        let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(
            bodyString.contains("format=json"),
            "expected the form-encoded body to pin format=json, got: \(bodyString)"
        )
    }
}

/// Returns a fixed status/body on every call, and records the most recent
/// request so callers can assert on headers (e.g. `MusicBrainzClientTests`
/// asserting `User-Agent`). Shared across lookup-client test files rather
/// than duplicated per client — not `private`, so it's visible to any test
/// file in this module.
final class StubLoader: URLLoading, @unchecked Sendable {
    private let status: Int
    private let body: Data
    private let lock = NSLock()
    private var count = 0
    private var capturedLastRequest: URLRequest?

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    var callCount: Int {
        lock.withLock { count }
    }

    var lastRequest: URLRequest? {
        lock.withLock { capturedLastRequest }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            count += 1
            capturedLastRequest = request
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// Returns successive canned responses, one per call; the last response
/// repeats if there are more calls than responses.
private final class SequencedStubLoader: URLLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [(status: Int, body: Data, headers: [String: String])]
    private var count = 0

    init(responses: [(status: Int, body: Data, headers: [String: String])]) {
        self.responses = responses
    }

    var callCount: Int {
        lock.withLock { count }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let next: (status: Int, body: Data, headers: [String: String]) = lock.withLock {
            count += 1
            let index = min(count - 1, responses.count - 1)
            return responses[index]
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.status,
            httpVersion: nil,
            headerFields: next.headers
        )!
        return (next.body, response)
    }
}

/// Fails every call with a PER-REQUEST URL error (a malformed server
/// response), to exercise `LookupError.transport` mapping for non-HTTP-status
/// failures that are NOT connection-wide (those map to `.offline` — see
/// `OfflineLoader`).
private final class ThrowingLoader: URLLoading {
    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.badServerResponse)
    }
}

/// Fails every call with a connection-wide URL error, to exercise
/// `LookupError.offline` mapping (offline / DNS / host unreachable).
private final class OfflineLoader: URLLoading {
    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// A `BackoffSleeping` that records requested delays instead of waiting,
/// so retry tests are deterministic and instant.
private final class RecordingSleeper: BackoffSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [TimeInterval] = []

    var recordedDelays: [TimeInterval] {
        lock.withLock { delays }
    }

    func sleep(seconds: TimeInterval) async {
        lock.withLock { delays.append(seconds) }
    }
}
