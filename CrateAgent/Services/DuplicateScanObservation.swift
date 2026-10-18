import GRDB

/// Notifies the Duplicates panel when a column that can change either
/// mode's groups, or what their rows display, is written: fingerprints
/// landing, hashes, membership/availability, the projected metadata and
/// content and decoded-audio digests, and kept label reviews.
enum DuplicateScanObservation {
    static func start(in database: LibraryDatabase,
                      onChange: @escaping @Sendable () -> Void,
                      onError: @escaping @Sendable (Error) -> Void) -> AnyDatabaseCancellable
    {
        let tracked = SQLRequest<GRDB.Row>(sql: """
        SELECT \(DuplicateFileRow.columnsSQL), files.chromaprint_fingerprint, files.library_membership, files.file_availability
        FROM files
        """)
        return DatabaseRegionObservation(tracking: tracked, Table(DigestKind.content.table), Table(DigestKind.audio.table),
                                         Table(DuplicateLabelReview.table)).start(in: database.writer, onError: onError) { _ in onChange() }
    }
}
