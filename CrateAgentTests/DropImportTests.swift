@testable import CrateAgent
import GRDB
import XCTest

@MainActor
final class DropImportTests: XCTestCase {
    func testADropRegistersEveryFileWithSeratoInOneLibraryWrite() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        try fixture.save(paths: [])
        let rewrites = LockedTestCounter()
        let engine = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                                     seratoAddTrackBatchWriter: { databasePath, additions in
                                         rewrites.increment()
                                         return try batchAddTracksToDatabase(databasePath: databasePath, additions: additions)
                                     })
        let drop = fixture.directory.appendingPathComponent("drop")
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        let paths = try (0 ..< 3).map { index in
            let url = drop.appendingPathComponent("dropped-\(index).wav")
            try FinalRemovalIntegrationTests.wav(sample: UInt8(index + 1)).write(to: url)
            return url.path
        }

        let result = await ImportCoordinator(operationEngine: engine, database: fixture.database).importDroppedItems([drop])

        XCTAssertEqual(result.filesImported, 3)
        XCTAssertEqual(result.filesPendingSync, 0)
        XCTAssertEqual(rewrites.value, 1, "Each dropped file rewrote database V2 on its own")
        let registered = try Set(readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).map { record in SeratoPath.normalized(record.path) })
        XCTAssertEqual(registered, Set(paths))
        let memberships = try await fixture.database.writer.read { database in try FileRecord.fetchAll(database).map(\.libraryMembership) }
        XCTAssertEqual(memberships, [.active, .active, .active])
        let remaining = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(remaining, 0)
    }
}

private final class LockedTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.withLock { stored }
    }

    func increment() {
        lock.withLock { stored += 1 }
    }
}
