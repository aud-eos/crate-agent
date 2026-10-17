@testable import CrateAgent
import GRDB
import XCTest

/// Queue passes run one at a time, so the two imports' Serato bootstrap
/// decisions cannot interleave; both must still land.
final class ConcurrentImportBootstrapTests: XCTestCase {
    @MainActor
    func testConcurrentPendingImportsBothSurviveInitiallyAbsentDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LibraryDatabase(writer: DatabasePool(path: root.appendingPathComponent("sidecar.sqlite").path))
        let audioURLs = [root.appendingPathComponent("first.mp3"), root.appendingPathComponent("second.mp3")]
        for audio in audioURLs {
            try Data(audio.lastPathComponent.utf8).write(to: audio)
        }
        let fileIDs = try await database.writer.write { connection in
            try audioURLs.map { audio in
                let identity = try FileMetadataCollector.collectVerified(at: audio.path)
                var file = FileRecord(path: audio.path, volumeUuid: identity.volumeUuid, inode: identity.inode,
                                      fileSize: identity.fileSize, mtime: identity.mtime, lightweightHash: identity.lightweightHash)
                file.libraryMembership = .pendingImport
                file.fileAvailability = .available
                file.membershipRevision = 1
                try file.insert(connection)
                return try XCTUnwrap(file.id)
            }
        }
        let seratoDirectory = root.appendingPathComponent("_Serato_")
        let v2URL = seratoDirectory.appendingPathComponent("database V2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: v2URL.path))
        let engine = OperationEngine(database: database,
                                     seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }),
                                     seratoLocator: SeratoLibraryLocator(seratoDirectory: seratoDirectory))
        async let first = engine.apply(.addTrackToSerato(AddTrackToSeratoPayload(fileId: fileIDs[0], metadata: SeratoMetadata(title: "first"))))
        async let second = engine.apply(.addTrackToSerato(AddTrackToSeratoPayload(fileId: fileIDs[1], metadata: SeratoMetadata(title: "second"))))
        _ = try await (first, second)
        let queued = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(queued, 0, "Both imports must finish their durable external effects")
        let records = try readDatabaseRecords(databasePath: v2URL.path)
        XCTAssertEqual(Set(records.map(\.path)), Set(audioURLs.map { audio in SeratoLibraryLocator.seratoRelativePath(fromAbsolute: audio.path) }))
        try await database.writer.read { connection in
            let files = try FileRecord.order(Column("id")).fetchAll(connection)
            XCTAssertEqual(files.map(\.libraryMembership), [.active, .active])
            XCTAssertEqual(files.map(\.membershipRevision), [2, 2])
            XCTAssertEqual(try EventRecord.filter(Column("event_type") == EventType.trackAddedToSerato.rawValue).fetchCount(connection), 2)
            XCTAssertEqual(try EventRecord.filter(Column("event_type") == EventType.fileLibraryStateChanged.rawValue).fetchCount(connection), 2)
        }
    }
}
