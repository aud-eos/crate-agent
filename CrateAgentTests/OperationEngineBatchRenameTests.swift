import GRDB
import XCTest
@testable import CrateAgent

final class OperationEngineBatchRenameTests: XCTestCase {

    // Synthesize a database V2 with the given paths. Reuses the
    // test helper exposed by the main test class so the on-disk
    // byte layout stays in lockstep with the rest of the suite.
    private func writeTemporarySeratoLibrary(
        withDatabasePaths paths: [String]
    ) throws -> URL {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "crate-agent-batch-rename-\(UUID().uuidString)",
                isDirectory: true
            )
        let seratoDirectory = rootDirectory.appendingPathComponent(
            "_Serato_",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: seratoDirectory.appendingPathComponent("Subcrates", isDirectory: true),
            withIntermediateDirectories: true
        )
        let databaseV2Url = seratoDirectory.appendingPathComponent("database V2")
        let bytes = OperationEngineTests.synthesizeDatabaseV2BytesForTest(
            withTrackPaths: paths
        )
        try bytes.write(to: databaseV2Url)
        return seratoDirectory
    }

    @MainActor
    private func makeEngine(
        seratoDirectory: URL
    ) throws -> (OperationEngine, LibraryDatabase) {
        let database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(
            runningBundleIdentifiersProvider: { [] } // Serato closed
        )
        let locator = SeratoLibraryLocator(seratoDirectory: seratoDirectory)
        let engine = OperationEngine(
            database: database,
            seratoWatchdog: watchdog,
            seratoLocator: locator,
            fileTagWriter: { _, _ in /* synthetic paths */ },
            fileTrasher: { _ in /* synthetic paths */ }
        )
        return (engine, database)
    }

    func testBatchRenameRewritesEveryPathInDatabaseV2() async throws {
        // Three Serato-relative paths registered in the V2 fixture.
        // The matching absolute paths must resolve to the same
        // Serato-relative form — the locator strips the leading
        // music-folder slash for us, so any well-formed absolute
        // path works.
        let seratoPaths = [
            "Music/A/one.mp3",
            "Music/A/two.mp3",
            "Music/A/three.mp3",
        ]
        let seratoDirectory = try writeTemporarySeratoLibrary(
            withDatabasePaths: seratoPaths
        )
        let databaseV2Path = seratoDirectory
            .appendingPathComponent("database V2").path

        let (engine, database) = try await MainActor.run {
            try makeEngine(seratoDirectory: seratoDirectory)
        }

        // Index the three files in the SQLite sidecar. Absolute
        // paths shaped so seratoRelativePath strips the leading
        // slash and yields the Serato-relative form above.
        for (index, seratoPath) in seratoPaths.enumerated() {
            try await engine.apply(.indexNewFile(IndexNewFilePayload(
                path: "/\(seratoPath)",
                volumeUuid: "v1",
                inode: Int64(index + 1),
                fileSize: 1,
                mtime: 1
            )))
        }

        // Look up the inserted file IDs.
        let fileIds = try await database.writer.read { connection in
            try Int64.fetchAll(
                connection,
                sql: "SELECT id FROM files ORDER BY id ASC"
            )
        }
        XCTAssertEqual(fileIds.count, 3)

        // applyBatch with three rename mutations. Serato is not
        // running, so the path goes through applyConsecutiveSeratoWrites
        // → applySeratoRenameBatch → batchRewriteDatabasePaths (one
        // file write covering all three renames).
        try await engine.applyBatch(
            [
                .renameFile(RenameFilePayload(fileId: fileIds[0], newPath: "/Music/B/one.mp3")),
                .renameFile(RenameFilePayload(fileId: fileIds[1], newPath: "/Music/B/two.mp3")),
                .renameFile(RenameFilePayload(fileId: fileIds[2], newPath: "/Music/B/three.mp3")),
            ],
            batchId: "batch-rename"
        )

        // Read the V2 file back through the Rust FFI and verify
        // every path was rewritten.
        let postRenamePaths = try readDatabasePaths(databasePath: databaseV2Path)
        XCTAssertEqual(
            postRenamePaths,
            [
                "Music/B/one.mp3",
                "Music/B/two.mp3",
                "Music/B/three.mp3",
            ]
        )

        // DB side: every file row's path should also reflect the
        // rename, and three fileRenamed events should share the
        // batch ID.
        try await database.writer.read { connection in
            let paths = try String.fetchAll(
                connection,
                sql: "SELECT path FROM files ORDER BY id ASC"
            )
            XCTAssertEqual(paths, [
                "/Music/B/one.mp3",
                "/Music/B/two.mp3",
                "/Music/B/three.mp3",
            ])
            let renameEventCount = try EventRecord
                .filter(Column("batch_id") == "batch-rename")
                .filter(Column("event_type") == EventType.fileRenamed.rawValue)
                .fetchCount(connection)
            XCTAssertEqual(renameEventCount, 3)
        }
    }
}
