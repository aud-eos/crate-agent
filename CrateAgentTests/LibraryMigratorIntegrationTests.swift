@testable import CrateAgent
import GRDB
import XCTest

@MainActor
final class LibraryMigratorIntegrationTests: XCTestCase {
    func testMigrationMaintainsAudioAndLibraryConsistency() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        try await assertLifecycleChangesRejectBeforeMoving(fixture)
        try await assertPhysicalChangesInvalidatePreview(fixture)
        try await assertCommitFailureRestoresAudio(fixture)
        try await assertPartialMigrationAndUndo(fixture)
        try await assertExternalFailureCanBeResynced(fixture)
        try await assertUnavailableFilesPreventRootCompletion(fixture)
    }

    private func assertLifecycleChangesRejectBeforeMoving(_ fixture: SeratoRemovalFixture) async throws {
        for scenario in ["retired", "unavailable", "reactivated"] {
            let file = try await fixture.add("\(scenario).mp3")
            let plans = try preview([file], fixture: fixture)
            let fileID = try XCTUnwrap(file.id)
            try await fixture.engine.apply(.setFileLibraryState(.init(
                fileId: fileID, expectedRevision: 0,
                state: .init(membership: scenario == "unavailable" ? .active : .retired,
                             availability: scenario == "unavailable" ? .missing : .available,
                             libraryID: file.seratoLibraryId, retiredAt: scenario == "unavailable" ? nil : 1)
            )))
            if scenario == "reactivated" {
                try await fixture.engine.apply(.setFileLibraryState(.init(
                    fileId: fileID, expectedRevision: 1,
                    state: .init(membership: .active, availability: .available, libraryID: file.seratoLibraryId, retiredAt: nil)
                )))
            }
            let eventCount = try await fixture.events()
            let result = try await LibraryMigrator(operationEngine: fixture.engine).migrate(plans)
            XCTAssertEqual(result.movedCount, 0, scenario)
            XCTAssertEqual(result.failureCount, 1, scenario)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), scenario)
            XCTAssertFalse(FileManager.default.fileExists(atPath: plans[0].destinationPath), scenario)
            let current = try await fixture.row(file)
            XCTAssertEqual(current.path, file.path, scenario)
            let afterCount = try await fixture.events()
            XCTAssertEqual(afterCount, eventCount, "Rejected moves must not create rename events")
        }
    }

    private func assertPhysicalChangesInvalidatePreview(_ fixture: SeratoRemovalFixture) async throws {
        for replace in [false, true] {
            let file = try await fixture.add("physical-\(replace).mp3")
            let plans = try preview([file], fixture: fixture)
            let source = URL(fileURLWithPath: file.path)
            let before = try SeratoSourceIdentity.read(source)
            let changedBytes = Data([9, 8, 7, 6])
            if replace {
                let retained = source.appendingPathExtension("retained")
                try FileManager.default.moveItem(at: source, to: retained)
                try changedBytes.write(to: source)
            } else {
                let handle = try FileHandle(forWritingTo: source)
                try handle.write(contentsOf: changedBytes)
                try handle.close()
                var timestamps = [timespec(tv_sec: before.modifiedSeconds, tv_nsec: before.modifiedNanoseconds),
                                  timespec(tv_sec: before.modifiedSeconds, tv_nsec: before.modifiedNanoseconds == 123_456_789 ? 234_567_890 : 123_456_789)]
                XCTAssertEqual(utimensat(AT_FDCWD, file.path, &timestamps, 0), 0)
                let after = try SeratoSourceIdentity.read(source)
                XCTAssertEqual(after.modifiedSeconds, before.modifiedSeconds)
                XCTAssertEqual(after.inode, before.inode)
                XCTAssertEqual(after.size, before.size)
            }
            // Model a background scan refreshing SQLite after the preview.
            let refreshed = try FileMetadataCollector.collectVerified(at: file.path)
            try await fixture.database.writer.write { database in
                var current = try XCTUnwrap(FileRecord.fetchOne(database, key: file.id))
                current.volumeUuid = refreshed.volumeUuid
                current.inode = refreshed.inode
                current.fileSize = refreshed.fileSize
                current.mtime = refreshed.mtime
                current.lightweightHash = refreshed.lightweightHash
                try current.update(database)
            }
            let result = try await LibraryMigrator(operationEngine: fixture.engine).migrate(plans)
            XCTAssertEqual(result.movedCount, 0)
            XCTAssertEqual(result.failureCount, 1)
            XCTAssertEqual(try Data(contentsOf: source), changedBytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: plans[0].destinationPath))
        }
    }

    private func assertCommitFailureRestoresAudio(_ fixture: SeratoRemovalFixture) async throws {
        let file = try await fixture.add("rollback.mp3")
        let plans = try preview([file], fixture: fixture)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let eventCount = try await fixture.events()
        try await fixture.database.writer.write { database in
            try database.execute(sql: "CREATE TABLE migration_commit_failure (file_id INTEGER REFERENCES files(id) DEFERRABLE INITIALLY DEFERRED)")
            try database.execute(sql: "CREATE TRIGGER fail_migration_commit AFTER INSERT ON events BEGIN INSERT INTO migration_commit_failure VALUES (999999); END")
        }
        let result = try await LibraryMigrator(operationEngine: fixture.engine).migrate(plans)
        XCTAssertEqual(result.movedCount, 0)
        XCTAssertEqual(result.failureCount, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plans[0].destinationPath))
        let current = try await fixture.row(file)
        XCTAssertEqual(current.path, file.path)
        XCTAssertEqual(current.inode, file.inode)
        let afterCount = try await fixture.events()
        XCTAssertEqual(afterCount, eventCount)
        try await fixture.database.writer.write { database in
            try database.execute(sql: "DROP TRIGGER fail_migration_commit")
            try database.execute(sql: "DROP TABLE migration_commit_failure")
        }
    }

    private func assertPartialMigrationAndUndo(_ fixture: SeratoRemovalFixture) async throws {
        let first = try await fixture.add("first.mp3")
        let blocked = try await fixture.add("blocked.mp3")
        let second = try await fixture.add("second.mp3")
        let files = [first, blocked, second]
        let plans = try preview(files, fixture: fixture)
        try await fixture.engine.apply(.setFileLibraryState(.init(
            fileId: XCTUnwrap(blocked.id), expectedRevision: 0,
            state: .init(membership: .active, availability: .inaccessible, libraryID: blocked.seratoLibraryId, retiredAt: nil)
        )))
        let originalPaths = files.map(\.path)
        let crates = try saveSeratoPaths(originalPaths, fixture: fixture)
        let batchID = "migration-round-trip"
        let result = try await LibraryMigrator(operationEngine: fixture.engine).migrate(plans, batchId: batchID)
        XCTAssertEqual(result.movedCount, 2)
        XCTAssertEqual(result.failureCount, 1)
        let expected = [plans[0].destinationPath, blocked.path, plans[2].destinationPath]
        try assertSeratoPaths(expected, fixture: fixture, crates: crates)
        for index in [0, 2] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: files[index].path))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: plans[index].destinationPath)), Data([1, 2, 3, 4]))
            let current = try await fixture.row(files[index])
            XCTAssertEqual(current.path, plans[index].destinationPath)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        let refreshed = try await fixture.database.writer.read { database in
            try FileRecord.filter(ids: [first.id!, second.id!]).fetchAll(database)
        }
        XCTAssertTrue(try preview(refreshed, fixture: fixture).isEmpty,
                      "A retry must not nest already-moved files inside the destination again")
        let events = try await fixture.database.writer.read { database in
            try EventRecord.filter(Column("batch_id") == batchID).fetchAll(database)
        }
        XCTAssertEqual(events.count, 2)
        _ = try await fixture.engine.undoBatch(result.batchId)
        try assertSeratoPaths(originalPaths, fixture: fixture, crates: crates)
        for index in [0, 2] {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: files[index].path)), Data([1, 2, 3, 4]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: plans[index].destinationPath))
            let current = try await fixture.row(files[index])
            XCTAssertEqual(current.path, files[index].path)
        }
    }

    private func assertExternalFailureCanBeResynced(_ fixture: SeratoRemovalFixture) async throws {
        for count in [1, 2] {
            for failedStore in 0 ..< 3 {
                var files: [FileRecord] = []
                for index in 0 ..< count {
                    try await files.append(fixture.add("resync-\(count)-\(failedStore)-\(index).mp3"))
                }
                let plans = try preview(files, fixture: fixture)
                let crates = try saveSeratoPaths(files.map(\.path), fixture: fixture)
                let failedURL = ([fixture.locator.databaseV2Url] + crates)[failedStore]
                let originalBytes = try Data(contentsOf: failedURL)
                try FileManager.default.removeItem(at: failedURL)
                try FileManager.default.createDirectory(at: failedURL, withIntermediateDirectories: true)
                let batchID = "migration-resync-\(count)-\(failedStore)"
                do {
                    _ = try await LibraryMigrator(operationEngine: fixture.engine).migrate(plans, batchId: batchID)
                    XCTFail("A failed Serato store must remain visible even when others succeed")
                } catch let error as OperationEngineError {
                    guard case let .externalSyncIncomplete(appliedBatchID, _) = error else { throw error }
                    XCTAssertEqual(appliedBatchID, batchID)
                }
                for (file, plan) in zip(files, plans) {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
                    XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destinationPath))
                    let current = try await fixture.row(file)
                    XCTAssertEqual(current.path, plan.destinationPath)
                }
                try FileManager.default.removeItem(at: failedURL)
                try originalBytes.write(to: failedURL)
                _ = try await fixture.engine.resyncSeratoForBatch(batchID)
                try assertSeratoPaths(plans.map(\.destinationPath), fixture: fixture, crates: crates)
                _ = try await fixture.engine.undoBatch(batchID)
                try assertSeratoPaths(files.map(\.path), fixture: fixture, crates: crates)
                for file in files {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                }
            }
        }
    }

    private func assertUnavailableFilesPreventRootCompletion(_ fixture: SeratoRemovalFixture) async throws {
        let oldRoot = fixture.directory.appendingPathComponent("completion", isDirectory: true)
        let newRoot = oldRoot.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        let available = try await fixture.add("completion/available.mp3")
        let unavailable = try await fixture.add("completion/unavailable.mp3")
        try await fixture.engine.apply(.setFileLibraryState(.init(
            fileId: XCTUnwrap(unavailable.id), expectedRevision: 0,
            state: .init(membership: .active, availability: .missing, libraryID: unavailable.seratoLibraryId, retiredAt: nil)
        )))
        let plans = try LibraryMigrator.prepareMoves(in: [available], oldRoot: oldRoot, newRoot: newRoot)
        let result = try await LibraryMigrator(operationEngine: fixture.engine).migrate(plans)
        XCTAssertEqual(result.failureCount, 0)
        let remaining = try await LibraryMigrator.remainingFileCount(in: fixture.database, oldRoot: oldRoot, newRoot: newRoot)
        XCTAssertEqual(remaining, 1, "Unavailable active files still need migration after a successful partial preview")
        try await fixture.engine.apply(.setFileLibraryState(.init(
            fileId: XCTUnwrap(unavailable.id), expectedRevision: 0,
            state: .init(membership: .retired, availability: .missing, libraryID: unavailable.seratoLibraryId, retiredAt: 1)
        )))
        let afterRetirement = try await LibraryMigrator.remainingFileCount(in: fixture.database, oldRoot: oldRoot, newRoot: newRoot)
        XCTAssertEqual(afterRetirement, 0, "Retired entries are outside the active library migration")
    }

    private func saveSeratoPaths(_ paths: [String], fixture: SeratoRemovalFixture) throws -> [URL] {
        try fixture.save(paths: paths.map(SeratoLibraryLocator.seratoRelativePath))
        let crates = [fixture.locator.subcratesDirectoryUrl.appendingPathComponent("test.crate"),
                      fixture.locator.smartCratesDirectoryUrl.appendingPathComponent("test.scrate")]
        let bytes = paths.reduce(SeratoTestEncoding.record("vrsn", Data())) { bytes, path in
            bytes + SeratoTestEncoding.record("otrk", SeratoTestEncoding.record("ptrk", SeratoLibraryLocator.seratoRelativePath(fromAbsolute: path).data(using: .utf16BigEndian)!))
        }
        for crate in crates {
            try bytes.write(to: crate)
        }
        return crates
    }

    private func preview(_ files: [FileRecord], fixture: SeratoRemovalFixture) throws -> [LibraryMigrator.Plan] {
        try LibraryMigrator.prepareMoves(in: files, oldRoot: fixture.directory,
                                         newRoot: fixture.directory.appendingPathComponent("migrated", isDirectory: true))
    }

    private func assertSeratoPaths(_ expected: [String], fixture: SeratoRemovalFixture, crates: [URL]) throws {
        XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).map { record in SeratoPath.normalized(record.path) }, expected)
        for crate in crates {
            XCTAssertEqual(try readCratePaths(cratePath: crate.path).map(SeratoPath.normalized), expected)
        }
    }
}
