import CryptoKit
import Foundation

/// Looks up a Chromaprint fingerprint against AcoustID, returning ranked
/// MusicBrainz recording candidates. A cache hit returns without any
/// network call; a miss sends `POST /v2/lookup`, retrying on 429/503 via
/// `RetryingLookupRequester` (the same backoff mechanic `MusicBrainzClient`
/// uses).
public struct AcoustIDClient: Sendable {
    private static let endpoint = URL(string: "https://api.acoustid.org/v2/lookup")!

    private let requester: RetryingLookupRequester
    private let cache: LookupCache

    public init(
        loader: URLLoading,
        limiter: RateLimiter,
        cache: LookupCache,
        sleeper: BackoffSleeping = SystemBackoffSleeper()
    ) {
        requester = RetryingLookupRequester(loader: loader, limiter: limiter, sleeper: sleeper)
        self.cache = cache
    }

    /// - Returns: candidates sorted by AcoustID confidence score, descending.
    public func lookup(fingerprintBase64: String, durationSeconds: Int, apiKey: String) async throws -> [AcoustIDResult] {
        let cacheKey = Self.cacheKey(forFingerprint: fingerprintBase64)
        if let cachedData = cache.data(forKey: cacheKey) {
            return try Self.decodeSortedResults(from: cachedData)
        }

        let request = Self.makeRequest(apiKey: apiKey, durationSeconds: durationSeconds, fingerprintBase64: fingerprintBase64)
        let responseData = try await requester.perform(request)
        cache.store(responseData, forKey: cacheKey)
        return try Self.decodeSortedResults(from: responseData)
    }

    private static func makeRequest(apiKey: String, durationSeconds: Int, fingerprintBase64: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncodedBody(
            apiKey: apiKey,
            durationSeconds: durationSeconds,
            fingerprintBase64: fingerprintBase64
        ).utf8)
        return request
    }

    private static func formEncodedBody(apiKey: String, durationSeconds: Int, fingerprintBase64: String) -> String {
        [
            ("client", apiKey),
            ("duration", String(durationSeconds)),
            ("fingerprint", fingerprintBase64),
            ("meta", "recordings+recordingids"),
        ]
        .map { key, value in "\(key)=\(formURLEncodedValue(value))" }
        .joined(separator: "&")
    }

    /// `application/x-www-form-urlencoded` encoding: everything outside
    /// unreserved characters is percent-encoded, including `+` — a literal
    /// `+` byte in a form body decodes to a space server-side, so a `+`
    /// meant literally (the `+` joining `meta=recordings+recordingids`, or
    /// one that happens to appear inside a base64 fingerprint) must be
    /// escaped to `%2B` rather than sent as-is.
    private static func formURLEncodedValue(_ value: String) -> String {
        var allowedCharacters = CharacterSet.alphanumerics
        allowedCharacters.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
    }

    private static func decodeSortedResults(from data: Data) throws -> [AcoustIDResult] {
        let response: AcoustIDResponse
        do {
            response = try JSONDecoder().decode(AcoustIDResponse.self, from: data)
        } catch {
            throw LookupError.transport("invalid AcoustID response body: \(error.localizedDescription)")
        }
        // AcoustID can answer with HTTP 200 and a body that itself reports
        // failure (e.g. a malformed fingerprint) — that must not decode
        // into an empty-but-successful result set.
        guard response.status == "ok" else {
            throw LookupError.transport("AcoustID returned status \"\(response.status)\"")
        }
        return response.results.sorted { $0.score > $1.score }
    }

    private static func cacheKey(forFingerprint fingerprintBase64: String) -> String {
        let digest = SHA256.hash(data: Data(fingerprintBase64.utf8))
        let hexDigest = digest.map { String(format: "%02x", $0) }.joined()
        return "acoustid:\(hexDigest)"
    }
}
