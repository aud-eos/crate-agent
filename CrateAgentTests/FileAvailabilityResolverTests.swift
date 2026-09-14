@testable import CrateAgent
import GRDB
import XCTest

final class FileAvailabilityResolverTests: XCTestCase {
    func testRealFilesMissingOfflinePermissionsAndOrdinaryTrashFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Trash"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("music.mp3")
        try Data([1, 2]).write(to: source)
        let volume = try XCTUnwrap(source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        let resolver = FileAvailabilityResolver()
        XCTAssertEqual(try resolver.inspect(path: source.path, volumeID: volume), .available)
        let moved = directory.appendingPathComponent("Trash/music.mp3")
        try FileManager.default.moveItem(at: source, to: moved)
        XCTAssertEqual(try resolver.inspect(path: source.path, volumeID: volume), .missing)
        XCTAssertEqual(try resolver.inspect(path: moved.path, volumeID: volume), .available)
        XCTAssertEqual(try resolver.inspect(path: source.path, volumeID: UUID().uuidString), .offline)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: moved.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: moved.path) }
        XCTAssertEqual(try resolver.inspect(path: moved.path, volumeID: volume), .inaccessible)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: moved.path)
        try FileManager.default.removeItem(at: moved)
        XCTAssertEqual(try resolver.inspect(path: moved.path, volumeID: volume), .missing)
    }

    func testNativeTrashFixture() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("crate-agent-trash-test-\(UUID().uuidString).mp3")
        try Data([5, 6]).write(to: source)
        defer {
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.removeItem(at: source)
            }
        }
        let volume = try XCTUnwrap(source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        let metadata = try XCTUnwrap(FileMetadataCollector.collect(at: source.path))
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { connection in
            var file = FileRecord(id: 51, path: source.path, volumeUuid: volume, inode: metadata.inode, fileSize: metadata.fileSize, mtime: metadata.mtime)
            file.libraryMembership = .active
            file.fileAvailability = .available
            try file.insert(connection)
        }
        let engine = await MainActor.run {
            OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }), seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")))
        }
        let coordinator = FilesystemSyncCoordinator(operationEngine: engine, database: database)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
        let trashed = try XCTUnwrap(resultingURL as URL?)
        defer { try? FileManager.default.removeItem(at: trashed) }
        XCTAssertEqual(try FileAvailabilityResolver().inspect(path: trashed.path, volumeID: volume), .trashed)
        try await coordinator.handleObservations([
            .init(path: trashed.path, isFile: true, wasRenamed: true),
            .init(path: source.path, isFile: true, wasRemoved: true),
        ])
        try await database.writer.read { connection in
            let file = try XCTUnwrap(FileRecord.fetchOne(connection, key: 51))
            XCTAssertEqual(file.path, source.path)
            XCTAssertEqual(file.fileAvailability, .trashed)
            XCTAssertEqual(file.libraryMembership, .active)
            XCTAssertEqual(file.membershipRevision, 0)
            let events = try EventRecord.fetchAll(connection)
            XCTAssertEqual(events.count, 1)
            XCTAssertFalse(events.contains { $0.eventType.hasReplayableSeratoProjection })
        }
        try Data([99, 100]).write(to: source)
        try await coordinator.handleObservations([.init(path: source.path, isFile: true, wasCreated: true)])
        try await database.writer.read { connection in
            let file = try XCTUnwrap(FileRecord.fetchOne(connection, key: 51))
            XCTAssertEqual(file.fileAvailability, .trashed)
            XCTAssertEqual(file.inode, metadata.inode)
            XCTAssertEqual(try EventRecord.fetchCount(connection), 1)
        }
        let reconciliationRequested = await coordinator.takeReconciliationRequest()
        XCTAssertTrue(reconciliationRequested)
        XCTAssertEqual(try FileAvailabilityResolver().inspect(path: trashed.path, volumeID: volume), .trashed)
    }
}
