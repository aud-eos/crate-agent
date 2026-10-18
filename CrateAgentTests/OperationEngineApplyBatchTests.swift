@testable import CrateAgent
import GRDB
import XCTest

final class OperationEngineApplyBatchTests: XCTestCase {
    @MainActor
    func testConflictGuardsEveryMutationEntryAndLeavesRowsAndEventsUntouched() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let protected = try await fixture.add("Café.mp3")
        let independent = try await fixture.add("independent.mp3")
        let protectedID = try XCTUnwrap(protected.id)
        let independentID = try XCTUnwrap(independent.id)
        try fixture.save(paths: [protected.path, protected.path.decomposedStringWithCanonicalMapping])
        let snapshot = try await fixture.reader.read()
        let analysis = try await SeratoConflictAnalyzer().analyze(snapshot: snapshot, files: [protected, independent])
        let authorization = gate.prepareDrain()
        try gate.install(analysis.scope, for: authorization)
        try gate.markReady(authorization)
        let mutations: [TrackMutation] = [
            .indexNewFile(.init(path: protected.path, volumeUuid: protected.volumeUuid, inode: protected.inode, fileSize: protected.fileSize, mtime: protected.mtime)),
            .beginFileImport(.init(fileId: protectedID, expectedRevision: 0, identity: protected.identity)),
            .observeFileLocation(.init(fileId: protectedID, expectedRevision: 0, path: protected.path, volumeUuid: protected.volumeUuid, inode: protected.inode)),
            .observeFileIdentity(.init(fileId: protectedID, expectedRevision: 0, previousIdentity: protected.identity, identity: protected.identity)),
            .setFileLibraryState(.init(fileId: protectedID, expectedRevision: 0, state: protected.libraryState)),
            .setMetadata(.init(fileId: protectedID, metadata: .init(artist: "Changed"))),
            .setMetadata(.init(fileId: protectedID, metadata: .init(artist: "Changed"), isSeratoAuthoritative: true)),
            .commitMetadataToSerato(.init(fileId: protectedID, metadata: .init(artist: "Changed"))),
            .addTrackToSerato(.init(fileId: protectedID, metadata: .empty)),
            .writeFileTags(.init(fileId: protectedID, metadata: .empty)),
            .trashFile(.init(fileId: protectedID)),
            .removeTrackFromSerato(.init(fileId: protectedID)),
            .removeFileFromCrates(.init(fileId: protectedID)),
            .removeFile(.init(fileId: protectedID)),
            .renameFile(.init(fileId: independentID, newPath: protected.path, previousPath: independent.path, physicalMove: true)),
        ]
        let originalV2 = try Data(contentsOf: fixture.locator.databaseV2Url)
        for mutation in mutations {
            do { try await fixture.engine.apply(mutation); XCTFail("Conflict mutation was authorized: \(mutation)") }
            catch is SeratoPathConflictError {}
        }
        let snapshotAuthorization = try await fixture.reader.authorization(for: snapshot)
        do {
            try await fixture.engine.applyObservedBatch([mutations[3]], authorization: snapshotAuthorization)
            XCTFail("Snapshot observations bypassed conflict protection")
        } catch is SeratoPathConflictError {}
        do {
            try await fixture.engine.applyFilesystemObservations([mutations[2]], batchId: "blocked-observation")
            XCTFail("Filesystem observation bypassed conflict protection")
        } catch is SeratoPathConflictError {}
        do {
            try await fixture.engine.applyBatch([.setMetadata(.init(fileId: independentID, metadata: .init(title: "Rollback"))), mutations[5]], batchId: "atomic-conflict")
            XCTFail("Batch containing a conflict committed")
        } catch is SeratoPathConflictError {}
        do {
            _ = try await fixture.engine.resolveDuplicate(target: independent, keeper: protected, batchID: "blocked-keeper", requirement: .identicalContent)
            XCTFail("Protected keeper authorized duplicate cleanup")
        } catch is SeratoPathConflictError {}
        let protectedAfter = try await fixture.row(protected)
        let independentAfter = try await fixture.row(independent)
        let events = try await fixture.events()
        XCTAssertEqual(protectedAfter, protected)
        XCTAssertEqual(independentAfter, independent)
        XCTAssertEqual(events, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), originalV2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: independent.path))
    }

    @MainActor
    func testUndoAndHistoricalReplayProtectTheOriginalRenamePath() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let original = try await fixture.add("original.mp3")
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: original.path)])
        try gate.markReady(gate.prepareDrain())
        let destination = fixture.directory.appendingPathComponent("renamed.mp3").path
        try await fixture.engine.apply(.renameFile(.init(fileId: XCTUnwrap(original.id), newPath: destination, previousPath: original.path, physicalMove: true)), batchId: "rename-history")
        let renamed = try await fixture.row(original)
        var scope = SeratoConflictScope()
        scope.protect(SeratoConflictTarget(paths: [original.path]), group: original.path)
        gate.invalidate()
        let authorization = gate.prepareDrain()
        try gate.install(scope, for: authorization)
        try gate.markReady(authorization)
        do { _ = try await fixture.engine.undoBatch("rename-history"); XCTFail("Undo wrote to a protected destination") }
        catch is SeratoPathConflictError {}
        let replay = try await fixture.engine.resyncSeratoForBatch("rename-history")
        XCTAssertEqual(replay.appliedCount, 0)
        XCTAssertEqual(replay.conflictBlockedCount, 1)
        let after = try await fixture.row(original)
        XCTAssertEqual(after, renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination))
    }

    @MainActor
    func testConflictInstalledInsideDatabaseCommitRollsBackMutation() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("late-conflict.mp3")
        var preparedScope = SeratoConflictScope()
        preparedScope.protect(.file(file), group: file.path)
        let scope = preparedScope
        try gate.markReady(gate.prepareDrain())
        try await fixture.database.writer.write { database in
            database.trace { event in
                if event.description.contains("UPDATE \"files\"") || event.description.contains("UPDATE files") {
                    gate.invalidate()
                    do { try gate.install(scope, for: gate.prepareDrain()) }
                    catch { XCTFail("Cannot install controlled conflict: \(error)") }
                }
            }
        }
        do { try await fixture.engine.apply(.setMetadata(.init(fileId: XCTUnwrap(file.id), metadata: .init(artist: "Rejected")))); XCTFail("Late exclusion committed") }
        catch is LibrarySyncReadinessError {} catch is SeratoPathConflictError {}
        let after = try await fixture.row(file)
        let events = try await fixture.events()
        XCTAssertEqual(after, file)
        XCTAssertEqual(events, 0)
    }

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
            fileTrasher: { path in path /* synthetic paths */ }
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
                    .removeFile(RemoveFilePayload(fileId: 9999)),
                ],
                batchId: "atomic-batch"
            )
            XCTFail("Expected fileNotFound to bubble up from the second mutation")
        } catch let error as OperationEngineError {
            XCTAssertEqual(error, .fileNotFound(fileId: 9999))
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

        try await markProcessingFixturesAvailable(in: database)
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

        let queueDepthBefore = try await engine.pendingSeratoWriteCount

        try await engine.applyBatch(
            [
                .renameFile(RenameFilePayload(fileId: idA, newPath: "/Music/A/a-new.mp3")),
                .renameFile(RenameFilePayload(fileId: idB, newPath: "/Music/A/b-new.mp3")),
            ],
            batchId: "rename-batch"
        )

        let queueDepthAfter = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(
            queueDepthAfter - queueDepthBefore,
            2,
            "Both renames should land in the pending Serato queue under one Watchdog check"
        )
    }
}
