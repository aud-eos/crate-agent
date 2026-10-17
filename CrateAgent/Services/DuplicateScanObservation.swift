import GRDB

/// Notifies the Duplicates panel when a column that can change either
/// mode's groups, or what their rows display, is written: fingerprints
/// landing, hashes, membership/availability and the projected metadata.
enum DuplicateScanObservation {
    static func start(in database: LibraryDatabase,
                      onChange: @escaping @Sendable () -> Void,
                      onError: @escaping @Sendable (Error) -> Void) -> AnyDatabaseCancellable
    {
        let tracked = SQLRequest<GRDB.Row>(sql: """
        SELECT \(DuplicateFileRow.columnsSQL), files.chromaprint_fingerprint, files.library_membership, files.file_availability
        FROM files
        """)
        return DatabaseRegionObservation(tracking: tracked).start(in: database.writer, onError: onError) { _ in onChange() }
    }
}
