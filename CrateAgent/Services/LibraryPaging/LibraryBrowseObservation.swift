import Combine
import Foundation
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
        let checklistRegions: [any DatabaseRegionConvertible] = LibraryChecklist.observedTables.map { table in
            SQLRequest<GRDB.Row>(sql: "SELECT * FROM \(table)")
        }
        let checklist = DatabaseRegionObservation(tracking: checklistRegions).publisher(in: database.writer)
            .map { _ in () }
            .throttle(for: LibraryChecklist.refreshThrottle, scheduler: DispatchQueue.global(qos: .utility), latest: true)
            .sink(receiveCompletion: { completion in
                if case let .failure(failure) = completion {
                    onError(failure)
                }
            }, receiveValue: { _ in onChange() })
        return AnyDatabaseCancellable {
            immediate.cancel()
            checklist.cancel()
        }
    }
}
