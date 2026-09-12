@testable import CrateAgent
import GRDB
import XCTest

/// The reset migration only has an observable effect on rows that
/// existed with `fingerprint_status = 'done'` *before* it runs. A
/// plain `LibraryDatabase.openInMemory()` applies every migration
/// (including this one) before the test can insert a seed row, so
/// these tests instead migrate a bare queue up to the migration just
/// before this one, seed legacy-shaped rows, then finish migrating
/// and assert the effect -- GRDB's documented pattern for testing a
/// migration's effect on pre-existing data.
final class ResetFingerprintsForAlgorithmTest2MigrationTests: XCTestCase {
    private static let priorMigration = "007_add_musicbrainz_columns"

    func testMigration008ResetsDoneFingerprintsToPending() async throws {
        let queue = try DatabaseQueue()
        let migrator = LibraryDatabase.makeMigrator()
        try migrator.migrate(queue, upTo: Self.priorMigration)

        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO files (
                    path, volume_uuid, inode, file_size, mtime,
                    chromaprint_fingerprint, fingerprint_status
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "/Music/A/track.mp3", "test-volume", 1, 1024, 0,
                    Data([0x01, 0x02, 0x03]), "done",
                ]
            )
        }

        try migrator.migrate(queue)

        let (fingerprint, status): (Data?, String) = try await queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT chromaprint_fingerprint, fingerprint_status
                FROM files WHERE path = ?
                """,
                arguments: ["/Music/A/track.mp3"]
            )!
            return (row["chromaprint_fingerprint"], row["fingerprint_status"])
        }

        XCTAssertNil(fingerprint, "migration should null out TEST1-era fingerprints")
        XCTAssertEqual(status, "pending", "reset rows should be re-queued for fingerprinting")
    }

    func testMigration008LeavesPendingRowsUntouched() async throws {
        let queue = try DatabaseQueue()
        let migrator = LibraryDatabase.makeMigrator()
        try migrator.migrate(queue, upTo: Self.priorMigration)

        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO files (
                    path, volume_uuid, inode, file_size, mtime, fingerprint_status
                )
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["/Music/B/track.mp3", "test-volume", 2, 2048, 0, "pending"]
            )
        }

        try migrator.migrate(queue)

        let status: String = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT fingerprint_status FROM files WHERE path = ?",
                arguments: ["/Music/B/track.mp3"]
            )!
        }

        XCTAssertEqual(status, "pending")
    }
}
