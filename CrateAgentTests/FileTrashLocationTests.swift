@testable import CrateAgent
import GRDB
import XCTest

final class FileTrashLocationTests: XCTestCase {
    func testRemovingAnotherTrashItemLeavesTrashedFileUnchanged() async throws {
        let fixture = try await TrashedFilesFixture(names: ["kept.mp3", "emptied.mp3"])
        defer { fixture.cleanup() }
        let kept = fixture.files[0], emptied = fixture.files[1]
        try FileManager.default.removeItem(atPath: emptied.trashPath)
        try await fixture.coordinator.handleObservations([.init(path: emptied.trashPath, isFile: true, wasRemoved: true)])
        let emptiedRow = try await fixture.row(emptied)
        XCTAssertEqual(emptiedRow.fileAvailability, .missing)
        XCTAssertEqual(emptiedRow.path, emptied.originalPath)
        let emptiedLocation = try await fixture.location(emptied)
        XCTAssertNil(emptiedLocation)
        let keptRow = try await fixture.row(kept)
        XCTAssertEqual(keptRow.fileAvailability, .trashed)
        let keptLocation = try await fixture.location(kept)
        XCTAssertEqual(keptLocation?.inode, keptRow.inode)
    }

    func testRestoringFromTrashClearsRecordedLocation() async throws {
        let fixture = try await TrashedFilesFixture(names: ["restored.mp3"])
        defer { fixture.cleanup() }
        let restored = fixture.files[0]
        try FileManager.default.moveItem(atPath: restored.trashPath, toPath: restored.originalPath)
        try await fixture.coordinator.handleObservations([
            .init(path: restored.trashPath, isFile: true, wasRenamed: true),
            .init(path: restored.originalPath, isFile: true, wasRenamed: true),
        ])
        let row = try await fixture.row(restored)
        XCTAssertEqual(row.fileAvailability, .available)
        let location = try await fixture.location(restored)
        XCTAssertNil(location)
    }
}

/// Indexed files moved to the native Trash of the task-owned APFS volume and observed there.
private final class TrashedFilesFixture {
    struct TrashedFile {
        let fileID: Int64
        let originalPath: String
        let trashPath: String
    }

    let directory: URL
    let database: LibraryDatabase
    let coordinator: FilesystemSyncCoordinator
    private(set) var files: [TrashedFile] = []

    init(names: [String]) async throws {
        let ownedVolume = URL(fileURLWithPath: "/private/tmp/crate-agent-task6-volume")
        guard FileManager.default.fileExists(atPath: ownedVolume.appendingPathComponent(".task6-test-volume").path) else {
            throw XCTSkip("Requires task-owned APFS volume")
        }
        directory = ownedVolume.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try LibraryDatabase.openInMemory()
        self.database = database
        let engine = await MainActor.run {
            OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }),
                            seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")))
        }
        coordinator = FilesystemSyncCoordinator(operationEngine: engine, database: database)
        for (index, name) in names.enumerated() {
            let source = directory.appendingPathComponent(name)
            try Data([UInt8(index), 7, 8, 9]).write(to: source)
            let metadata = try FileMetadataCollector.collectVerified(at: source.path)
            let fileID = try await database.writer.write { connection in
                var file = FileRecord(path: source.path, volumeUuid: metadata.volumeUuid, inode: metadata.inode, fileSize: metadata.fileSize,
                                      mtime: metadata.mtime, lightweightHash: metadata.lightweightHash)
                file.libraryMembership = .active
                file.fileAvailability = .available
                try file.insert(connection)
                return try XCTUnwrap(file.id)
            }
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
            let trashPath = try XCTUnwrap(resultingURL as URL?).path
            files.append(TrashedFile(fileID: fileID, originalPath: source.path, trashPath: trashPath))
            try await coordinator.handleObservations([
                .init(path: trashPath, isFile: true, wasRenamed: true),
                .init(path: source.path, isFile: true, wasRemoved: true),
            ])
            let trashed = try await database.writer.read { connection in try FileRecord.fetchOne(connection, key: fileID) }
            XCTAssertEqual(trashed?.fileAvailability, .trashed)
        }
    }

    func row(_ file: TrashedFile) async throws -> FileRecord {
        try await database.writer.read { connection in try XCTUnwrap(FileRecord.fetchOne(connection, key: file.fileID)) }
    }

    func location(_ file: TrashedFile) async throws -> FileMetadata? {
        try await database.writer.read { connection in try FileTrashLocation.load(fileID: file.fileID, in: connection) }
    }

    func cleanup() {
        for file in files {
            try? FileManager.default.removeItem(atPath: file.trashPath)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
