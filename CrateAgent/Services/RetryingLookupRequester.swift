import Foundation

/// The retry/backoff/error-mapping mechanic shared by every remote lookup
/// client. Each client builds its own `URLRequest` (method, headers, body)
/// and hands it here; this owns proactive rate-limiting (`RateLimiter`),
/// reactive retry on 429/503 with bounded exponential backoff (honoring a
/// `Retry-After` header when the server sends one), and mapping every
/// terminal outcome to `LookupError`.
///
/// Design ruling: backoff lives at this layer, not inside `RateLimiter`.
/// `RateLimiter` only spaces proactive calls before they're sent — it
/// never inspects a response, so it cannot know a call needs retrying.
public struct RetryingLookupRequester: Sendable {
    private let loader: URLLoading
    private let limiter: RateLimiter
    private let sleeper: BackoffSleeping
    private let maxAttempts: Int
    private let baseBackoffSeconds: TimeInterval

    /// - Parameters:
    ///   - maxAttempts: total attempts (including the first) before a
    ///     429/503 gives up and throws. The default of 4 gives three
    ///     retries with real-world backoffs of ~0.5s/1s/2s; tests inject a
    ///     `sleeper` that never actually waits, so the count — not the
    ///     wall-clock delay — is what matters for them.
    public init(
        loader: URLLoading,
        limiter: RateLimiter,
        sleeper: BackoffSleeping = SystemBackoffSleeper(),
        maxAttempts: Int = 4,
        baseBackoffSeconds: TimeInterval = 0.5
    ) {
        self.loader = loader
        self.limiter = limiter
        self.sleeper = sleeper
        self.maxAttempts = maxAttempts
        self.baseBackoffSeconds = baseBackoffSeconds
    }

    /// Sends `request`, retrying on 429/503 up to `maxAttempts` times, and
    /// returns the raw response body on any 2xx status. Every other
    /// outcome throws a `LookupError` — this never returns an empty or
    /// partial body in place of a failure.
    public func perform(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            await limiter.acquire()

            let (data, response) = try await load(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LookupError.transport("non-HTTP response")
            }

            switch httpResponse.statusCode {
            case 200 ... 299:
                return data
            case 401:
                throw LookupError.unauthorized
            case 429, 503:
                guard attempt < maxAttempts else {
                    throw httpResponse.statusCode == 429 ? LookupError.rateLimited : LookupError.server
                }
                await sleeper.sleep(seconds: retryDelay(forAttempt: attempt, response: httpResponse))
            case 500 ... 599:
                throw LookupError.server
            default:
                throw LookupError.transport("unexpected status \(httpResponse.statusCode)")
            }
        }
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await loader.data(for: request)
        } catch {
            throw LookupError.transport(error.localizedDescription)
        }
    }

    /// A `Retry-After` header (seconds form) wins when the server sends
    /// one; otherwise a bounded exponential backoff:
    /// `baseBackoffSeconds * 2^(attempt-1)`.
    private func retryDelay(forAttempt attempt: Int, response: HTTPURLResponse) -> TimeInterval {
        if let retryAfterHeader = response.value(forHTTPHeaderField: "Retry-After"),
           let retryAfterSeconds = TimeInterval(retryAfterHeader)
        {
            return retryAfterSeconds
        }
        return baseBackoffSeconds * pow(2.0, Double(attempt - 1))
    }
}
