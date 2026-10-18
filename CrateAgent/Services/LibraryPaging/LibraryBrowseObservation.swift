import GRDB

enum LibraryBrowseObservation {
    static func start(in database: LibraryDatabase,
                      onChange: @escaping @Sendable () -> Void,
                      onError: @escaping @Sendable (Error) -> Void) -> AnyDatabaseCancellable
    {
        let projection = SQLRequest<GRDB.Row>(sql: BrowserRow.browserFetchSQL)
        let families = SQLRequest<GRDB.Row>(sql: "SELECT files.track_id, tracks.work_id, tracks.musicbrainz_recording_id, works.representative_track_id FROM files LEFT JOIN tracks ON tracks.id = files.track_id LEFT JOIN works ON works.id = tracks.work_id")
        return DatabaseRegionObservation(tracking: projection, families).start(in: database.writer, onError: onError) { _ in onChange() }
    }
}
