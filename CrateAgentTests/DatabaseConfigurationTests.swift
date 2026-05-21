@testable import CrateAgent
import GRDB
import XCTest

final class DatabaseConfigurationTests: XCTestCase {
    func testAppliesSynchronousNormal() async throws {
        let database = try LibraryDatabase.openInMemory()
        let value: Int = try await database.writer.read { connection in
            try Int.fetchOne(connection, sql: "PRAGMA synchronous") ?? -1
        }
        // SQLite reports synchronous mode numerically:
        // 0 = OFF, 1 = NORMAL, 2 = FULL, 3 = EXTRA.
        XCTAssertEqual(value, 1, "Expected PRAGMA synchronous = NORMAL")
    }

    func testAppliesTempStoreMemory() async throws {
        let database = try LibraryDatabase.openInMemory()
        let value: Int = try await database.writer.read { connection in
            try Int.fetchOne(connection, sql: "PRAGMA temp_store") ?? -1
        }
        // 0 = DEFAULT, 1 = FILE, 2 = MEMORY.
        XCTAssertEqual(value, 2, "Expected PRAGMA temp_store = MEMORY")
    }

    func testAppliesNonDefaultCacheSize() async throws {
        let database = try LibraryDatabase.openInMemory()
        let value: Int = try await database.writer.read { connection in
            try Int.fetchOne(connection, sql: "PRAGMA cache_size") ?? 0
        }
        // We set -8000 (8 MB). SQLite reports negative values
        // verbatim when the unit is KiB; the exact value matters
        // less than confirming the connection isn't on the default.
        XCTAssertEqual(value, -8000)
    }

    func testKeepsForeignKeysOnByDefault() async throws {
        // GRDB enables foreign_keys for every new connection
        // automatically. Pin that contract here: if a future
        // Configuration change disables it, every ON DELETE
        // SET NULL cascade in the schema silently stops working.
        let database = try LibraryDatabase.openInMemory()
        let value: Int = try await database.writer.read { connection in
            try Int.fetchOne(connection, sql: "PRAGMA foreign_keys") ?? -1
        }
        XCTAssertEqual(value, 1)
    }
}
