@testable import CrateAgent
import GRDB
import XCTest

final class FileEligibilityIntegrationTests: XCTestCase {
    func testOrganizerRejectsStalePlanBeforeMovingAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp3")
        let destination = directory.appendingPathComponent("destination.mp3")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: source)
        let identity = try FileMetadataCollector.collectVerified(at: source.path)
        let database = try LibraryDatabase.openInMemory()
        let fileID = try await database.writer.write { database in
            var file = FileRecord(path: source.path, volumeUuid: identity.volumeUuid, inode: identity.inode, fileSize: identity.fileSize, mtime: identity.mtime)
            file.libraryMembership = .active
            file.fileAvailability = .available
            try file.insert(database)
            return try XCTUnwrap(file.id)
        }
        let engine = await MainActor.run {
            OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }), seratoLocator: SeratoLibraryLocator(seratoDirectory: directory.appendingPathComponent("Serato")))
        }
        let organizer = LibraryOrganizer(operationEngine: engine)
        let plan = LibraryOrganizer.Plan(id: fileID, sourcePath: source.path, destinationPath: destination.path, isOutsideMusicFolder: true)
        _ = try await engine.apply(.setFileLibraryState(.init(fileId: fileID, expectedRevision: 0, state: .init(membership: .retired, availability: .available, libraryID: nil, retiredAt: 1))))
        _ = try await engine.apply(.setFileLibraryState(.init(fileId: fileID, expectedRevision: 1, state: .init(membership: .active, availability: .available, libraryID: nil, retiredAt: nil))))
        let outcome = try await organizer.organize([plan])
        XCTAssertEqual(outcome.movedCount, 0)
        XCTAssertEqual(outcome.failureCount, 1)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testBrowsingExcludesRetiredAcrossEverySearchBranch() throws {
        let database = try LibraryDatabase.openInMemory()
        try database.writer.write { database in
            for (index, membership) in [LibraryMembership.active, .active, .retired, .pendingImport, .legacyUnverified].enumerated() {
                var file = FileRecord(path: "/needle-\(index).mp3", volumeUuid: "test", inode: Int64(index), fileSize: 1, mtime: 0, artist: "needle", title: "needle")
                file.libraryMembership = membership
                file.fileAvailability = index == 1 ? .missing : .available
                try file.insert(database)
            }
            for filter in AutoTagBrowseFilter.allCases {
                let result = try AutoTagFileBrowse.browse(filter: filter, in: database)
                XCTAssertEqual(result.totalMatchCount, 4)
                XCTAssertEqual(result.matches.count, 4)
            }
            let search = try AutoTagFileSearch.search(query: "needle", in: database)
            XCTAssertEqual(search.totalMatchCount, 4)
            XCTAssertEqual(search.matches.count, 4)
            XCTAssertEqual(try LibraryBrowserView.fetchBrowserRows(database, search: "needle", sortOrder: [], limit: 200).count, 4)
            XCTAssertEqual(try LibraryBrowserView.fetchBrowserRows(database, search: "", sortOrder: [], limit: 200).count, 4)
            XCTAssertEqual(try HygieneFileRow.fetchAll(database, sql: HygieneFileRow.hygieneFetchSQL).count, 1)
        }
    }

    func testWorkerRejectsRetirementAndReactivationDuringDecode() async throws {
        for scenario in 0 ... 2 {
            let database = try LibraryDatabase.openInMemory()
            let started = expectation(description: "decode started")
            let release = DispatchSemaphore(value: 0)
            let fileID = try await database.writer.write { database in
                var file = FileRecord(path: "/audio.mp3", volumeUuid: "test", inode: 1, fileSize: 1, mtime: 0)
                file.libraryMembership = .active
                file.fileAvailability = .available
                try file.insert(database)
                return try XCTUnwrap(file.id)
            }
            let worker = FingerprintWorker(database: database, concurrency: 1, fingerprintFunction: { _ in
                started.fulfill()
                release.wait()
                return [1, 2, 3]
            })
            let task = Task { try await worker.processAllPendingOnce() }
            await fulfillment(of: [started], timeout: 5)
            try await database.writer.write { database in
                try database.execute(sql: "UPDATE files SET library_membership = ?, membership_revision = ?, file_availability = ? WHERE id = ?", arguments: [scenario == 0 ? "retired" : "active", scenario == 2 ? 0 : 2, scenario == 2 ? "missing" : "available", fileID])
            }
            release.signal()
            _ = try await task.value
            let file = try await database.writer.read { try FileRecord.fetchOne($0, key: fileID) }
            XCTAssertNil(file?.chromaprintFingerprint)
            XCTAssertEqual(file?.fingerprintStatus, .pending)
        }
    }

    func testWorkerGuardsCopiedTwinsAndSiblingsIndependently() async throws {
        let database = try LibraryDatabase.openInMemory()
        let started = expectation(description: "representative decoding")
        let release = DispatchSemaphore(value: 0)
        let fileIDs = try await database.writer.write { database in
            try (0 ..< 5).map { index in
                var file = FileRecord(path: "/audio-\(index).mp3", volumeUuid: "test", inode: Int64(index), fileSize: 1, mtime: 0)
                file.libraryMembership = .active
                file.fileAvailability = .available
                file.lightweightHash = Data([index < 3 ? 1 : 2])
                if index == 4 {
                    file.fingerprintStatus = .done
                    file.chromaprintFingerprint = FingerprintEncoder.serialize([4, 5, 6])
                }
                try file.insert(database)
                return try XCTUnwrap(file.id)
            }
        }
        let worker = FingerprintWorker(database: database, concurrency: 1, fingerprintFunction: { _ in
            started.fulfill()
            release.wait()
            return [1, 2, 3]
        })
        let task = Task { try await worker.processAllPendingOnce() }
        await fulfillment(of: [started], timeout: 5)
        try await database.writer.write { database in
            for fileID in [fileIDs[0], fileIDs[1], fileIDs[3]] {
                try database.execute(sql: "UPDATE files SET membership_revision = membership_revision + 2 WHERE id = ?", arguments: [fileID])
            }
        }
        release.signal()
        let progress = try await task.value
        XCTAssertEqual(progress.totalDone, 1)
        let files = try await database.writer.read { try FileRecord.order(Column("id")).fetchAll($0) }
        for index in [0, 1, 3] {
            XCTAssertNil(files[index].chromaprintFingerprint)
            XCTAssertEqual(files[index].fingerprintStatus, .pending)
        }
        XCTAssertEqual(files[2].chromaprintFingerprint, FingerprintEncoder.serialize([1, 2, 3]))
        XCTAssertEqual(files[4].chromaprintFingerprint, FingerprintEncoder.serialize([4, 5, 6]))
    }

    func testWorkerOnlySelectsActiveAvailableFiles() async throws {
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { database in
            for (index, membership) in [LibraryMembership.active, .active, .retired, .pendingImport, .legacyUnverified].enumerated() {
                var file = FileRecord(path: "/audio-\(index).mp3", volumeUuid: "test", inode: Int64(index), fileSize: 1, mtime: 0)
                file.libraryMembership = membership
                file.fileAvailability = index == 1 ? .missing : .available
                try file.insert(database)
            }
        }
        let worker = FingerprintWorker(database: database, fingerprintFunction: { path in
            XCTAssertEqual(path, "/audio-0.mp3")
            return [1, 2, 3]
        })
        let progress = try await worker.processAllPendingOnce()
        XCTAssertEqual(progress.totalDone, 1)
        XCTAssertEqual(progress.totalFailed, 0)
    }
}
