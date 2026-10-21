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

    /// The track with this ISRC, or nil when Deezer has none.
    public func track(isrc: String) async throws -> DeezerTrack? {
        let data = try await requester.perform(URLRequest(url: Self.baseURL.appendingPathComponent("track/isrc:\(isrc)")))
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), envelope.error != nil {
            return nil
        }
        return try decode(TrackBody.self, from: data).track
    }

    /// The best search hit for the artist and title, or nil when there is none.
    public func search(artist: String, title: String) async throws -> DeezerTrack? {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "artist:\"\(artist)\" track:\"\(title)\""),
            URLQueryItem(name: "limit", value: "1"),
        ]
        let data = try await requester.perform(URLRequest(url: components.url!))
        return try decode(ListBody.self, from: data).data.first?.track
    }

    /// The global chart's top tracks, most popular first.
    public func chart(limit: Int = 100) async throws -> [DeezerTrack] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("chart/0/tracks"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        let data = try await requester.perform(URLRequest(url: components.url!))
        return try decode(ListBody.self, from: data).data.map(\.track)
    }

    private func decode<Body: Decodable>(_ type: Body.Type, from data: Data) throws -> Body {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LookupError.transport("Deezer response was not understood: \(error.localizedDescription)")
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
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
