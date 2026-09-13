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

    func testEmptyResultsIsAValidSuccessNotAFailure() async throws {
        let loader = StubLoader(status: 200, body: fixture("acoustid_empty.json"))
        let client = AcoustIDClient(loader: loader, limiter: .noop, cache: .memory())

        let results = try await client.lookup(fingerprintBase64: "F", durationSeconds: 1, apiKey: "K")

        XCTAssertTrue(results.isEmpty)
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

/// Fails every call with a transport-level error, to exercise
/// `LookupError.transport` mapping for non-HTTP-status failures.
private final class ThrowingLoader: URLLoading {
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
