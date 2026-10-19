import GRDB

enum LibraryBrowseObservation {
    /// `files` and family changes refresh at once. Checklist fact tables refresh at most once per
    /// `LibraryChecklist.refreshThrottle`, so background backfills don't reopen the snapshot continuously.
    static func start(in database: LibraryDatabase,
                      onChange: @escaping @Sendable () -> Void,
                      onError: @escaping @Sendable (Error) -> Void) -> AnyDatabaseCancellable
    {
        let projection = SQLRequest<GRDB.Row>(sql: BrowserRow.browserFetchSQL)
        let families = SQLRequest<GRDB.Row>(sql: """
        SELECT files.track_id, files.last_projection_invalidation_revision, tracks.work_id, tracks.musicbrainz_recording_id,
               works.representative_track_id
        FROM files LEFT JOIN tracks ON tracks.id = files.track_id LEFT JOIN works ON works.id = tracks.work_id
        """)
        let immediate = DatabaseRegionObservation(tracking: projection, families).start(in: database.writer, onError: onError) { _ in onChange() }
        let throttle = RefreshThrottle(interval: LibraryChecklist.refreshThrottle, action: onChange)
        let checklistRegions: [any DatabaseRegionConvertible] = LibraryChecklist.observedTables.map { table in SQLRequest<GRDB.Row>(sql: "SELECT * FROM \(table)") }
        let checklist = DatabaseRegionObservation(tracking: checklistRegions).start(in: database.writer, onError: onError) { _ in
            Task { await throttle.signal() }
        }
        return AnyDatabaseCancellable {
            immediate.cancel()
            checklist.cancel()
            Task { await throttle.cancel() }
        }
    }
}

/// Runs `action` on the first signal, then at most once per `interval`; signals inside an interval
/// coalesce into one trailing run, so the last change is never dropped.
actor RefreshThrottle {
    private let interval: Duration
    private let action: @Sendable () -> Void
    private var lastRun: ContinuousClock.Instant?
    private var trailing: Task<Void, Never>?
    private var isCancelled = false

    init(interval: Duration, action: @escaping @Sendable () -> Void) {
        self.interval = interval
        self.action = action
    }

    func signal() {
        guard !isCancelled, trailing == nil else { return }
        let now = ContinuousClock.now
        guard let lastRun, now - lastRun < interval else {
            run()
            return
        }
        let delay = interval - (now - lastRun)
        trailing = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.runTrailing()
        }
    }

    func cancel() {
        isCancelled = true
        trailing?.cancel()
        trailing = nil
    }

    private func runTrailing() {
        trailing = nil
        guard !isCancelled else { return }
        run()
    }

    private func run() {
        lastRun = .now
        action()
    }
}
