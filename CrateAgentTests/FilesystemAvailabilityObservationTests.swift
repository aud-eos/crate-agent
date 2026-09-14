@testable import CrateAgent
import GRDB
import XCTest

final class FilesystemAvailabilityObservationTests: XCTestCase {
    func testPreviouslyAvailablePathReplacementInvalidatesEligibility() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.mp3")
        let held = directory.appendingPathComponent("held.mp3")
        try Data([1, 2]).write(to: source)
        let metadata = try XCTUnwrap(FileMetadataCollector.collect(at: source.path))
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { connection in
            var file = FileRecord(id: 51, path: source.path, volumeUuid: metadata.volumeUuid, inode: metadata.inode, fileSize: metadata.fileSize, mtime: metadata.mtime)
            file.libraryMembership = .active
            file.fileAvailability = .available
            try file.insert(connection)
        }
        let engine = await MainActor.run {
            OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }), seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")))
        }
        let coordinator = FilesystemSyncCoordinator(operationEngine: engine, database: database)
        try FileManager.default.moveItem(at: source, to: held)
        try Data([99, 100]).write(to: source)
        try await coordinator.handleObservations([.init(path: source.path, isFile: true, wasCreated: true)])
        try await database.writer.read { connection in
            let file = try XCTUnwrap(FileRecord.fetchOne(connection, key: 51))
            XCTAssertEqual(file.fileAvailability, .unknown)
            XCTAssertEqual(file.inode, metadata.inode)
            XCTAssertEqual(file.libraryMembership, .active)
            XCTAssertEqual(file.membershipRevision, 0)
            XCTAssertThrowsError(try FileProcessingEligibility.requireProcessable(file))
            let event = try XCTUnwrap(EventRecord.fetchOne(connection))
            XCTAssertEqual(event.eventType, .fileLibraryStateChanged)
            let inverse = try JSONDecoder().decode(SetFileLibraryStatePayload.self, from: Data(event.inversePayloadJson.utf8))
            XCTAssertEqual(inverse.state.availability, .available)
        }
        let requested = await coordinator.takeReconciliationRequest()
        XCTAssertTrue(requested)
    }

    func testMissingPathReplacementDoesNotRestoreOriginalButSameIdentityDoes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.mp3")
        let held = directory.appendingPathComponent("held.mp3")
        try Data([1, 2]).write(to: source)
        let metadata = try XCTUnwrap(FileMetadataCollector.collect(at: source.path))
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { connection in
            var file = FileRecord(id: 51, path: source.path, volumeUuid: metadata.volumeUuid, inode: metadata.inode, fileSize: metadata.fileSize, mtime: metadata.mtime)
            file.libraryMembership = .active
            file.fileAvailability = .missing
            try file.insert(connection)
        }
        let engine = await MainActor.run {
            OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }), seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")))
        }
        let coordinator = FilesystemSyncCoordinator(operationEngine: engine, database: database)
        try FileManager.default.moveItem(at: source, to: held)
        try Data([99, 100]).write(to: source)
        try await coordinator.handleObservations([.init(path: source.path, isFile: true, wasCreated: true)])
        try await database.writer.read { connection in
            let file = try XCTUnwrap(FileRecord.fetchOne(connection, key: 51))
            XCTAssertEqual(file.fileAvailability, .missing)
            XCTAssertEqual(file.inode, metadata.inode)
            XCTAssertThrowsError(try FileProcessingEligibility.requireProcessable(file))
            XCTAssertEqual(try EventRecord.fetchCount(connection), 0)
        }
        let request = await coordinator.takeReconciliationRequest()
        XCTAssertTrue(request)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: held, to: source)
        try await coordinator.handleObservations([.init(path: source.path, isFile: true, wasRenamed: true)])
        try await database.writer.read { connection in
            let file = try XCTUnwrap(FileRecord.fetchOne(connection, key: 51))
            XCTAssertEqual(file.fileAvailability, .available)
            XCTAssertEqual(file.inode, metadata.inode)
            XCTAssertEqual(file.membershipRevision, 0)
            XCTAssertEqual(try EventRecord.fetchCount(connection), 1)
        }
        let restoreRequest = await coordinator.takeReconciliationRequest()
        XCTAssertFalse(restoreRequest)
    }

    func testCreatedHardLinkPreservesOriginalLocationAndSeratoBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.mp3")
        let linked = directory.appendingPathComponent("linked.mp3")
        try Data([1, 2]).write(to: source)
        let metadata = try XCTUnwrap(FileMetadataCollector.collect(at: source.path))
        let seratoURL = directory.appendingPathComponent("database V2")
        let originalBytes = OperationEngineTests.synthesizeDatabaseV2BytesForTest(withTrackPaths: [String(source.path.dropFirst())])
        try originalBytes.write(to: seratoURL)
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { connection in
            var file = FileRecord(id: 51, path: source.path, volumeUuid: metadata.volumeUuid, inode: metadata.inode, fileSize: metadata.fileSize, mtime: metadata.mtime)
            file.libraryMembership = .active
            file.fileAvailability = .available
            try file.insert(connection)
        }
        let engine = await MainActor.run {
            OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }), seratoLocator: SeratoLibraryLocator(seratoDirectory: directory))
        }
        let coordinator = FilesystemSyncCoordinator(operationEngine: engine, database: database)
        try FileManager.default.linkItem(at: source, to: linked)
        try await coordinator.handleObservations([.init(path: linked.path, isFile: true, wasCreated: true)])
        try await database.writer.read { connection in
            XCTAssertEqual(try FileRecord.fetchOne(connection, key: 51)?.path, source.path)
            XCTAssertEqual(try EventRecord.fetchCount(connection), 0)
        }
        XCTAssertEqual(try Data(contentsOf: seratoURL), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testDatabaseFailureThrowsPathContext() async throws {
        let database = try LibraryDatabase.openInMemory()
        let engine = await MainActor.run {
            OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }), seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")))
        }
        try await database.writer.write { connection in try connection.execute(sql: "DROP TABLE files") }
        let coordinator = FilesystemSyncCoordinator(operationEngine: engine, database: database)
        do {
            try await coordinator.handleObservations([.init(path: "/fixture.mp3", isFile: true, wasRemoved: true)])
            XCTFail("Database failure must not be acknowledged")
        } catch let error as FilesystemObservationError {
            XCTAssertEqual(error.path, "/fixture.mp3")
            XCTAssertTrue(error.underlying is DatabaseError)
        }
    }

    func testReplayAfterRegroupingRepairsCommittedRenameBeforeCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("before.mp3")
        let destination = directory.appendingPathComponent("after.mp3")
        try Data([1, 2]).write(to: source)
        let metadata = try XCTUnwrap(FileMetadataCollector.collect(at: source.path))
        let seratoURL = directory.appendingPathComponent("database V2")
        try Data([0, 1, 2]).write(to: seratoURL)
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { connection in
            var file = FileRecord(id: 51, path: source.path, volumeUuid: metadata.volumeUuid, inode: metadata.inode, fileSize: metadata.fileSize, mtime: metadata.mtime)
            file.libraryMembership = .active
            file.fileAvailability = .available
            try file.insert(connection)
        }
        let engine = await MainActor.run {
            OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }), seratoLocator: SeratoLibraryLocator(seratoDirectory: directory))
        }
        let coordinator = FilesystemSyncCoordinator(operationEngine: engine, database: database)
        try FileManager.default.moveItem(at: source, to: destination)
        let renamed = FSEventsObservation(path: destination.path, isFile: true, wasRenamed: true, eventID: 100)
        do {
            try await coordinator.handleBatch(.init(observations: [renamed], highestEventID: 100))
            XCTFail("Malformed Serato fixture must fail external write")
        } catch {
            XCTAssertTrue(error is FilesystemObservationError)
        }
        let committedPath = try await database.writer.read { try FileRecord.fetchOne($0, key: 51)?.path }
        XCTAssertEqual(committedPath, destination.path)
        try OperationEngineTests.synthesizeDatabaseV2BytesForTest(withTrackPaths: [String(source.path.dropFirst())]).write(to: seratoURL)
        let restarted = FilesystemSyncCoordinator(operationEngine: engine, database: database)
        let later = FSEventsObservation(path: "/unknown-fixture", eventID: 101)
        try await restarted.handleBatch(.init(observations: [renamed, later], highestEventID: 101))
        let expected = OperationEngineTests.synthesizeDatabaseV2BytesForTest(withTrackPaths: [String(destination.path.dropFirst())])
        XCTAssertEqual(try Data(contentsOf: seratoURL), expected)
        let eventCount = try await database.writer.read { try EventRecord.fetchCount($0) }
        XCTAssertEqual(eventCount, 1)
    }

    func testRetiredMoveObservesLocationAndAvailabilityWithoutOutboundWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("before.mp3")
        let destination = directory.appendingPathComponent("restored.mp3")
        try Data([1, 2]).write(to: source)
        let metadata = try XCTUnwrap(FileMetadataCollector.collect(at: source.path))
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { connection in
            var file = FileRecord(id: 51, path: source.path, volumeUuid: metadata.volumeUuid, inode: metadata.inode, fileSize: metadata.fileSize, mtime: metadata.mtime)
            file.libraryMembership = .retired
            file.membershipRevision = 8
            file.fileAvailability = .trashed
            file.retiredAt = 42
            try file.insert(connection)
        }
        let engine = await MainActor.run {
            OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }), seratoLocator: SeratoLibraryLocator(seratoDirectory: directory.appendingPathComponent("absent-serato")))
        }
        let coordinator = FilesystemSyncCoordinator(operationEngine: engine, database: database)
        try FileManager.default.moveItem(at: source, to: destination)
        try await coordinator.handleObservations([.init(path: destination.path, isFile: true, wasRenamed: true)])
        try await database.writer.read { connection in
            let file = try XCTUnwrap(FileRecord.fetchOne(connection, key: 51))
            XCTAssertEqual(file.path, destination.path)
            XCTAssertEqual(file.libraryMembership, .retired)
            XCTAssertEqual(file.fileAvailability, .available)
            XCTAssertEqual(file.membershipRevision, 8)
            XCTAssertEqual(file.retiredAt, 42)
            let events = try EventRecord.fetchAll(connection)
            XCTAssertEqual(events.count, 2)
            XCTAssertFalse(events.contains { $0.eventType.hasReplayableSeratoProjection })
            let location = try XCTUnwrap(events.first { $0.eventType == .fileLocationObserved })
            let inverse = try JSONDecoder().decode(ObserveFileLocationPayload.self, from: Data(location.inversePayloadJson.utf8))
            XCTAssertEqual(inverse.path, source.path)
            XCTAssertEqual(inverse.inode, metadata.inode)
            XCTAssertEqual(inverse.volumeUuid, metadata.volumeUuid)
            XCTAssertEqual(inverse.expectedRevision, 8)
        }
        try await coordinator.handleObservations([.init(path: destination.path, isFile: true, wasRenamed: true)])
        let count = try await database.writer.read { try EventRecord.fetchCount($0) }
        XCTAssertEqual(count, 2)
    }

    func testDirectoryRenamesCoalesceUntilRequestIsTaken() async throws {
        let database = try LibraryDatabase.openInMemory()
        let engine = await MainActor.run {
            OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }), seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")))
        }
        let coordinator = FilesystemSyncCoordinator(operationEngine: engine, database: database)
        let renamed = FSEventsObservation(path: "/nonexistent-fixture", isDirectory: true, wasRenamed: true)
        try await coordinator.handleBatch(.init(observations: [renamed, renamed], highestEventID: 1))
        try await coordinator.handleBatch(.init(observations: [renamed], highestEventID: 2))
        let requested = await coordinator.takeReconciliationRequest()
        let repeated = await coordinator.takeReconciliationRequest()
        XCTAssertTrue(requested)
        XCTAssertFalse(repeated)
        let count = try await database.writer.read { try EventRecord.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }

    func testStaleLocationObservationRejectsWithoutChangingIdentity() async throws {
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { connection in
            var file = FileRecord(id: 51, path: "/old.mp3", volumeUuid: "original", inode: 7, fileSize: 1, mtime: 1)
            file.membershipRevision = 3
            try file.insert(connection)
        }
        let engine = await MainActor.run {
            OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }), seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")))
        }
        do {
            _ = try await engine.apply(.observeFileLocation(.init(fileId: 51, expectedRevision: 2, path: "/new.mp3", volumeUuid: "new", inode: 8)))
            XCTFail("Stale observation must fail")
        } catch {
            XCTAssertEqual(error as? FileLibraryStateMutationError, .staleRevision(fileId: 51, expected: 2, actual: 3))
        }
        try await database.writer.read { connection in
            XCTAssertEqual(try FileRecord.fetchOne(connection, key: 51)?.path, "/old.mp3")
            XCTAssertEqual(try EventRecord.fetchCount(connection), 0)
        }
    }
}
