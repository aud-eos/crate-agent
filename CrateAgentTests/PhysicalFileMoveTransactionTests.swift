@testable import CrateAgent
import GRDB
import XCTest

final class PhysicalFileMoveTransactionTests: XCTestCase {
    private static let disposableVolume = URL(fileURLWithPath: "/private/tmp/crate-agent-task6-volume")

    func testCrossVolumeReplacedDestinationBeforeVerificationIsRetained() async throws {
        try await assertCrossVolumeReplacementRetained(replacementMatchesSource: false)
    }

    func testCrossVolumeSameContentReplacementIsStillUnowned() async throws {
        try await assertCrossVolumeReplacementRetained(replacementMatchesSource: true)
    }

    private func assertCrossVolumeReplacementRetained(replacementMatchesSource: Bool) async throws {
        guard FileManager.default.fileExists(atPath: Self.disposableVolume.appendingPathComponent(".task6-test-volume").path) else {
            throw XCTSkip("Requires the explicitly created disposable Task 6 disk image")
        }
        let fixture = try await MoveFixture(destinationRoot: Self.disposableVolume)
        defer { fixture.remove() }
        let replacement = replacementMatchesSource ? fixture.bytes : Data([9, 8, 7, 6])
        do {
            try await PhysicalFileMoveTransaction.write(to: fixture.database.writer, batchId: "replaced", afterTransfer: { destination in
                try FileManager.default.removeItem(at: destination)
                try replacement.write(to: destination)
            }) { database, moves in
                let file = try XCTUnwrap(FileRecord.fetchOne(database, key: fixture.fileID))
                _ = try moves.move(.init(fileId: fixture.fileID, newPath: fixture.destination.path, previousPath: fixture.source.path, physicalMove: true), file: file)
            }
            XCTFail("replacement must reject the move")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Retained audio paths")) }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), replacement)
    }

    func testSameVolumeReplacementCannotBecomeRollbackAuthority() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.remove() }
        let retained = fixture.directory.appendingPathComponent("original-retained-by-writer.mp3")
        let original = try FileMetadataCollector.collectVerified(at: fixture.source.path)
        do {
            try await PhysicalFileMoveTransaction.write(to: fixture.database.writer, batchId: "same-volume-replacement", afterTransfer: { destination in
                try FileManager.default.moveItem(at: destination, to: retained)
                try fixture.bytes.write(to: destination)
            }) { database, moves in
                let file = try XCTUnwrap(FileRecord.fetchOne(database, key: fixture.fileID))
                _ = try moves.move(.init(fileId: fixture.fileID, newPath: fixture.destination.path, previousPath: fixture.source.path, physicalMove: true), file: file)
                try database.execute(sql: "INSERT INTO deliberately_missing_table VALUES (1)")
            }
            XCTFail("replacement must reject the move")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Retained audio paths")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try Data(contentsOf: retained), fixture.bytes)
        XCTAssertEqual(try FileMetadataCollector.collectVerified(at: retained.path).inode, original.inode)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        XCTAssertNotEqual(try FileMetadataCollector.collectVerified(at: fixture.destination.path).inode, original.inode)
    }

    func testCrossVolumeMiddleEditBeforeRollbackIsRetained() async throws {
        guard FileManager.default.fileExists(atPath: Self.disposableVolume.appendingPathComponent(".task6-test-volume").path) else {
            throw XCTSkip("Requires the explicitly created disposable Task 6 disk image")
        }
        let fixture = try await MoveFixture(destinationRoot: Self.disposableVolume, bytes: Data(repeating: 3, count: 4 * 1024 * 1024))
        defer { fixture.remove() }
        do {
            try await PhysicalFileMoveTransaction.write(to: fixture.database.writer, batchId: "middle-edit") { database, moves in
                let file = try XCTUnwrap(FileRecord.fetchOne(database, key: fixture.fileID))
                _ = try moves.move(.init(fileId: fixture.fileID, newPath: fixture.destination.path, previousPath: fixture.source.path, physicalMove: true), file: file)
                let handle = try FileHandle(forWritingTo: fixture.destination)
                try handle.seek(toOffset: 2 * 1024 * 1024)
                try handle.write(contentsOf: Data([9]))
                try handle.close()
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(file.mtime + 10))], ofItemAtPath: fixture.destination.path)
                try database.execute(sql: "INSERT INTO deliberately_missing_table VALUES (1)")
            }
            XCTFail("database failure must roll back")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Retained audio paths")) }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        let changed = try Data(contentsOf: fixture.destination)
        XCTAssertEqual(changed[2 * 1024 * 1024], 9)
        XCTAssertEqual(changed.count, fixture.bytes.count)
    }

    func testCrossVolumeOrganizeAndUndo() async throws {
        guard FileManager.default.fileExists(atPath: Self.disposableVolume.appendingPathComponent(".task6-test-volume").path) else {
            throw XCTSkip("Requires the explicitly created disposable Task 6 disk image")
        }
        let fixture = try await MoveFixture(destinationRoot: Self.disposableVolume)
        defer { fixture.remove() }
        let original = try FileMetadataCollector.collectVerified(at: fixture.source.path)
        let outcome = try await LibraryOrganizer(operationEngine: fixture.engine).organize([fixture.plan], batchId: "cross-volume")
        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        XCTAssertNotEqual(try FileMetadataCollector.collectVerified(at: fixture.destination.path).volumeUuid, original.volumeUuid)
        _ = try await fixture.engine.undoBatch("cross-volume")
        try await fixture.assertRestored()
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.hasPrefix(".crate-agent-move-") })
    }

    func testCrossVolumeCommitFailurePreservesOriginalInode() async throws {
        guard FileManager.default.fileExists(atPath: Self.disposableVolume.appendingPathComponent(".task6-test-volume").path) else {
            throw XCTSkip("Requires the explicitly created disposable Task 6 disk image")
        }
        let fixture = try await MoveFixture(destinationRoot: Self.disposableVolume)
        defer { fixture.remove() }
        let original = try FileMetadataCollector.collectVerified(at: fixture.source.path)
        try await fixture.database.writer.write { database in
            try database.execute(sql: "CREATE TABLE commit_failure (file_id INTEGER REFERENCES files(id) DEFERRABLE INITIALLY DEFERRED)")
            try database.execute(sql: "CREATE TRIGGER fail_move_commit AFTER INSERT ON events BEGIN INSERT INTO commit_failure VALUES (999); END")
        }
        do {
            _ = try await fixture.engine.apply(fixture.mutation, batchId: "cross-volume-failure")
            XCTFail("deferred constraint must abort COMMIT")
        } catch is DatabaseError {}
        try await fixture.assertRestored()
        XCTAssertEqual(try FileMetadataCollector.collectVerified(at: fixture.source.path).inode, original.inode)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.hasPrefix(".crate-agent-move-") })
    }

    func testOrganizeAndUndoRestoreAudioAndIdentity() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.remove() }
        let outcome = try await LibraryOrganizer(operationEngine: fixture.engine).organize([fixture.plan], batchId: "move")
        XCTAssertEqual(outcome.movedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        _ = try await fixture.engine.undoBatch("move")
        try await fixture.assertRestored()
    }

    func testLaterMutationFailureCompensatesPhysicalMove() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.remove() }
        do {
            _ = try await fixture.engine.applyBatch([fixture.mutation, .setMetadata(.init(fileId: 999, metadata: .init(artist: "invalid")))], batchId: "rollback")
            XCTFail("missing file must abort the transaction")
        } catch is OperationEngineError {}
        try await fixture.assertRestored()
        let count = try await fixture.database.writer.read { try EventRecord.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }

    func testDeferredForeignKeyCommitFailureCompensatesPhysicalMove() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.remove() }
        try await fixture.database.writer.write { database in
            try database.execute(sql: "CREATE TABLE commit_failure (file_id INTEGER REFERENCES files(id) DEFERRABLE INITIALLY DEFERRED)")
            try database.execute(sql: "CREATE TRIGGER fail_move_commit AFTER INSERT ON events BEGIN INSERT INTO commit_failure VALUES (999); END")
        }
        do {
            _ = try await fixture.engine.apply(fixture.mutation, batchId: "commit-failure")
            XCTFail("deferred foreign key must fail COMMIT")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
        try await fixture.assertRestored()
        let count = try await fixture.database.writer.read { try EventRecord.fetchCount($0) }
        XCTAssertEqual(count, 0)
    }
}

private struct MoveFixture {
    let directory: URL
    let source: URL
    let destination: URL
    let bytes: Data
    let database: LibraryDatabase
    let engine: OperationEngine
    let fileID: Int64

    var plan: LibraryOrganizer.Plan {
        .init(id: fileID, sourcePath: source.path, destinationPath: destination.path, isOutsideMusicFolder: true)
    }

    var mutation: TrackMutation {
        .renameFile(.init(fileId: fileID, newPath: destination.path, previousPath: source.path, physicalMove: true))
    }

    init(destinationRoot: URL? = nil, bytes: Data = Data([1, 2, 3, 4])) async throws {
        self.bytes = bytes
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("source.mp3")
        destination = (destinationRoot ?? directory).appendingPathComponent("destination-\(UUID().uuidString).mp3")
        try bytes.write(to: source)
        let identity = try FileMetadataCollector.collectVerified(at: source.path)
        database = try LibraryDatabase.openInMemory()
        fileID = try await database.writer.write { database in
            var file = FileRecord(path: identity.path, volumeUuid: identity.volumeUuid, inode: identity.inode, fileSize: identity.fileSize, mtime: identity.mtime)
            file.libraryMembership = .active
            file.fileAvailability = .available
            try file.insert(database)
            return try XCTUnwrap(file.id)
        }
        let database = database
        let serato = directory.appendingPathComponent("Serato")
        engine = await MainActor.run {
            OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }), seratoLocator: SeratoLibraryLocator(seratoDirectory: serato))
        }
    }

    func assertRestored() async throws {
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let record = try await database.writer.read { try XCTUnwrap(FileRecord.fetchOne($0, key: fileID)) }
        let actual = try FileMetadataCollector.collectVerified(at: source.path)
        XCTAssertEqual(record.path, source.path)
        XCTAssertEqual(record.inode, actual.inode)
        XCTAssertEqual(record.volumeUuid, actual.volumeUuid)
    }

    func remove() {
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: directory)
    }
}
