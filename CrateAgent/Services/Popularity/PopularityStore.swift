import Foundation
import GRDB

/// A recording the service can look up, with every identifier a source may take.
struct PopularityCandidate: Equatable, Sendable {
    let recordingKey: String
    let recordingMBID: String?
    let isrc: String?
    let artist: String
    let title: String
}

/// The only writer of `popularity_lookups` and `popularity_scores`. Scores are recomputed from a
/// recording's whole lookup history whenever a lookup lands, so they never drift from it.
enum PopularityStore {
    static let lookupsTable = "popularity_lookups"
    static let scoresTable = "popularity_scores"

    private static let candidateJoinSQL = "FROM files LEFT JOIN tracks ON tracks.id = files.track_id"

    static func record(_ observations: [PopularityObservation], now: Int64, in database: GRDB.Database) throws {
        for observation in observations {
            try database.execute(sql: """
            INSERT INTO \(lookupsTable) (recording_key, source, observed_at, value) VALUES (?, ?, ?, ?)
            ON CONFLICT(recording_key, source, observed_at) DO UPDATE SET value = excluded.value
            """, arguments: [observation.recordingKey, observation.source.rawValue, observation.observedAt, observation.value])
        }
        for recordingKey in Set(observations.map(\.recordingKey)) {
            try rescore(recordingKey, now: now, in: database)
        }
    }

    /// Recordings of active files with no score, or one older than `olderThan`, oldest first, one per key.
    static func staleRecordingKeys(limit: Int, olderThan: Int64, in database: GRDB.Database) throws -> [PopularityCandidate] {
        try Row.fetchAll(database, sql: """
        SELECT \(KeeperMarks.recordingKeySQL) AS recording_key, MIN(tracks.musicbrainz_recording_id) AS recording_mbid, MIN(tracks.isrc) AS isrc,
               MAX(COALESCE(tracks.artist, files.artist, '')) AS artist, MAX(COALESCE(tracks.title, files.title, '')) AS title,
               scores.updated_at AS updated_at
        \(candidateJoinSQL)
        LEFT JOIN \(scoresTable) AS scores ON scores.recording_key = \(KeeperMarks.recordingKeySQL)
        WHERE \(FileProcessingEligibility.processableSQL) AND (scores.updated_at IS NULL OR scores.updated_at < ?)
        GROUP BY 1
        ORDER BY scores.updated_at IS NOT NULL, scores.updated_at, 1
        LIMIT ?
        """, arguments: [olderThan, limit]).map { row in
            PopularityCandidate(recordingKey: row["recording_key"], recordingMBID: row["recording_mbid"], isrc: row["isrc"],
                                artist: row["artist"], title: row["title"])
        }
    }

    /// Replaces every chart seed with these positions: a recording off the chart loses its seed, and a computed
    /// Hot always wins over a seed. All-time and detail stay, and a recording never looked up stays due for one.
    static func seedHot(_ seeds: [(recordingKey: String, hot: Double)], now _: Int64, in database: GRDB.Database) throws {
        try database.execute(sql: "UPDATE \(scoresTable) SET chart_hot = NULL WHERE chart_hot IS NOT NULL")
        for seed in seeds {
            try database.execute(sql: """
            INSERT INTO \(scoresTable) (recording_key, all_time, hot, chart_hot, detail, updated_at) VALUES (?, NULL, NULL, ?, '', 0)
            ON CONFLICT(recording_key) DO UPDATE SET chart_hot = excluded.chart_hot
            """, arguments: [seed.recordingKey, seed.hot])
        }
    }

    /// Recording keys of active files whose folded artist and title match an entry, by entry index.
    static func recordingKeys(matching entries: [(artist: String, title: String)], in database: GRDB.Database) throws -> [Int: [String]] {
        var byFoldedPair: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            byFoldedPair[foldedPair(artist: entry.artist, title: entry.title), default: []].append(index)
        }
        var matches: [Int: [String]] = [:]
        let rows = try Row.fetchCursor(database, sql: """
        SELECT \(KeeperMarks.recordingKeySQL) AS recording_key, COALESCE(tracks.artist, files.artist, '') AS artist,
               COALESCE(tracks.title, files.title, '') AS title
        \(candidateJoinSQL) WHERE \(FileProcessingEligibility.processableSQL)
        """)
        while let row = try rows.next() {
            guard let indices = byFoldedPair[foldedPair(artist: row["artist"], title: row["title"])] else { continue }
            let recordingKey: String = row["recording_key"]
            for index in indices where matches[index]?.contains(recordingKey) != true {
                matches[index, default: []].append(recordingKey)
            }
        }
        return matches
    }

    /// Case, width and diacritics folded, whitespace collapsed; the comparison Deezer search hits are checked with.
    static func folded(_ text: String) -> String {
        text.split(whereSeparator: BlankText.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func foldedPair(artist: String, title: String) -> String {
        "\(folded(artist))\u{1F}\(folded(title))"
    }

    private static func rescore(_ recordingKey: String, now: Int64, in database: GRDB.Database) throws {
        var history: [PopularitySource: [(observedAt: Int64, value: Double)]] = [:]
        let rows = try Row.fetchCursor(database, sql: "SELECT source, observed_at, value FROM \(lookupsTable) WHERE recording_key = ?", arguments: [recordingKey])
        while let row = try rows.next() {
            let name: String = row["source"]
            guard let source = PopularitySource(rawValue: name) else { throw PopularityStoreError.unexpectedSource(name) }
            history[source, default: []].append((row["observed_at"], row["value"]))
        }
        let latest = history.compactMapValues { observations in observations.max { lhs, rhs in lhs.observedAt < rhs.observedAt }?.value }
        let hot = PopularityScoring.hot(history: history, now: now)
        try database.execute(sql: """
        INSERT INTO \(scoresTable) (recording_key, all_time, hot, detail, updated_at) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(recording_key) DO UPDATE SET all_time = excluded.all_time, hot = excluded.hot, detail = excluded.detail,
            updated_at = excluded.updated_at
        """, arguments: [recordingKey, PopularityScoring.allTime(latest: latest), hot, PopularityScoring.detail(latest: latest), now])
    }
}

enum PopularityStoreError: LocalizedError, Equatable {
    case unexpectedSource(String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedSource(name): "The popularity table holds an unknown source: \(name)."
        }
    }
}
