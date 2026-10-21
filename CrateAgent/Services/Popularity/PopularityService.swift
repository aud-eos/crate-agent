import Foundation
import GRDB

/// Looks recordings up on the popularity sources the owner switched on, in the
/// background, and keeps `popularity_scores` fresh through `PopularityStore`.
/// Nothing is sent while every source is off. A pass takes the stalest recordings
/// first, in batches, so a 30,000-file library fills in over several passes
/// without holding the writer; a lookup error ends the pass and keeps what landed.
@MainActor
final class PopularityService: ObservableObject {
    enum Status: Equatable {
        case off
        case notRefreshed
        case refreshing(done: Int, total: Int)
        case refreshed(count: Int)
        /// The reason the last pass stopped; scores already stored stay.
        case failed(String)
    }

    static let batchSize = 50
    static let passLimit = 500
    static let chartSize = 100

    @Published private(set) var status: Status = .notRefreshed

    private let database: LibraryDatabase
    let preferences: PreferencesStore
    private let readiness: LibrarySyncReadiness?
    private let listenBrainz: ListenBrainzClient
    private let deezer: DeezerClient
    private let now: () -> Int64
    private var isRefreshing = false
    private var refreshRequested = false

    init(database: LibraryDatabase, preferences: PreferencesStore, readiness: LibrarySyncReadiness?,
         listenBrainz: ListenBrainzClient, deezer: DeezerClient, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) })
    {
        self.database = database
        self.preferences = preferences
        self.readiness = readiness
        self.listenBrainz = listenBrainz
        self.deezer = deezer
        self.now = now
        if preferences.enabledPopularitySources.isEmpty {
            status = .off
        }
    }

    var enabledSources: Set<PopularitySource> {
        preferences.enabledPopularitySources
    }

    /// A request made while a pass runs is coalesced into one more pass.
    func refresh() async {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequested = false
            await refreshOnce()
        } while refreshRequested
    }

    private func refreshOnce() async {
        let sources = enabledSources
        guard !sources.isEmpty else {
            status = .off
            return
        }
        let authorization: LibrarySyncReadiness.Authorization?
        do {
            authorization = try readiness?.capture()
        } catch {
            return
        }
        let startedAt = now()
        var lookedUp = 0
        do {
            let total = try await database.writer.read { connection in
                try PopularityStore.staleRecordingKeys(limit: Self.passLimit, olderThan: startedAt - PopularityScoring.refreshInterval, in: connection).count
            }
            status = .refreshing(done: 0, total: total)
            while lookedUp < Self.passLimit {
                let candidates = try await database.writer.read { connection in
                    try PopularityStore.staleRecordingKeys(limit: Self.batchSize, olderThan: startedAt - PopularityScoring.refreshInterval, in: connection)
                }
                guard !candidates.isEmpty else { break }
                let observations = try await observe(candidates, sources: sources)
                try authorization?.check()
                let recordedAt = now()
                try await database.writer.write { connection in
                    try PopularityStore.record(observations, now: recordedAt, in: connection)
                    try Self.markLookedUp(candidates, observed: Set(observations.map(\.recordingKey)), now: recordedAt, in: connection)
                }
                lookedUp += candidates.count
                status = .refreshing(done: lookedUp, total: total)
            }
            if sources.contains(.deezer) {
                try await seedHotFromChart(authorization: authorization)
            }
            try await database.writer.write { connection in
                try SeratoLibraryFacts.writeStamp(.popularity, "{}", in: connection)
            }
            status = .refreshed(count: lookedUp)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Every source's figure for the candidates it can look up; a source with nothing to send is skipped.
    private func observe(_ candidates: [PopularityCandidate], sources: Set<PopularitySource>) async throws -> [PopularityObservation] {
        let observedAt = now()
        var observations: [PopularityObservation] = []
        if sources.contains(.listenBrainz) {
            let withMBID = candidates.filter { candidate in candidate.recordingMBID != nil }
            if !withMBID.isEmpty {
                let counts = try await listenBrainz.listenCounts(recordingMBIDs: withMBID.compactMap(\.recordingMBID))
                for candidate in withMBID {
                    if let mbid = candidate.recordingMBID, let count = counts[mbid] {
                        observations.append(PopularityObservation(recordingKey: candidate.recordingKey, source: .listenBrainz, observedAt: observedAt, value: Double(count)))
                    }
                }
            }
        }
        if sources.contains(.deezer) {
            for candidate in candidates {
                try Task.checkCancellation()
                guard let track = try await deezerTrack(for: candidate) else { continue }
                observations.append(PopularityObservation(recordingKey: candidate.recordingKey, source: .deezer, observedAt: observedAt, value: Double(track.rank)))
            }
        }
        return observations
    }

    /// An ISRC hit is authoritative; a search hit counts only when its artist is the candidate's.
    private func deezerTrack(for candidate: PopularityCandidate) async throws -> DeezerTrack? {
        if let isrc = candidate.isrc, let track = try await deezer.track(isrc: isrc) {
            return track
        }
        guard !candidate.artist.isEmpty, !candidate.title.isEmpty,
              let hit = try await deezer.search(artist: candidate.artist, title: candidate.title),
              PopularityStore.folded(hit.artist) == PopularityStore.folded(candidate.artist) else { return nil }
        return hit
    }

    /// A candidate no source answered still gets `updated_at`, so the pass moves on instead of retrying it every time.
    private nonisolated static func markLookedUp(_ candidates: [PopularityCandidate], observed: Set<String>, now: Int64, in database: GRDB.Database) throws {
        for candidate in candidates where !observed.contains(candidate.recordingKey) {
            try database.execute(sql: """
            INSERT INTO \(PopularityStore.scoresTable) (recording_key, all_time, hot, detail, updated_at) VALUES (?, NULL, NULL, '', ?)
            ON CONFLICT(recording_key) DO UPDATE SET updated_at = excluded.updated_at
            """, arguments: [candidate.recordingKey, now])
        }
    }

    /// Seeds Hot from the Deezer chart at most once per refresh interval: position 1 scores 100, position 100 scores 1.
    private func seedHotFromChart(authorization: LibrarySyncReadiness.Authorization?) async throws {
        let seededAt = now()
        if let last = preferences.popularityChartSeededAt, seededAt - last < PopularityScoring.refreshInterval {
            return
        }
        let chart = try await deezer.chart(limit: Self.chartSize)
        try authorization?.check()
        try await database.writer.write { connection in
            let matches = try PopularityStore.recordingKeys(matching: chart.map { track in (artist: track.artist, title: track.title) }, in: connection)
            let seeds = matches.flatMap { position, keys in keys.map { key in (recordingKey: key, hot: Double(Self.chartSize - position)) } }
            try PopularityStore.seedHot(seeds, now: seededAt, in: connection)
        }
        preferences.popularityChartSeededAt = seededAt
    }
}
