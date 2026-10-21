import Foundation

/// One Deezer track: its rank is Deezer's popularity figure, roughly 0 to 1,000,000.
public struct DeezerTrack: Equatable, Sendable {
    public let id: Int
    public let title: String
    public let artist: String
    public let rank: Int
}

/// Deezer's public API, no key needed. An ISRC lookup sends only the ISRC; a search sends the artist and title.
public struct DeezerClient: Sendable {
    static let baseURL = URL(string: "https://api.deezer.com")!

    private let requester: RetryingLookupRequester

    public init(loader: URLLoading, limiter: RateLimiter, sleeper: BackoffSleeping = SystemBackoffSleeper()) {
        requester = RetryingLookupRequester(loader: loader, limiter: limiter, sleeper: sleeper)
    }

    /// Deezer answers HTTP 200 with an error envelope; this code means "no data" and every other one is a failure.
    static let noDataErrorCode = 800
    static let quotaErrorCode = 4
    /// Query-allowed characters minus the ones a form-decoded query would reinterpret.
    private static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))

    /// The track with this ISRC, or nil when Deezer has none.
    public func track(isrc: String) async throws -> DeezerTrack? {
        let data = try await requester.perform(URLRequest(url: Self.baseURL.appendingPathComponent("track/isrc:\(isrc)")))
        return try body(TrackBody.self, from: data)?.track
    }

    /// The best search hit for the artist and title, or nil when there is none. Quotes would end a term early, so they are dropped.
    public func search(artist: String, title: String) async throws -> DeezerTrack? {
        let query = "artist:\"\(Self.term(artist))\" track:\"\(Self.term(title))\""
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) else {
            throw LookupError.transport("Deezer search query could not be encoded")
        }
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = "q=\(encoded)&limit=1"
        let data = try await requester.perform(URLRequest(url: components.url!))
        return try body(ListBody.self, from: data)?.data.first?.track
    }

    /// The global chart's top tracks, most popular first.
    public func chart(limit: Int = 100) async throws -> [DeezerTrack] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("chart/0/tracks"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        let data = try await requester.perform(URLRequest(url: components.url!))
        return try body(ListBody.self, from: data)?.data.map(\.track) ?? []
    }

    private static func term(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "")
    }

    /// The decoded body, nil for Deezer's "no data" envelope, and an error for any other envelope.
    private func body<Body: Decodable>(_ type: Body.Type, from data: Data) throws -> Body? {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let detail = envelope.error {
            switch detail.code {
            case Self.noDataErrorCode: return nil
            case Self.quotaErrorCode: throw LookupError.rateLimited
            default: throw LookupError.transport("Deezer error \(detail.code.map(String.init) ?? "?"): \(detail.message ?? "no message")")
            }
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LookupError.transport("Deezer response was not understood: \(error.localizedDescription)")
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let code: Int?
            let message: String?
        }

        let error: Detail?
    }

    private struct TrackBody: Decodable {
        struct Artist: Decodable {
            let name: String
        }

        let id: Int
        let title: String
        let artist: Artist
        let rank: Int

        var track: DeezerTrack {
            DeezerTrack(id: id, title: title, artist: artist.name, rank: rank)
        }
    }

    private struct ListBody: Decodable {
        let data: [TrackBody]
    }
}
