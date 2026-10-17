import Foundation
import GRDB

/// Sidecar SQLite database for crate-agent.
///
/// Stores everything the Serato library can't: file identity (path,
/// inode, hash, fingerprint), track identity, work groupings, and the
/// append-only event log that powers undo and per-file history.
///
/// Lives at `~/Library/Application Support/crate-agent/library.sqlite`
/// at runtime; tests open an in-memory variant via `openInMemory()`.
public final class LibraryDatabase {
    public static let shared: LibraryDatabase = {
        do {
            return try LibraryDatabase.openDefault()
        } catch {
            // Loud failure per the no-silent-failures invariant.
            // If we cannot open the sidecar DB, the app cannot do
            // useful work; better to crash here than to limp along
            // with phantom state.
            fatalError("Failed to open crate-agent database: \(error)")
        }
    }()

    public let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.runMigrations(writer)
    }

    /// Open the production database file under Application Support.
    /// Creates the directory and migrates the schema on first launch.
    public static func openDefault() throws -> LibraryDatabase {
        try ApplicationRuntime.requireLiveResources()
        let applicationSupportUrl = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let crateAgentDirectory = applicationSupportUrl.appendingPathComponent(
            "crate-agent",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: crateAgentDirectory,
            withIntermediateDirectories: true
        )
        let databaseUrl = crateAgentDirectory.appendingPathComponent("library.sqlite")
        return try openWAL(at: databaseUrl)
    }

    static func openWAL(at url: URL) throws -> LibraryDatabase {
        let pool = try DatabasePool(path: url.path, configuration: makeConfiguration())
        return try LibraryDatabase(writer: pool)
    }

    /// Open an in-memory database. Used by unit and integration tests.
    public static func openInMemory() throws -> LibraryDatabase {
        let queue = try DatabaseQueue(configuration: makeConfiguration())
        return try LibraryDatabase(writer: queue)
    }

    /// Tuning PRAGMAs applied to every connection. `journal_mode=WAL`
    /// is already forced by `DatabasePool`; `foreign_keys=ON` is
    /// GRDB's default. The rest exist because SQLite's stock
    /// settings are conservatively tuned for embedded devices, not
    /// for a desktop app holding tens of thousands of rows hot.
    private static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            ListSearch.register(in: database)
            // NORMAL is the WAL-mode recommended setting: durable
            // across power loss (committed transactions survive),
            // but only fsyncs once per commit instead of twice.
            // Halves write latency for the initial Serato-library
            // scan, where every track is its own transaction.
            try database.execute(sql: "PRAGMA synchronous = NORMAL")
            // 8 MB page cache. Default is ~2 MB, which forces page
            // evictions during the hygiene scan over 30k+ rows.
            try database.execute(sql: "PRAGMA cache_size = -8000")
            // Keep temp B-trees (ORDER BY, GROUP BY, hash joins) in
            // RAM rather than spilling to a temp file on disk.
            try database.execute(sql: "PRAGMA temp_store = MEMORY")
            // 128 MB mmap window. Lets SQLite read pages via the
            // page cache without a read() syscall per page; matters
            // for the History panel's full-events aggregation and
            // the LibraryBrowser's full-files scan.
            try database.execute(sql: "PRAGMA mmap_size = 134217728")
        }
        return configuration
    }

    private static func runMigrations(_ writer: any DatabaseWriter) throws {
        try makeMigrator().migrate(writer)
    }

    /// Builds the migrator with every registered migration, in
    /// registration order. Not private: tests that need to seed
    /// pre-migration data (e.g. asserting a reset migration's effect
    /// on a `done`-status row) migrate a fresh database up to a named
    /// migration, insert legacy-shaped rows, then finish migrating and
    /// assert -- this is the one place that ordering is defined, so
    /// tests reuse it rather than re-declaring their own subset.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
            migrator.eraseDatabaseOnSchemaChange = false
        #endif
        InitialSchemaMigration.register(in: &migrator)
        PivotToSeratoSourceOfTruthMigration.register(in: &migrator)
        AddSeratoMetadataToFilesMigration.register(in: &migrator)
        AddBitrateToFilesMigration.register(in: &migrator)
        ResetFingerprintsForDurationCapMigration.register(in: &migrator)
        AddEventsBatchAggIndexMigration.register(in: &migrator)
        AddMusicBrainzColumnsMigration.register(in: &migrator)
        ResetFingerprintsForAlgorithmTest2Migration.register(in: &migrator)
        AddFingerprintFreshnessBasisMigration.register(in: &migrator)
        AddFileLibraryStateMigration.register(in: &migrator)
        AddSyncCheckpointMigration.register(in: &migrator)
        AddSyncStatProjectionMigration.register(in: &migrator)
        AddDurableSeratoQueueMigration.register(in: &migrator)
        AddSeratoWriteLandedMarkerMigration.register(in: &migrator)
        AddFileTrashLocationsMigration.register(in: &migrator)
        AddFingerprintFailureReasonMigration.register(in: &migrator)
        AddSubsecondFileIdentityMigration.register(in: &migrator)
        return migrator
    }
}
