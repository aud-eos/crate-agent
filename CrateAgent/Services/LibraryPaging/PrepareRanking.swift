/// The order Prepare works through unfinished tracks: the most promising first.
/// A track's rank is its Popularity and Hot scores (0 to 100 each) plus
/// `pointsPerPlay` for each of the owner's own Serato plays. A track with none of
/// the three signals has no rank and comes last, so an unlooked-up library still
/// orders by what the owner has played. `sql` and `score` are the same formula.
enum PrepareRanking {
    static let pointsPerPlay = 10.0

    static func sql(_ alias: String) -> String {
        let allTime = "\(alias).popularity_all_time"
        let hot = "\(alias).popularity_hot"
        let plays = "\(alias).play_count"
        return "CASE WHEN \(allTime) IS NULL AND \(hot) IS NULL AND \(plays) IS NULL THEN NULL "
            + "ELSE COALESCE(\(allTime), 0) + COALESCE(\(hot), 0) + COALESCE(\(plays), 0) * \(pointsPerPlay) END"
    }

    static func score(allTime: Double?, hot: Double?, plays: Int?) -> Double? {
        if allTime == nil, hot == nil, plays == nil {
            return nil
        }
        return (allTime ?? 0) + (hot ?? 0) + Double(plays ?? 0) * pointsPerPlay
    }
}
