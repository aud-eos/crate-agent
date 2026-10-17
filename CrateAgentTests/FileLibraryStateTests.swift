@testable import CrateAgent
import GRDB
import XCTest

final class FileLibraryStateTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (LibraryDatabase, OperationEngine) {
        let database = try LibraryDatabase.openInMemory()
        try database.writer.write { connection in
            var track = TrackRecord(id: 41, fingerprintHash: Data([1, 2]))
            try track.insert(connection)
            for fileId: Int64 in [51, 52] {
                var file = FileRecord(id: fileId, path: "/synthetic/\(fileId).mp3", volumeUuid: "volume", inode: fileId, fileSize: 3, mtime: 4, chromaprintFingerprint: Data([3, 4]), trackId: 41)
                try file.insert(connection)
            }
        }
        let engine = OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }), seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")))
        return (database, engine)
    }

    private let retired = FileLibraryState(membership: .retired, availability: .missing, libraryID: "library", retiredAt: 123)

    func testRetirementPreservesSharedIdentityAndAuditsBothStates() async throws {
        let (database, engine) = try await MainActor.run { try fixture() }
        try await database.writer.write { connection in
            var history = EventRecord(batchId: "prior", timestamp: 1, fileId: 51, trackId: 41, eventType: .trackImported, payloadJson: "{}", inversePayloadJson: "{}")
            try history.insert(connection)
        }
        let before = try await database.writer.read { try XCTUnwrap(FileRecord.fetchOne($0, key: 51)) }
        let eventId = try await engine.apply(.setFileLibraryState(.init(fileId: 51, expectedRevision: 0, state: retired)), batchId: "observe")
        XCTAssertNotNil(eventId)
        try await database.writer.read { connection in
            let after = try XCTUnwrap(FileRecord.fetchOne(connection, key: 51))
            XCTAssertEqual(after.id, before.id)
            XCTAssertEqual(after.trackId, before.trackId)
            XCTAssertEqual(after.chromaprintFingerprint, before.chromaprintFingerprint)
            XCTAssertEqual(after.libraryMembership, .retired)
            XCTAssertEqual(after.libraryState, self.retired)
            XCTAssertEqual(after.membershipRevision, 1)
            let history = try XCTUnwrap(EventRecord.filter(Column("batch_id") == "prior").fetchOne(connection))
            XCTAssertEqual(history.fileId, 51)
            XCTAssertEqual(history.trackId, 41)
            XCTAssertEqual(try FileRecord.fetchOne(connection, key: 52)?.libraryMembership, .legacyUnverified)
            XCTAssertEqual(try TrackRecord.fetchCount(connection), 1)
            let event = try XCTUnwrap(EventRecord.fetchOne(connection, key: eventId))
            XCTAssertEqual(event.fileId, 51)
            XCTAssertEqual(event.trackId, 41)
            let forward = try JSONDecoder().decode(SetFileLibraryStatePayload.self, from: Data(event.payloadJson.utf8))
            let inverse = try JSONDecoder().decode(SetFileLibraryStatePayload.self, from: Data(event.inversePayloadJson.utf8))
            XCTAssertEqual(forward.state, self.retired)
            XCTAssertEqual(inverse.state, before.libraryState)
            XCTAssertEqual(inverse.expectedRevision, 1)
        }
    }

    func testIdenticalObservationReturnsNilAndAvailabilityDoesNotAdvanceRevision() async throws {
        let (database, engine) = try await MainActor.run { try fixture() }
        _ = try await engine.apply(.setFileLibraryState(.init(fileId: 51, expectedRevision: 0, state: retired)))
        let repeated = try await engine.apply(.setFileLibraryState(.init(fileId: 51, expectedRevision: 1, state: retired)))
        XCTAssertNil(repeated)
        let available = FileLibraryState(membership: .retired, availability: .available, libraryID: "library", retiredAt: 123)
        _ = try await engine.apply(.setFileLibraryState(.init(fileId: 51, expectedRevision: 1, state: available)))
        try await database.writer.read { connection in
            XCTAssertEqual(try EventRecord.fetchCount(connection), 2)
            XCTAssertEqual(try FileRecord.fetchOne(connection, key: 51)?.membershipRevision, 1)
        }
    }

    func testStaleRevisionRollsBackWholeBatch() async throws {
        let (database, engine) = try await MainActor.run { try fixture() }
        do {
            _ = try await engine.applyBatch([
                .setFileLibraryState(.init(fileId: 52, expectedRevision: 0, state: retired)),
                .setFileLibraryState(.init(fileId: 51, expectedRevision: 7, state: retired)),
            ], batchId: "stale")
            XCTFail("Stale mutation must reject")
        } catch {
            XCTAssertEqual(error as? FileLibraryStateMutationError, .staleRevision(fileId: 51, expected: 7, actual: 0))
        }
        try await database.writer.read { connection in
            XCTAssertEqual(try EventRecord.fetchCount(connection), 0)
            XCTAssertEqual(try FileRecord.fetchOne(connection, key: 52)?.libraryMembership, .legacyUnverified)
        }
    }

    func testObservationAndMixedBatchesCannotUndo() async throws {
        let (database, engine) = try await MainActor.run { try fixture() }
        _ = try await engine.apply(.setFileLibraryState(.init(fileId: 51, expectedRevision: 0, state: retired)), batchId: "mixed")
        _ = try await engine.apply(.removeFile(.init(fileId: 52)), batchId: "mixed")
        let summary = try await EventHistoryQuery.loadRecentBatches(database: database)
        XCTAssertFalse(try XCTUnwrap(summary.first).canUndo)
        XCTAssertFalse(try XCTUnwrap(summary.first).canResync)
        do {
            _ = try await engine.undoBatch("mixed")
            XCTFail("Observations must reject before any inverse")
        } catch {
            XCTAssertEqual(error as? OperationEngineError, .undoNotSupported(eventType: .fileLibraryStateChanged))
        }
        try await database.writer.read { connection in
            XCTAssertNil(try FileRecord.fetchOne(connection, key: 52))
            XCTAssertEqual(try FileRecord.fetchOne(connection, key: 51)?.libraryMembership, .retired)
            XCTAssertEqual(try EventRecord.fetchCount(connection), 2)
        }
    }

    func testInverseStateApplicationAdvancesRevisionAndRejectsReuse() async throws {
        let (database, engine) = try await MainActor.run { try fixture() }
        let eventId = try await engine.apply(.setFileLibraryState(.init(fileId: 51, expectedRevision: 0, state: retired)))
        let inverse = try await database.writer.read { connection in
            let event = try XCTUnwrap(EventRecord.fetchOne(connection, key: eventId))
            return try JSONDecoder().decode(SetFileLibraryStatePayload.self, from: Data(event.inversePayloadJson.utf8))
        }
        _ = try await engine.apply(.setFileLibraryState(inverse))
        do {
            _ = try await engine.apply(.setFileLibraryState(inverse))
            XCTFail("An old revision cannot be reused, even for identical state")
        } catch {
            XCTAssertEqual(error as? FileLibraryStateMutationError, .staleRevision(fileId: 51, expected: 1, actual: 2))
        }
        try await database.writer.read { connection in
            let file = try XCTUnwrap(FileRecord.fetchOne(connection, key: 51))
            XCTAssertEqual(file.membershipRevision, 2)
            XCTAssertEqual(file.libraryMembership, .legacyUnverified)
            XCTAssertEqual(try EventRecord.fetchCount(connection), 2)
        }
    }

    func testBatchReturnsOnlyRealEventsAndObservationsHaveNoReplay() async throws {
        let (database, engine) = try await MainActor.run { try fixture() }
        let eventIds = try await engine.applyBatch([
            .setFileLibraryState(.init(fileId: 51, expectedRevision: 0, state: retired)),
            .setFileLibraryState(.init(fileId: 51, expectedRevision: 1, state: retired)),
            .setFileLibraryState(.init(fileId: 52, expectedRevision: 0, state: retired)),
        ], batchId: "observations")
        XCTAssertEqual(eventIds.count, 2)
        let storedIds = try await database.writer.read { connection in
            try EventRecord.order(Column("event_id")).fetchAll(connection).compactMap(\.eventId)
        }
        XCTAssertEqual(eventIds, storedIds)
        let summaries = try await EventHistoryQuery.loadRecentBatches(database: database)
        XCTAssertFalse(try XCTUnwrap(summaries.first).canUndo)
        XCTAssertFalse(try XCTUnwrap(summaries.first).canResync)
        let replay = try await engine.resyncSeratoForBatch("observations")
        XCTAssertEqual(replay.totalCount, 0)
        let pendingCount = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(pendingCount, 0)
    }

    func testMigrationPreservesIdentityAndHistory() throws {
        let queue = try DatabaseQueue()
        let migrator = LibraryDatabase.makeMigrator()
        try migrator.migrate(queue, upTo: "009_add_fingerprint_freshness_basis")
        try queue.write { database in
            try database.execute(sql: "INSERT INTO tracks (id, fingerprint_hash) VALUES (41, X'0102')")
            try database.execute(sql: "INSERT INTO files (id, path, volume_uuid, inode, file_size, mtime, chromaprint_fingerprint, track_id) VALUES (51, '/absent.mp3', 'volume', 1, 2, 3, X'0304', 41)")
            try database.execute(sql: "INSERT INTO events (event_id, batch_id, timestamp, file_id, track_id, event_type, payload_json, inverse_payload_json) VALUES (61, 'old', 1, 51, 41, 'track_imported', '{}', '{}')")
        }
        try migrator.migrate(queue)
        try queue.read { database in
            let file = try XCTUnwrap(FileRecord.fetchOne(database, key: 51))
            XCTAssertEqual(file.trackId, 41)
            XCTAssertEqual(file.chromaprintFingerprint, Data([3, 4]))
            let columns = try XCTUnwrap(Row.fetchOne(database, sql: "SELECT * FROM files WHERE id = 51"))
            XCTAssertEqual(columns["library_membership"] as String?, "legacyUnverified")
            XCTAssertEqual(columns["file_availability"] as String?, "unknown")
            XCTAssertEqual(columns["membership_revision"] as Int64?, 0)
            XCTAssertEqual(try TrackRecord.fetchOne(database, key: 41)?.fingerprintHash, Data([1, 2]))
            let event = try XCTUnwrap(EventRecord.fetchOne(database, key: 61))
            XCTAssertEqual(event.fileId, 51)
            XCTAssertEqual(event.trackId, 41)
            XCTAssertEqual(event.payloadJson, "{}")
            XCTAssertEqual(event.inversePayloadJson, "{}")
        }
    }
}
