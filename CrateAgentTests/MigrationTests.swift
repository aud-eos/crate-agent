@testable import CrateAgent
import GRDB
import XCTest

final class MigrationTests: XCTestCase {
    func testCheckpointMigrationPreservesExistingFilesAndEvents() throws {
        let queue = try DatabaseQueue()
        let migrator = LibraryDatabase.makeMigrator()
        try migrator.migrate(queue, upTo: "010_add_file_library_state")
        try queue.write { connection in
            var file = FileRecord(path: "/existing.wav", volumeUuid: "fixture", inode: 1, fileSize: 64, mtime: 1)
            try file.insert(connection)
            var event = EventRecord(batchId: "existing", timestamp: 1, fileId: file.id, eventType: .fileIdentityObserved,
                                    payloadJson: "{\"forward\":true}", inversePayloadJson: "{\"inverse\":true}")
            try event.insert(connection)
        }
        let before = try queue.read { connection in
            try (Row.fetchAll(connection, sql: "SELECT * FROM files"), Row.fetchAll(connection, sql: "SELECT * FROM events"))
        }
        try migrator.migrate(queue)
        try queue.read { connection in
            XCTAssertEqual(try Row.fetchAll(connection, sql: "SELECT * FROM files"), before.0)
            XCTAssertEqual(try Row.fetchAll(connection, sql: "SELECT * FROM events"), before.1)
        }
    }

    func testLandedMarkerMigrationKeepsAnAttemptWithoutAnErrorPossiblyLanded() throws {
        let queue = try DatabaseQueue()
        let migrator = LibraryDatabase.makeMigrator()
        try migrator.migrate(queue, upTo: "013_add_durable_serato_queue")
        let rows: [(attempts: Int, lastError: String?)] = [(1, nil), (1, "Write failed"), (0, nil)]
        try queue.write { connection in
            for (eventID, row) in rows.enumerated() {
                try connection.execute(sql: """
                INSERT INTO serato_write_queue (event_id, kind, file_id, membership_revision, payload, attempts, last_error, created_at)
                VALUES (?, 'metadataUpdate', 1, 1, x'00', ?, ?, 1)
                """, arguments: [eventID, row.attempts, row.lastError])
            }
        }
        try migrator.migrate(queue)
        let landed = try queue.read { connection in
            try Bool.fetchAll(connection, sql: "SELECT may_have_landed FROM serato_write_queue ORDER BY event_id")
        }
        XCTAssertEqual(landed, [true, false, false], "An attempt interrupted before it recorded an error may have landed")
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
