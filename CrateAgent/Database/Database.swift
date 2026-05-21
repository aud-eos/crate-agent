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
        let pool = try DatabasePool(path: databaseUrl.path)
        return try LibraryDatabase(writer: pool)
    }

    /// Open an in-memory database. Used by unit and integration tests.
    public static func openInMemory() throws -> LibraryDatabase {
        let queue = try DatabaseQueue()
        return try LibraryDatabase(writer: queue)
    }

    private static func runMigrations(_ writer: any DatabaseWriter) throws {
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
        try migrator.migrate(writer)
    }
}
