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
        let cacheKey = Self.cacheKey(forFingerprint: fingerprintBase64, durationSeconds: durationSeconds)
        if let cachedResults = cache.cachedValue(forKey: cacheKey, decode: Self.decodeSortedResults) {
            return cachedResults
        }

        let request = Self.makeRequest(apiKey: apiKey, durationSeconds: durationSeconds, fingerprintBase64: fingerprintBase64)
        let responseData = try await requester.perform(request)
        // Decode (and validate the in-body `status`) BEFORE caching — a
        // 200-with-body-error must never be cached, or every subsequent
        // lookup for this fingerprint would replay the same failure
        // forever instead of retrying the network.
        let results = try Self.decodeSortedResults(from: responseData)
        cache.store(responseData, forKey: cacheKey)
        return results
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
            ("meta", "recordings recordingids"),
            ("format", "json"),
        ]
        .map { key, value in "\(key)=\(formURLEncodedValue(value))" }
        .joined(separator: "&")
    }

    /// `application/x-www-form-urlencoded` encoding: everything outside
    /// unreserved characters is percent-encoded, including `+` — a literal
    /// `+` byte in a form body decodes to a space server-side, so a `+`
    /// that happens to appear inside a base64 fingerprint or key must be
    /// escaped to `%2B` rather than sent as-is. A real space (e.g. the one
    /// separating AcoustID's two `meta` option names) is percent-encoded to
    /// `%20`, which standard form parsers decode back to a space just like
    /// `+` — so it reaches AcoustID as the option separator it needs to be,
    /// not folded into one invalid combined option name.
    private static func formURLEncodedValue(_ value: String) -> String {
        var allowedCharacters = CharacterSet.alphanumerics
        allowedCharacters.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
    }

    /// AcoustID's documented codes for a rejected API key within an
    /// in-body error object — distinct from an HTTP 401, which
    /// `RetryingLookupRequester` already maps to `.unauthorized` directly.
    /// `4` is an invalid application key, `6` an invalid *user* key; both
    /// mean every subsequent call will fail identically, so both must halt
    /// the whole auto-tag pass rather than being retried per file.
    private static let invalidAPIKeyErrorCode = 4
    private static let invalidUserAPIKeyErrorCode = 6

    private static func decodeSortedResults(from data: Data) throws -> [AcoustIDResult] {
        let response: AcoustIDResponse
        do {
            response = try JSONDecoder().decode(AcoustIDResponse.self, from: data)
        } catch {
            throw LookupError.transport("invalid AcoustID response body: \(error.localizedDescription)")
        }
        // AcoustID can answer with HTTP 200 and a body that itself reports
        // failure — that must not decode into an empty-but-successful
        // result set. Only a rejected key is pass-fatal (every further call
        // will fail the same way); any other in-body error (e.g. a
        // malformed fingerprint) is specific to this one file, so it maps
        // to `.transport` — same as before this file's key-handling was
        // added — and AutoTaggerService fails only that row.
        guard response.status == "ok" else {
            if let errorPayload = response.error {
                if errorPayload.code == invalidAPIKeyErrorCode || errorPayload.code == invalidUserAPIKeyErrorCode {
                    throw LookupError.unauthorized
                }
                throw LookupError.transport("AcoustID returned error code \(errorPayload.code): \(errorPayload.message)")
            }
            throw LookupError.transport("AcoustID returned status \"\(response.status)\"")
        }
        return response.results.sorted { $0.score > $1.score }
    }

    /// Fingerprints are capped at the first 120s, so two recordings that
    /// share an identical opening but differ in total length can produce
    /// the same fingerprint while needing a different `duration` param —
    /// keying on fingerprint alone would let the second lookup wrongly
    /// reuse the first's cached candidates.
    /// Not `private`: the test target computes the same key to seed a
    /// corrupt cache entry (`@testable import` only lifts `private` up to
    /// `internal`, not below it).
    static func cacheKey(forFingerprint fingerprintBase64: String, durationSeconds: Int) -> String {
        let digest = SHA256.hash(data: Data("\(fingerprintBase64)|\(durationSeconds)".utf8))
        let hexDigest = digest.map { String(format: "%02x", $0) }.joined()
        return "acoustid:\(hexDigest)"
    }
}
