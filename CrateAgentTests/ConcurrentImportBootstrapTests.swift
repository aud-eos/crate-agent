@testable import CrateAgent
import GRDB
import XCTest

final class ConcurrentImportBootstrapTests: XCTestCase {
    @MainActor
    func testConcurrentPendingImportsBothSurviveInitiallyAbsentDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try BootstrapSchedulingWriter(DatabasePool(path: root.appendingPathComponent("sidecar.sqlite").path))
        let database = try LibraryDatabase(writer: writer)
        let audioURLs = [root.appendingPathComponent("first.mp3"), root.appendingPathComponent("second.mp3")]
        for audio in audioURLs {
            try Data(audio.lastPathComponent.utf8).write(to: audio)
        }
        let fileIDs = try await database.writer.write { connection in
            try audioURLs.map { audio in
                let identity = try FileMetadataCollector.collectVerified(at: audio.path)
                var file = FileRecord(path: audio.path, volumeUuid: identity.volumeUuid, inode: identity.inode,
                                      fileSize: identity.fileSize, mtime: identity.mtime, lightweightHash: identity.lightweightHash)
                file.libraryMembership = .pendingImport
                file.fileAvailability = .available
                file.membershipRevision = 1
                try file.insert(connection)
                return try XCTUnwrap(file.id)
            }
        }
        let seratoDirectory = root.appendingPathComponent("_Serato_")
        let v2URL = seratoDirectory.appendingPathComponent("database V2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: v2URL.path))
        let engine = OperationEngine(database: database,
                                     seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }),
                                     seratoLocator: SeratoLibraryLocator(seratoDirectory: seratoDirectory))
        writer.arm()
        async let first = engine.apply(.addTrackToSerato(AddTrackToSeratoPayload(fileId: fileIDs[0], metadata: SeratoMetadata(title: "first"))))
        async let second = engine.apply(.addTrackToSerato(AddTrackToSeratoPayload(fileId: fileIDs[1], metadata: SeratoMetadata(title: "second"))))
        _ = try await (first, second)
        XCTAssertEqual(writer.submittedWrites, 6, "Two event transactions, two external writes, and two confirmations")
        let records = try readDatabaseRecords(databasePath: v2URL.path)
        XCTAssertEqual(Set(records.map(\.path)), Set(audioURLs.map { audio in SeratoLibraryLocator.seratoRelativePath(fromAbsolute: audio.path) }))
        try await database.writer.read { connection in
            let files = try FileRecord.order(Column("id")).fetchAll(connection)
            XCTAssertEqual(files.map(\.libraryMembership), [.active, .active])
            XCTAssertEqual(files.map(\.membershipRevision), [2, 2])
            XCTAssertEqual(try EventRecord.filter(Column("event_type") == EventType.trackAddedToSerato.rawValue).fetchCount(connection), 2)
            XCTAssertEqual(try EventRecord.filter(Column("event_type") == EventType.fileLibraryStateChanged.rawValue).fetchCount(connection), 2)
        }
    }
}

/// Delegates all database work to a real pool while controlling writer submission order.
private final class BootstrapSchedulingWriter: DatabaseWriter, @unchecked Sendable {
    private let base: any DatabaseWriter
    private let lock = NSLock()
    private var armed = false
    private var submissionCount = 0
    private let secondEventSubmitted = DispatchSemaphore(value: 0)
    private let secondExternalWriteSubmitted = DispatchSemaphore(value: 0)

    init(_ base: any DatabaseWriter) {
        self.base = base
    }

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    var submittedWrites: Int {
        lock.lock()
        defer { lock.unlock() }
        return submissionCount
    }

    func asyncWriteWithoutTransaction(_ updates: @escaping (Database) -> Void) {
        lock.lock()
        if armed {
            submissionCount += 1
        }
        let ordinal = armed ? submissionCount : 0
        lock.unlock()
        base.asyncWriteWithoutTransaction { [self] connection in
            if ordinal == 1 {
                XCTAssertEqual(secondEventSubmitted.wait(timeout: .now() + 10), .success)
            }
            if ordinal == 3 {
                XCTAssertEqual(secondExternalWriteSubmitted.wait(timeout: .now() + 10), .success)
            }
            updates(connection)
        }
        if ordinal == 2 {
            secondEventSubmitted.signal()
        }
        if ordinal == 4 {
            secondExternalWriteSubmitted.signal()
        }
    }

    var configuration: Configuration {
        base.configuration
    }

    var path: String {
        base.path
    }

    func close() throws {
        try base.close()
    }

    func interrupt() {
        base.interrupt()
    }

    func read<Value>(_ value: (Database) throws -> Value) throws -> Value {
        try base.read(value)
    }

    func asyncRead(_ value: @escaping (Result<Database, Error>) -> Void) {
        base.asyncRead(value)
    }

    func unsafeRead<Value>(_ value: (Database) throws -> Value) throws -> Value {
        try base.unsafeRead(value)
    }

    func asyncUnsafeRead(_ value: @escaping (Result<Database, Error>) -> Void) {
        base.asyncUnsafeRead(value)
    }

    func unsafeReentrantRead<Value>(_ value: (Database) throws -> Value) throws -> Value {
        try base.unsafeReentrantRead(value)
    }

    func writeWithoutTransaction<Value>(_ updates: (Database) throws -> Value) rethrows -> Value {
        try base.writeWithoutTransaction(updates)
    }

    func barrierWriteWithoutTransaction<Value>(_ updates: (Database) throws -> Value) throws -> Value {
        try base.barrierWriteWithoutTransaction(updates)
    }

    func asyncBarrierWriteWithoutTransaction(_ updates: @escaping (Result<Database, Error>) -> Void) {
        base.asyncBarrierWriteWithoutTransaction(updates)
    }

    func unsafeReentrantWrite<Value>(_ updates: (Database) throws -> Value) rethrows -> Value {
        try base.unsafeReentrantWrite(updates)
    }

    func concurrentRead<Value>(_ value: @escaping (Database) throws -> Value) -> DatabaseFuture<Value> {
        base.concurrentRead(value)
    }

    func spawnConcurrentRead(_ value: @escaping (Result<Database, Error>) -> Void) {
        base.spawnConcurrentRead(value)
    }

    func _add<Reducer: ValueReducer>(observation: ValueObservation<Reducer>, scheduling scheduler: some ValueObservationScheduler,
                                     onChange: @escaping (Reducer.Value) -> Void) -> AnyDatabaseCancellable
    {
        base._add(observation: observation, scheduling: scheduler, onChange: onChange)
    }
}
