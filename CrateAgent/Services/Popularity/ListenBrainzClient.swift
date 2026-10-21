import Foundation

/// ListenBrainz recording popularity: total listens per MusicBrainz recording ID, no key needed.
/// Only recording IDs are sent.
public struct ListenBrainzClient: Sendable {
    static let endpoint = URL(string: "https://api.listenbrainz.org/1/popularity/recording")!
    static let maximumIDsPerRequest = 100

    private let requester: RetryingLookupRequester
    private let userAgentHeaderValue: String

    public init(loader: URLLoading, limiter: RateLimiter, sleeper: BackoffSleeping = SystemBackoffSleeper(),
                appVersion: String = MusicBrainzClient.bundleAppVersion())
    {
        requester = RetryingLookupRequester(loader: loader, limiter: limiter, sleeper: sleeper)
        userAgentHeaderValue = "crate-agent/\(appVersion) ( \(MusicBrainzClient.contactURL) )"
    }

    /// Listen counts by recording ID; recordings ListenBrainz has no count for are left out.
    public func listenCounts(recordingMBIDs: [String]) async throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for start in stride(from: 0, to: recordingMBIDs.count, by: Self.maximumIDsPerRequest) {
            let batch = Array(recordingMBIDs[start ..< min(start + Self.maximumIDsPerRequest, recordingMBIDs.count)])
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue(userAgentHeaderValue, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(Request(recordingMBIDs: batch))
            let data = try await requester.perform(request)
            let entries: [Entry]
            do {
                entries = try JSONDecoder().decode([Entry].self, from: data)
            } catch {
                throw LookupError.transport("ListenBrainz popularity response was not understood: \(error.localizedDescription)")
            }
            for entry in entries {
                if let count = entry.totalListenCount {
                    counts[entry.recordingMBID] = count
                }
            }
            try Task.checkCancellation()
        }
        return counts
    }

    private struct Request: Encodable {
        let recordingMBIDs: [String]

        enum CodingKeys: String, CodingKey {
            case recordingMBIDs = "recording_mbids"
        }
    }

    private struct Entry: Decodable {
        let recordingMBID: String
        let totalListenCount: Int?

        enum CodingKeys: String, CodingKey {
            case recordingMBID = "recording_mbid"
            case totalListenCount = "total_listen_count"
        }
    }
}
