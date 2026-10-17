@testable import CrateAgent
import GRDB
import XCTest

final class OperationEngineBatchRenameTests: XCTestCase {
    @MainActor
    func testBatchRenameRewritesEveryPathInDatabaseV2() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        var files: [FileRecord] = []
        for filename in ["one.mp3", "two.mp3", "three.mp3"] {
            try await files.append(fixture.add(filename))
        }
        try fixture.save(paths: files.map { SeratoLibraryLocator.seratoRelativePath(fromAbsolute: $0.path) })
        let destinations = files.map { fixture.directory.appendingPathComponent("moved").appendingPathComponent(($0.path as NSString).lastPathComponent).path }
        let mutations = try zip(files, destinations).map { file, destination in
            try TrackMutation.renameFile(.init(fileId: XCTUnwrap(file.id), newPath: destination, previousPath: file.path, physicalMove: true))
        }
        try await fixture.engine.applyBatch(mutations, batchId: "batch-rename")
        XCTAssertEqual(try readDatabasePaths(databasePath: fixture.locator.databaseV2Url.path), destinations.map { SeratoLibraryLocator.seratoRelativePath(fromAbsolute: $0) })
        try await fixture.database.writer.read { database in
            XCTAssertEqual(try FileRecord.order(Column("id")).fetchAll(database).map(\.path), destinations)
            XCTAssertEqual(try EventRecord.filter(Column("batch_id") == "batch-rename" && Column("event_type") == EventType.fileRenamed.rawValue).fetchCount(database), 3)
        }
        for path in destinations {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
    }
}
