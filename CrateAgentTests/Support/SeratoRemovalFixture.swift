@testable import CrateAgent
import Foundation
import GRDB

enum SeratoTestEncoding {
    static func record(_ tag: String, _ payload: Data) -> Data {
        precondition(tag.utf8.count == 4)
        var length = UInt32(payload.count).bigEndian
        return Data(tag.utf8) + withUnsafeBytes(of: &length) { bytes in Data(bytes) } + payload
    }

    static func library(paths: [String]) -> Data {
        paths.reduce(record("vrsn", "2.0/Serato Scratch LIVE Database".data(using: .utf16BigEndian)!)) { bytes, path in
            bytes + record("otrk", record("pfil", path.data(using: .utf16BigEndian)!))
        }
    }
}

@MainActor
final class SeratoRemovalFixture {
    let directory: URL
    let database: LibraryDatabase
    let locator: SeratoLibraryLocator
    let watchdog: SeratoWatchdog
    let reader: SeratoMembershipSnapshotReader
    let engine: OperationEngine
    let reconciler: SeratoMembershipReconciler
    let lifecycle = Lifecycle()
    final class Lifecycle { var running = false }

    init(readiness: LibrarySyncReadiness? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        locator = SeratoLibraryLocator(seratoDirectory: directory)
        try FileManager.default.createDirectory(at: locator.subcratesDirectoryUrl, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locator.smartCratesDirectoryUrl, withIntermediateDirectories: true)
        database = try LibraryDatabase.openInMemory()
        let lifecycle = lifecycle
        watchdog = SeratoWatchdog { lifecycle.running ? ["com.serato.dj"] : [] }
        reader = SeratoMembershipSnapshotReader(locator: locator, watchdog: watchdog)
        engine = OperationEngine(database: database, seratoWatchdog: watchdog, seratoLocator: locator, readiness: readiness)
        reconciler = SeratoMembershipReconciler(database: database, operationEngine: engine, reader: reader)
        try save(paths: [])
    }

    func cleanup() {
        do { try FileManager.default.removeItem(at: directory) }
        catch { preconditionFailure("Could not clean removal fixture: \(error)") }
    }

    func save(paths: [String]) throws {
        try SeratoTestEncoding.library(paths: paths).write(to: locator.databaseV2Url)
    }

    func add(_ name: String, membership: LibraryMembership = .active) async throws -> FileRecord {
        let path = directory.appendingPathComponent(name).path
        try Data([1, 2, 3, 4]).write(to: URL(fileURLWithPath: path))
        let metadata = FileMetadataCollector.collect(at: path, includeLightweightHash: true)!
        let owner = try await reader.read().libraryID
        return try await database.writer.write { connection in
            var file = FileRecord(path: path, volumeUuid: metadata.volumeUuid, inode: metadata.inode, fileSize: metadata.fileSize, mtime: metadata.mtime, lightweightHash: metadata.lightweightHash)
            file.libraryMembership = membership
            file.fileAvailability = .available
            file.seratoLibraryId = membership == .legacyUnverified ? nil : owner
            try file.insert(connection)
            return file
        }
    }

    func row(_ file: FileRecord) async throws -> FileRecord {
        try await database.writer.read { connection in try FileRecord.fetchOne(connection, key: file.id)! }
    }

    func events() async throws -> Int {
        try await database.writer.read { connection in try EventRecord.fetchCount(connection) }
    }

    func reconcile() async throws -> ReconciliationSummary {
        try await reconciler.reconcile(reader.read())
    }
}
