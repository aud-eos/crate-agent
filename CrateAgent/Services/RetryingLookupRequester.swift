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
    private let now: @Sendable () -> Date

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
        baseBackoffSeconds: TimeInterval = 0.5,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loader = loader
        self.limiter = limiter
        self.sleeper = sleeper
        self.maxAttempts = maxAttempts
        self.baseBackoffSeconds = baseBackoffSeconds
        self.now = now
    }

    /// Sends `request`, retrying on 429/503 up to `maxAttempts` times, and
    /// returns the raw response body on any 2xx status. Every other
    /// outcome throws a `LookupError` — this never returns an empty or
    /// partial body in place of a failure.
    public func perform(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            // Stop before doing any more work if the enclosing task was
            // cancelled (e.g. the user started a New Scan or left Auto-Tag)
            // — including during the previous iteration's backoff sleep, whose
            // cancellation now propagates rather than being swallowed. Prevents
            // a superseded scan from spending its remaining retries against the
            // service concurrently with its replacement (finding #4001501076).
            try Task.checkCancellation()
            attempt += 1
            try await limiter.acquire()

            let (data, response) = try await load(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LookupError.transport("non-HTTP response")
            }

            switch httpResponse.statusCode {
            case 200 ... 299:
                return data
            case 401:
                throw LookupError.unauthorized
            case 429, 500, 502, 503, 504:
                // Transient: rate-limit and the retryable gateway/server 5xx
                // codes get the bounded backoff budget. Only after retries are
                // exhausted does a 5xx become the pass-fatal `.server` — a
                // single momentary 500/502/504 must not abort a whole 200-file
                // scan (finding #4000668528). A 429 that gives up stays
                // `.rateLimited`.
                guard attempt < maxAttempts else {
                    throw httpResponse.statusCode == 429 ? LookupError.rateLimited : LookupError.server
                }
                try await sleeper.sleep(seconds: retryDelay(forAttempt: attempt, response: httpResponse))
            case 500 ... 599:
                // Non-transient 5xx (e.g. 501 Not Implemented) — no retry.
                throw LookupError.server
            default:
                throw LookupError.transport("unexpected status \(httpResponse.statusCode)")
            }
        }
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await loader.data(for: request)
        } catch let urlError as URLError where Self.isConnectionWide(urlError.code) {
            // The whole connection is down, not this one request — surface it
            // as `.offline` so a multi-file scan halts instead of retrying the
            // same doomed request once per row.
            throw LookupError.offline(urlError.localizedDescription)
        } catch {
            throw LookupError.transport(error.localizedDescription)
        }
    }

    /// URL-loading failure codes that mean the connection itself is
    /// unavailable — every subsequent request would fail identically — as
    /// opposed to a one-off per-request failure that maps to `.transport`.
    /// Deliberately excludes `.timedOut`: a single slow response (e.g. one
    /// lookup stalling under AcoustID rate-limiting) is per-request, not a
    /// systemic outage, and halting the whole scan on it would be too
    /// aggressive — it stays `.transport` and fails just that row.
    /// `.networkConnectionLost` IS included: a dropped connection mid-scan is
    /// the systemic case #3999114468 targets, and if it were a one-off only
    /// this scan halts and a re-scan proceeds.
    private static func isConnectionWide(_ code: URLError.Code) -> Bool {
        switch code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .networkConnectionLost,
             .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    /// A valid `Retry-After` delay or HTTP date wins; otherwise use
    /// bounded exponential backoff:
    /// `baseBackoffSeconds * 2^(attempt-1)`.
    private func retryDelay(forAttempt attempt: Int, response: HTTPURLResponse) -> TimeInterval {
        if let header = response.value(forHTTPHeaderField: "Retry-After") {
            let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = TimeInterval(value), seconds.isFinite, seconds < Double(Int64.max) {
                return max(0, seconds)
            }
            let receivedAt = now()
            if let retryAt = Self.httpDate(value, relativeTo: receivedAt) {
                return max(0, retryAt.timeIntervalSince(receivedAt))
            }
        }
        return baseBackoffSeconds * pow(2.0, Double(attempt - 1))
    }

    private static func httpDate(_ value: String, relativeTo referenceDate: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.calendar = calendar
        formatter.isLenient = false
        // RFC 9110's obsolete two-digit year form uses a rolling window,
        // not DateFormatter's fixed default century.
        formatter.twoDigitStartDate = calendar.date(byAdding: .year, value: -49, to: referenceDate)
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
            "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        for (index, format) in formats.enumerated() {
            formatter.dateFormat = format
            guard let date = formatter.date(from: value) else { continue }
            if index == 1,
               let futureLimit = calendar.date(byAdding: .year, value: 50, to: referenceDate),
               date > futureLimit
            {
                return calendar.date(byAdding: .year, value: -100, to: date)
            }
            return date
        }
        return nil
    }
}
