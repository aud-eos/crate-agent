import GRDB
import XCTest
@testable import CrateAgent

final class OperationEngineApplyBatchTests: XCTestCase {

    @MainActor
    private func makeEngine(
        seratoIsRunning: Bool = false
    ) throws -> (OperationEngine, LibraryDatabase) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(
            runningBundleIdentifiersProvider: {
                seratoIsRunning ? ["com.serato.djpro"] : []
            }
        )
        let locator = SeratoLibraryLocator(
            seratoDirectory: URL(fileURLWithPath: "/dev/null")
        )
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { _, _ in /* synthetic paths */ },
            fileTrasher: { _ in /* synthetic paths */ }
        )
        return (engine, database)
    }

    private func indexNewFile(
        _ path: String,
        inode: Int64 = 1
    ) -> TrackMutation {
        .indexNewFile(IndexNewFilePayload(
            path: path,
            volumeUuid: "v1",
            inode: inode,
            fileSize: 1,
            mtime: 1
        ))
    }

    func testReturnsEmptyArrayForEmptyInput() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        let eventIds = try await engine.applyBatch([], batchId: "noop-batch")
        XCTAssertTrue(eventIds.isEmpty)
        let eventCount = try await database.writer.read { try EventRecord.fetchCount($0) }
        XCTAssertEqual(eventCount, 0, "Empty applyBatch must not journal any events")
    }

    func testReturnsEventIdsInInputOrder() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        let eventIds = try await engine.applyBatch(
            [
                indexNewFile("/Music/A/a.mp3", inode: 1),
                indexNewFile("/Music/A/b.mp3", inode: 2),
                indexNewFile("/Music/A/c.mp3", inode: 3),
            ],
            batchId: "batch-order"
        )
        XCTAssertEqual(eventIds.count, 3)
        XCTAssertTrue(
            eventIds[0] < eventIds[1] && eventIds[1] < eventIds[2],
            "Event IDs should be monotonically increasing in input order; got \(eventIds)"
        )

        try await database.writer.read { connection in
            let events = try EventRecord
                .filter(Column("batch_id") == "batch-order")
                .order(Column("event_id").asc)
                .fetchAll(connection)
            XCTAssertEqual(events.map(\.eventId), eventIds)
        }
    }

    func testGroupsAllMutationsUnderSingleBatchId() async throws {
        let (engine, database) = try await MainActor.run { try makeEngine() }
        try await engine.applyBatch(
            [
                indexNewFile("/Music/A/one.mp3", inode: 1),
                indexNewFile("/Music/A/two.mp3", inode: 2),
            ],
            batchId: "shared-batch"
        )
        let count = try await database.writer.read { connection in
            try EventRecord
                .filter(Column("batch_id") == "shared-batch")
                .fetchCount(connection)
        }
        XCTAssertEqual(count, 2)
    }

    func testRollsBackAllMutationsWhenAnyFails() async throws {
        // The first mutation indexes a fresh file (must succeed).
        // The second references a non-existent fileId (must throw
        // fileNotFound). With per-mutation transactions, the first
        // would persist. With applyBatch's single transaction, the
        // failure rolls back the whole batch — files table stays
        // empty, events table stays empty.
        let (engine, database) = try await MainActor.run { try makeEngine() }
        do {
            _ = try await engine.applyBatch(
                [
                    indexNewFile("/Music/A/will-be-rolled-back.mp3"),
                    .removeFile(RemoveFilePayload(fileId: 9_999)),
                ],
                batchId: "atomic-batch"
            )
            XCTFail("Expected fileNotFound to bubble up from the second mutation")
        } catch let error as OperationEngineError {
            XCTAssertEqual(error, .fileNotFound(fileId: 9_999))
        }

        try await database.writer.read { connection in
            let fileCount = try FileRecord.fetchCount(connection)
            XCTAssertEqual(
                fileCount,
                0,
                "First mutation's file insert must be rolled back by the second's failure"
            )
            let eventCount = try EventRecord.fetchCount(connection)
            XCTAssertEqual(
                eventCount,
                0,
                "Neither event should be journaled if any mutation fails"
            )
        }
    }

    func testQueuesAllSeratoWritesAtOnceWhenSeratoIsRunning() async throws {
        // Two rename mutations under one applyBatch when Serato is
        // running should produce two queued Serato writes (one per
        // rename) and exactly one Watchdog check — the queue depth
        // grows by 2 with no intermediate apply attempts.
        let (engine, database) = try await MainActor.run {
            try makeEngine(seratoIsRunning: true)
        }
        try await engine.apply(indexNewFile("/Music/A/a.mp3", inode: 1))
        try await engine.apply(indexNewFile("/Music/A/b.mp3", inode: 2))

        let (idA, idB) = try await database.writer.read { connection in
            let rowA = try Int64.fetchOne(
                connection, sql: "SELECT id FROM files WHERE path = ?",
                arguments: ["/Music/A/a.mp3"]
            )!
            let rowB = try Int64.fetchOne(
                connection, sql: "SELECT id FROM files WHERE path = ?",
                arguments: ["/Music/A/b.mp3"]
            )!
            return (rowA, rowB)
        }

        let queueDepthBefore = await engine.pendingSeratoWriteCount

        try await engine.applyBatch(
            [
                .renameFile(RenameFilePayload(fileId: idA, newPath: "/Music/A/a-new.mp3")),
                .renameFile(RenameFilePayload(fileId: idB, newPath: "/Music/A/b-new.mp3")),
            ],
            batchId: "rename-batch"
        )

        let queueDepthAfter = await engine.pendingSeratoWriteCount
        XCTAssertEqual(
            queueDepthAfter - queueDepthBefore,
            2,
            "Both renames should land in the pending Serato queue under one Watchdog check"
        )
    }
}
