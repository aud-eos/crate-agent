import Foundation

/// Looks up full MusicBrainz recording metadata (releases, release-group
/// first-release-date, artist-credit, ISRCs) by recording MBID. A cache hit
/// returns without any network call; a miss sends `GET
/// /ws/2/recording/<mbid>`, retrying on 429/503 via
/// `RetryingLookupRequester` (the same backoff mechanic `AcoustIDClient`
/// uses).
public struct MusicBrainzClient: Sendable {
    private static let baseURLString = "https://musicbrainz.org/ws/2/recording/"
    /// MusicBrainz etiquette requires an identifying `User-Agent` naming the
    /// application, its version, and a contact URL — a request without one
    /// can be throttled or blocked.
    private static let contactURL = "https://github.com/aud-eos/crate-agent"
    private static let fallbackAppVersion = "0.0.0"

    private let requester: RetryingLookupRequester
    private let cache: LookupCache
    private let userAgentHeaderValue: String

    /// - Parameter appVersion: defaults to the running app's
    ///   `CFBundleShortVersionString`, falling back to a placeholder when
    ///   unavailable (e.g. the unit test bundle has no such key). Injectable
    ///   so tests can assert on a known `User-Agent` value.
    public init(
        loader: URLLoading,
        limiter: RateLimiter,
        cache: LookupCache,
        sleeper: BackoffSleeping = SystemBackoffSleeper(),
        appVersion: String = Self.bundleAppVersion()
    ) {
        requester = RetryingLookupRequester(loader: loader, limiter: limiter, sleeper: sleeper)
        self.cache = cache
        userAgentHeaderValue = "crate-agent/\(appVersion) ( \(Self.contactURL) )"
    }

    public func recording(mbid: String) async throws -> MBRecording {
        let cacheKey = Self.cacheKey(forMBID: mbid)
        if let cachedRecording = cache.cachedValue(forKey: cacheKey, decode: Self.decodeRecording) {
            return cachedRecording
        }

        let request = makeRequest(mbid: mbid)
        let responseData = try await requester.perform(request)
        let recording = try Self.decodeRecording(from: responseData)
        cache.store(responseData, forKey: cacheKey)
        return recording
    }

    private func makeRequest(mbid: String) -> URLRequest {
        let encodedMBID = mbid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? mbid
        let url = URL(string: "\(Self.baseURLString)\(encodedMBID)?inc=releases+release-groups+artist-credits+isrcs&fmt=json")!
        var request = URLRequest(url: url)
        request.setValue(userAgentHeaderValue, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func decodeRecording(from data: Data) throws -> MBRecording {
        do {
            return try JSONDecoder().decode(MBRecording.self, from: data)
        } catch {
            throw LookupError.transport("invalid MusicBrainz recording response body: \(error.localizedDescription)")
        }
    }

    /// Not `private`: the test target computes the same key to seed a
    /// corrupt cache entry (`@testable import` only lifts `private` up to
    /// `internal`, not below it).
    static func cacheKey(forMBID mbid: String) -> String {
        "mb:\(mbid)"
    }

    public static func bundleAppVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallbackAppVersion
    }
}
