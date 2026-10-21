import Foundation

/// Where a popularity figure comes from. Both are keyless; each is switched off until the owner enables it.
enum PopularitySource: String, CaseIterable, Codable, Sendable {
    case listenBrainz = "listenbrainz"
    case deezer
}

/// One source's raw figure for a recording at one time: ListenBrainz total listens, or Deezer rank.
struct PopularityObservation: Equatable, Sendable {
    let recordingKey: String
    let source: PopularitySource
    let observedAt: Int64
    let value: Double
}

/// The formulas behind the two scores. All-time normalizes each source to 0 to 100 and averages them.
/// Hot is growth between a recording's latest figure and an earlier one at least a week older, so
/// it needs two lookups per source; the Deezer chart seeds it meanwhile.
enum PopularityScoring {
    static let hotMinimumGap: Int64 = 7 * 86400
    static let hotWindow: Int64 = 28 * 86400
    static let refreshInterval: Int64 = 7 * 86400
    /// 10 million ListenBrainz listens, and the top of Deezer's rank range, both score 100.
    private static let listenBrainzSaturationLog10 = 7.0
    private static let deezerSaturationRank = 1_000_000.0

    static func allTime(latest: [PopularitySource: Double]) -> Double? {
        let scores = latest.map { source, value -> Double in
            switch source {
            case .listenBrainz: min(100, log10(value + 1) / listenBrainzSaturationLog10 * 100)
            case .deezer: min(100, value / deezerSaturationRank * 100)
            }
        }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    static func hot(history: [PopularitySource: [(observedAt: Int64, value: Double)]], now: Int64) -> Double? {
        let growths = history.values.compactMap { observations -> Double? in
            guard let latest = observations.max(by: { lhs, rhs in lhs.observedAt < rhs.observedAt }) else { return nil }
            let earlier = observations.filter { observation in
                observation.observedAt <= latest.observedAt - hotMinimumGap && observation.observedAt >= now - hotWindow
            }.min { lhs, rhs in lhs.observedAt < rhs.observedAt }
            guard let earlier else { return nil }
            return (latest.value - earlier.value) / max(earlier.value, 1) * 100
        }
        guard !growths.isEmpty else { return nil }
        return growths.reduce(0, +) / Double(growths.count)
    }

    static func detail(latest: [PopularitySource: Double]) -> String {
        PopularitySource.allCases.compactMap { source in latest[source].map { value in PopularityMessages.detail(source, value: value) } }
            .joined(separator: " · ")
    }
}
