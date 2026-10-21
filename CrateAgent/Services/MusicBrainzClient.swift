import CryptoKit
import Foundation

/// Looks up full MusicBrainz recording metadata (releases, release-group
/// first-release-date, artist-credit, ISRCs, performed works) by recording MBID. A cache hit
/// returns without any network call; a miss sends `GET
/// /ws/2/recording/<mbid>`, retrying on 429/503 via
/// `RetryingLookupRequester` (the same backoff mechanic `AcoustIDClient`
/// uses).
public struct MusicBrainzClient: Sendable {
    private static let baseURLString = "https://musicbrainz.org/ws/2/recording/"
    /// MusicBrainz etiquette requires an identifying `User-Agent` naming the
    /// application, its version, and a contact URL — a request without one
    /// can be throttled or blocked.
    static let contactURL = "https://github.com/aud-eos/crate-agent"
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
        var recording = try Self.decodeRecording(from: responseData)
        guard let canonicalID = recording.id else {
            throw LookupError.transport("MusicBrainz recording response has no canonical ID")
        }
        if recording.releases.count >= 25 {
            recording = try await recording.replacingReleases(with: allReleases(recordingID: canonicalID))
        }
        try Task.checkCancellation()
        let completeData = try JSONEncoder().encode(recording)
        cache.store(completeData, forKey: cacheKey)
        cache.store(completeData, forKey: Self.cacheKey(forMBID: canonicalID))
        cache.store(completeData, forKey: Self.detailsCacheKey(forMBID: mbid))
        cache.store(completeData, forKey: Self.detailsCacheKey(forMBID: canonicalID))
        return recording
    }

    public func recordingDetails(mbid: String) async throws -> MBRecordingDetails {
        let cacheKey = Self.detailsCacheKey(forMBID: mbid)
        if let cached = cache.cachedValue(forKey: cacheKey, decode: Self.decodeRecording) {
            return MBRecordingDetails(recording: cached, requestedID: mbid)
        }
        let responseData = try await requester.perform(makeRequest(mbid: mbid, includes: "artist-credits"))
        let recording = try Self.decodeRecording(from: responseData)
        let details = MBRecordingDetails(recording: recording, requestedID: mbid)
        try Task.checkCancellation()
        cache.store(responseData, forKey: cacheKey)
        cache.store(responseData, forKey: Self.detailsCacheKey(forMBID: details.id))
        return details
    }

    /// Searches recordings by artist and title — the Auto-Tag fallback
    /// when AcoustID returns no recordings. Shares the rate limiter and
    /// retry policy with every other MusicBrainz request. Non-empty
    /// results are cached; an empty result is not, so a recording added
    /// to MusicBrainz later is still found.
    public func searchRecordings(artist: String, title: String) async throws -> [MBRecordingDetails] {
        let query = "recording:\(Self.phrase(title)) AND artist:\(Self.phrase(artist))"
        let cacheKey = Self.searchCacheKey(forQuery: query)
        if let cached = cache.cachedValue(forKey: cacheKey, decode: Self.decodeSearch) {
            return cached
        }
        var components = URLComponents(string: Self.baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))!
        // Percent-encode everything but unreserved characters: a literal
        // `+` in a title would otherwise reach the server as a space.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "query", value: query.addingPercentEncoding(withAllowedCharacters: unreserved)),
            URLQueryItem(name: "limit", value: String(Self.searchResultLimit)),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgentHeaderValue, forHTTPHeaderField: "User-Agent")
        let data = try await requester.perform(request)
        let hits = try Self.decodeSearch(from: data)
        try Task.checkCancellation()
        if !hits.isEmpty {
            cache.store(data, forKey: cacheKey)
        }
        return hits
    }

    private static let searchResultLimit = 10

    private struct SearchResponse: Decodable {
        let recordings: [MBRecording]
    }

    private static func decodeSearch(from data: Data) throws -> [MBRecordingDetails] {
        let response: SearchResponse
        do {
            response = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw LookupError.transport("invalid MusicBrainz search response body: \(error.localizedDescription)")
        }
        return try response.recordings.map { recording in
            guard let identifier = recording.id, !identifier.isEmpty else {
                throw LookupError.transport("MusicBrainz search result has no recording ID")
            }
            return MBRecordingDetails(recording: recording, requestedID: identifier)
        }
    }

    /// A Lucene phrase: backslashes and quotes inside a tag are escaped
    /// so they can't end the phrase or inject query syntax.
    private static func phrase(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func searchCacheKey(forQuery query: String) -> String {
        "mb:search-v1:" + SHA256.hash(data: Data(query.utf8)).lowercaseHex
    }

    private struct ReleasePage: Decodable {
        let count: Int
        let offset: Int
        let releases: [MBRelease]

        enum CodingKeys: String, CodingKey {
            case count = "release-count"
            case offset = "release-offset"
            case releases
        }
    }

    private func allReleases(recordingID: String) async throws -> [MBRelease] {
        var releases: [MBRelease] = []
        var seenIDs: Set<String> = []
        var expectedCount: Int?
        var offset = 0
        repeat {
            var components = URLComponents(string: "https://musicbrainz.org/ws/2/release")!
            components.queryItems = [
                URLQueryItem(name: "recording", value: recordingID),
                URLQueryItem(name: "inc", value: "release-groups"),
                URLQueryItem(name: "fmt", value: "json"),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue(userAgentHeaderValue, forHTTPHeaderField: "User-Agent")
            let data = try await requester.perform(request)
            let page: ReleasePage
            do {
                page = try JSONDecoder().decode(ReleasePage.self, from: data)
            } catch {
                throw LookupError.transport("invalid MusicBrainz release page at offset \(offset): \(error.localizedDescription)")
            }
            guard page.offset == offset, page.count >= offset,
                  page.releases.count <= page.count - offset,
                  expectedCount == nil || expectedCount == page.count,
                  !page.releases.isEmpty || offset == page.count
            else {
                throw LookupError.transport("incomplete or changing MusicBrainz release list at offset \(offset) — retry the scan")
            }
            for release in page.releases {
                guard seenIDs.insert(release.id).inserted else {
                    throw LookupError.transport("duplicate MusicBrainz release across pages — retry the scan")
                }
                releases.append(release)
            }
            expectedCount = page.count
            // Release pages can be shorter than limit due to track counts.
            offset += page.releases.count
        } while offset < (expectedCount ?? 0)
        return releases
    }

    private func makeRequest(mbid: String, includes: String = "releases+release-groups+artist-credits+isrcs+work-rels") -> URLRequest {
        let encodedMBID = mbid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? mbid
        let url = URL(string: "\(Self.baseURLString)\(encodedMBID)?inc=\(includes)&fmt=json")!
        var request = URLRequest(url: url)
        request.setValue(userAgentHeaderValue, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func decodeRecording(from data: Data) throws -> MBRecording {
        do {
            let recording = try JSONDecoder().decode(MBRecording.self, from: data)
            guard let canonicalID = recording.id, !canonicalID.isEmpty else {
                throw LookupError.transport("MusicBrainz recording response has no canonical ID")
            }
            return recording
        } catch {
            throw LookupError.transport("invalid MusicBrainz recording response body: \(error.localizedDescription)")
        }
    }

    /// Not `private`: the test target computes the same key to seed a
    /// corrupt cache entry (`@testable import` only lifts `private` up to
    /// `internal`, not below it).
    /// v3 added work relations (#262); a v2 entry has none, so it is refetched.
    static func cacheKey(forMBID mbid: String) -> String {
        "mb:complete-v3:\(mbid)"
    }

    private static func detailsCacheKey(forMBID mbid: String) -> String {
        "mb:details-v1:\(mbid)"
    }

    public static func bundleAppVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallbackAppVersion
    }
}
