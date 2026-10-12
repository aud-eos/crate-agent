@testable import CrateAgent
import GRDB
import XCTest

final class SyncCheckpointStoreTests: XCTestCase {
    @MainActor
    func testFailedImportEffectKeepsFenceUntilSuccessfulRetry() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("pending.wav", membership: .pendingImport)
        let store = SyncCheckpointStore(database: fixture.database)
        try gate.markReady(gate.prepareDrain())
        try Data("invalid".utf8).write(to: fixture.locator.databaseV2Url)
        do {
            try await fixture.engine.apply(.addTrackToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .empty)), batchId: "failed-import")
            XCTFail("Invalid V2 accepted import")
        } catch is OperationEngineError {}
        let retained = try await store.pendingEffects()
        XCTAssertFalse(retained.isEmpty)
        try fixture.save(paths: [])
        try await fixture.engine.drainPendingSeratoUpdates()
        let completed = try await store.pendingEffects()
        XCTAssertEqual(completed, [])
    }

    func testDatabaseChangesInvalidateDurablyButRollbackAndFingerprintProgressDoNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot clean checkpoint fixture: \(error)") }
        }
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase.openWAL(at: databaseURL)
        let store = SyncCheckpointStore(database: database)
        let fileID = try await database.writer.write { connection in
            var file = FileRecord(path: "/fixture/original.wav", volumeUuid: "fixture", inode: 1, fileSize: 64, mtime: 1)
            file.libraryMembership = .active
            file.fileAvailability = .available
            try file.insert(connection)
            return try XCTUnwrap(file.id)
        }
        let initial = try await store.currentRevision()
        try await database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET title = 'New title' WHERE id = ?", arguments: [fileID])
        }
        let changed = try await store.currentRevision()
        XCTAssertGreaterThan(changed, initial)
        enum Expected: Error { case rollback }
        do {
            try await database.writer.write { connection in
                try connection.execute(sql: "UPDATE files SET path = '/fixture/rolled-back.wav' WHERE id = ?", arguments: [fileID])
                throw Expected.rollback
            }
        } catch Expected.rollback {}
        try await database.writer.write { connection in
            _ = try FingerprintPersistence.write(fileID: fileID, fingerprint: Data([1, 2, 3]), status: .done, in: connection)
        }
        let retained = try await store.currentRevision()
        XCTAssertEqual(retained, changed)
        let reopened = try SyncCheckpointStore(database: LibraryDatabase.openWAL(at: databaseURL))
        let durable = try await reopened.currentRevision()
        XCTAssertEqual(durable, changed)
        let dirty = try await reopened.dirtyFiles()
        XCTAssertTrue(dirty.fileIDs.contains(fileID))
        XCTAssertTrue(dirty.paths.contains(Data("/fixture/original.wav".utf8)))
        XCTAssertFalse(dirty.paths.contains(Data("/fixture/rolled-back.wav".utf8)))
    }

    func testPublicationRejectsStaleRevisionAndDurableUnacknowledgedEffects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot clean checkpoint fixture: \(error)") }
        }
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let sourceURL = directory.appendingPathComponent("database V2")
        try SeratoTestEncoding.library(paths: []).write(to: sourceURL)
        let database = try LibraryDatabase.openWAL(at: databaseURL)
        let store = SyncCheckpointStore(database: database)
        let revision = try await store.currentRevision()
        let header = try SyncCheckpointHeader(libraryID: "fixture", source: SeratoSourceIdentity.read(sourceURL), localRevision: revision,
                                              watchRoots: [directory.path], eventID: 42, hadConflicts: false)
        let checkpoint = LibrarySyncCheckpoint(header: header, records: [], files: [])
        try await store.publish(checkpoint, expectedRevision: revision)
        let saved = try await store.load()
        XCTAssertEqual(saved?.header, header)
        try await store.beginEffect(batchID: "external-write")
        try Data([7]).write(to: directory.appendingPathComponent("external-effect"))
        let reopened = try SyncCheckpointStore(database: LibraryDatabase.openWAL(at: databaseURL))
        let unresolved = try await reopened.pendingEffects()
        XCTAssertEqual(unresolved, ["external-write"])
        do { try await reopened.publish(checkpoint, expectedRevision: revision); XCTFail("Unacknowledged I/O produced a completed checkpoint") }
        catch SyncCheckpointError.incompleteEffects {}
        try await reopened.finishEffect(batchID: "external-write")
        try await database.writer.write { connection in
            var file = FileRecord(path: "/late.wav", volumeUuid: "fixture", inode: 1, fileSize: 1, mtime: 1)
            try file.insert(connection)
        }
        do { try await store.publish(checkpoint, expectedRevision: revision); XCTFail("Stale evidence was published") }
        catch SyncCheckpointError.changed {}
    }

    func testRawOccurrencesRoundTripAndCorruptCheckpointSurfaces() async throws {
        let database = try LibraryDatabase.openInMemory()
        let store = SyncCheckpointStore(database: database)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot clean checkpoint fixture: \(error)") }
        }
        let source = directory.appendingPathComponent("database V2")
        try SeratoTestEncoding.library(paths: []).write(to: source)
        let revision = try await store.currentRevision()
        let paths = ["/Caf\u{00e9}.wav", "/Cafe\u{0301}.wav", "/Caf\u{00e9}.wav"]
        let records = paths.enumerated().map { index, path in
            SavedSeratoOccurrence(pathBytes: Data(path.utf8), metadata: .init(artist: "Artist \(index)"))
        }
        let header = try SyncCheckpointHeader(libraryID: "fixture", source: SeratoSourceIdentity.read(source), localRevision: revision,
                                              watchRoots: [], eventID: 0, hadConflicts: true)
        try await store.publish(.init(header: header, records: records, files: []), expectedRevision: revision)
        let loaded = try await store.load()
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.records.map(\.pathBytes), paths.map { path in Data(path.utf8) })
        XCTAssertEqual(restored.records.map(\.metadata.artist), ["Artist 0", "Artist 1", "Artist 2"])
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(header)) as? [String: Any])
        var sourceObject = try XCTUnwrap(encoded["source"] as? [String: Any])
        sourceObject["unrecognizedEvidence"] = true
        encoded["source"] = sourceObject
        let invalidEvidence = try JSONSerialization.data(withJSONObject: encoded)
        try await database.writer.write { connection in
            try connection.execute(sql: "UPDATE sync_checkpoint SET payload = ?", arguments: [invalidEvidence])
        }
        do { _ = try await store.load(); XCTFail("Unknown nested evidence was accepted") } catch SyncCheckpointError.malformed {}
        try await database.writer.write { connection in
            try connection.execute(sql: "UPDATE sync_checkpoint SET payload = ?", arguments: [Data("invalid".utf8)])
        }
        do { _ = try await store.load(); XCTFail("Corrupt cache was accepted") } catch is DecodingError {}
    }
}
