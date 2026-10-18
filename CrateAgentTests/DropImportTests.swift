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

        // A file dropped alongside its own folder is imported once.
        let result = await ImportCoordinator(operationEngine: engine, database: fixture.database).importDroppedItems([drop, URL(fileURLWithPath: paths[0])])

        XCTAssertEqual(result.filesImported, 3)
        XCTAssertEqual(result.filesSkipped, 0)
        XCTAssertEqual(result.filesPendingSync, 0)
        XCTAssertEqual(rewrites.value, 1, "Each dropped file rewrote database V2 on its own")
        let registered = try Set(readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).map { record in SeratoPath.normalized(record.path) })
        XCTAssertEqual(registered, Set(paths))
        let memberships = try await fixture.database.writer.read { database in try FileRecord.fetchAll(database).map(\.libraryMembership) }
        XCTAssertEqual(memberships, [.active, .active, .active])
        let remaining = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(remaining, 0)
        let imports = try await fixture.database.writer.read { database in
            try EventRecord.filter(Column("event_type") == EventType.trackAddedToSerato.rawValue).fetchCount(database)
        }
        XCTAssertEqual(imports, 3, "A file was journaled for import twice")
    }

    func testAFileChangedDuringTheDropIsReportedAndCanBeDroppedAgain() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        try fixture.save(paths: [])
        let drop = fixture.directory.appendingPathComponent("drop")
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        let audio = drop.appendingPathComponent("changing.wav")
        try FinalRemovalIntegrationTests.wav().write(to: audio)
        let changed = LockedChange()
        let replacement = FinalRemovalIntegrationTests.wav(sample: 9, durationSeconds: 2)
        try await fixture.database.writer.write { connection in
            connection.trace { event in
                guard event.expandedDescription.contains("INTO serato_write_queue"), changed.setOnce() else { return }
                do { try replacement.write(to: audio) }
                catch { XCTFail("Could not change the dropped file: \(error)") }
            }
        }
        let importer = ImportCoordinator(operationEngine: fixture.engine, database: fixture.database)

        let first = await importer.importDroppedItems([drop])
        try await fixture.database.writer.write { connection in connection.trace(nil) }

        XCTAssertEqual(first.filesImported, 0, "A file whose add was superseded was reported as imported")
        XCTAssertEqual(first.syncFailures, [], "A superseded add has nothing for Retry Sync to finish")
        XCTAssertEqual(first.filesNotAdded.count, 1)
        let second = await importer.importDroppedItems([drop])
        XCTAssertEqual(second.filesImported, 1, "The changed file could not be dropped again")
        let registered = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).map { record in SeratoPath.normalized(record.path) }
        XCTAssertEqual(registered, [audio.path])
        let membership = try await fixture.database.writer.read { database in try FileRecord.fetchAll(database).map(\.libraryMembership) }
        XCTAssertEqual(membership, [.active])
    }

    func testADropThatCannotTellWhichIndexedFileItIsReportsWhy() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        try fixture.save(paths: [])
        let composed = "Café.wav".precomposedStringWithCanonicalMapping
        let first = try await fixture.add(composed, membership: .pendingImport, bytes: FinalRemovalIntegrationTests.wav())
        // The same file indexed again under its path's other Unicode form.
        try await fixture.database.writer.write { database in
            var twin = first
            twin.id = nil
            let decomposed = first.path.decomposedStringWithCanonicalMapping
            twin.path = decomposed == first.path ? first.path.precomposedStringWithCanonicalMapping : decomposed
            try twin.insert(database)
        }

        let result = await ImportCoordinator(operationEngine: fixture.engine, database: fixture.database)
            .importDroppedItems([URL(fileURLWithPath: first.path)])

        XCTAssertEqual(result.filesSkipped, 0)
        XCTAssertEqual(result.blockedFiles, ["\(composed): \(SeratoReconciliationError.ambiguousIdentity(SeratoPath.normalized(first.path)).localizedDescription)"])
    }
}

extension DropImportTests {
    func testOverlappingDropsImportEachFileOnce() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let drop = fixture.directory.appendingPathComponent("drop")
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
        for index in 0 ..< 3 {
            try FinalRemovalIntegrationTests.wav(sample: UInt8(index + 1)).write(to: drop.appendingPathComponent("overlap-\(index).wav"))
        }
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        let importer = ImportCoordinator(operationEngine: fixture.engine, database: fixture.database)

        async let first = importer.importDroppedItems([drop])
        async let second = importer.importDroppedItems([drop])
        let results = await [first, second]

        XCTAssertEqual(results.map(\.filesImported).sorted(), [0, 3])
        XCTAssertEqual(results.map(\.filesAlreadyImporting.count).sorted(), [0, 3])
        let requests = try await fixture.database.writer.read { database in
            try EventRecord.filter(Column("event_type") == EventType.fileImportRequested.rawValue).fetchCount(database)
        }
        XCTAssertEqual(requests, 3, "A second drop restarted an import the first was still running")
    }
}

private final class LockedChange: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func setOnce() -> Bool {
        lock.withLock {
            guard !stored else { return false }
            stored = true
            return true
        }
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
