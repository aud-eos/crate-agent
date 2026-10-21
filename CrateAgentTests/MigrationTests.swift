@testable import CrateAgent
import GRDB
import XCTest

final class MigrationTests: XCTestCase {
    func testCheckpointMigrationPreservesExistingFilesAndEvents() throws {
        let queue = try DatabaseQueue()
        let migrator = LibraryDatabase.makeMigrator()
        try migrator.migrate(queue, upTo: "010_add_file_library_state")
        try queue.write { connection in
            // The current record type has columns this older schema lacks.
            try connection.execute(sql: "INSERT INTO files (path, volume_uuid, inode, file_size, mtime) VALUES ('/existing.wav', 'fixture', 1, 64, 1)")
            var event = EventRecord(batchId: "existing", timestamp: 1, fileId: connection.lastInsertedRowID, eventType: .fileIdentityObserved,
                                    payloadJson: "{\"forward\":true}", inversePayloadJson: "{\"inverse\":true}")
            try event.insert(connection)
        }
        let before = try queue.read { connection in
            try (Row.fetchAll(connection, sql: "SELECT * FROM files"), Row.fetchAll(connection, sql: "SELECT * FROM events"))
        }
        let existingFileColumns = before.0.first.map { row in Array(row.columnNames) } ?? []
        try migrator.migrate(queue)
        try queue.read { connection in
            let preservedFiles = try Row.fetchAll(connection, sql: "SELECT \(existingFileColumns.joined(separator: ", ")) FROM files")
            XCTAssertEqual(preservedFiles, before.0)
            XCTAssertEqual(try Row.fetchAll(connection, sql: "SELECT * FROM events"), before.1)
        }
    }

    func testKeeperIndexMigrationBackfillsPendingRemovalsSavedBeforeIt() throws {
        let queue = try DatabaseQueue()
        let migrator = LibraryDatabase.makeMigrator()
        try migrator.migrate(queue, upTo: "032_add_keeper_marks")
        try queue.write { connection in
            let duplicatePayload = #"{"batchID":"b","keeper":{"token":{"fileId":7,"revision":1}},"target":{"token":{"fileId":9,"revision":1}}}"#
            let ownerChoicePayload = #"{"batchID":"b","keeper":null,"target":{"token":{"fileId":8,"revision":1}}}"#
            try connection.execute(sql: "INSERT INTO duplicate_cleanup_intents (target_file_id, payload, step) VALUES (9, ?, 0), (8, ?, 0)",
                                   arguments: [Data(duplicatePayload.utf8), Data(ownerChoicePayload.utf8)])
        }
        try migrator.migrate(queue)
        try queue.read { connection in
            XCTAssertTrue(try DuplicateCleanupStore.isKeeper(fileID: 7, in: connection))
            XCTAssertFalse(try DuplicateCleanupStore.isKeeper(fileID: 8, in: connection))
            XCTAssertFalse(try DuplicateCleanupStore.isKeeper(fileID: 9, in: connection))
        }
    }

    func testMigration007AddsMusicBrainzColumns() async throws {
        let database = try LibraryDatabase.openInMemory()
        let columnNames: [String] = try await database.writer.read { connection in
            try connection.columns(in: "tracks").map(\.name)
        }
        XCTAssertTrue(columnNames.contains("musicbrainz_release_id"))
        XCTAssertTrue(columnNames.contains("musicbrainz_artist_id"))
        XCTAssertTrue(columnNames.contains("isrc"))
    }
}
