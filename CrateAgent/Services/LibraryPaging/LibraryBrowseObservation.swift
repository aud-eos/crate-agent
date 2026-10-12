import GRDB

enum LibraryBrowseObservation {
    static func start(in database: LibraryDatabase,
                      onChange: @escaping @Sendable () -> Void,
                      onError: @escaping @Sendable (Error) -> Void) -> AnyDatabaseCancellable
    {
        let projection = SQLRequest<GRDB.Row>(sql: BrowserRow.browserFetchSQL)
        return DatabaseRegionObservation(tracking: projection).start(in: database.writer, onError: onError) { _ in onChange() }
    }
}
