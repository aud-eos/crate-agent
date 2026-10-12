import GRDB
import XCTest
@testable import CrateAgent

final class EventsBatchAggIndexTests: XCTestCase {

    func testIndexExistsAfterMigration() async throws {
        let database = try LibraryDatabase.openInMemory()
        let exists: Bool = try await database.writer.read { connection in
            let row = try Row.fetchOne(
                connection,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'events_batch_agg'"
            )
            return row != nil
        }
        XCTAssertTrue(exists, "Migration should create the events_batch_agg index")
    }

    func testIndexCoversBatchAggregationQuery() async throws {
        // EXPLAIN QUERY PLAN should show SQLite using the new index
        // for the History panel's GROUP BY query — not a full-table
        // scan and not a temp B-tree to satisfy the GROUP BY.
        let database = try LibraryDatabase.openInMemory()
        let planDetail: String = try await database.writer.read { connection in
            let rows = try Row.fetchAll(
                connection,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT
                        batch_id,
                        MIN(timestamp),
                        GROUP_CONCAT(event_type),
                        COUNT(*)
                    FROM events
                    GROUP BY batch_id
                    ORDER BY MIN(timestamp) DESC
                    LIMIT ?
                    """,
                arguments: [200]
            )
            return rows
                .compactMap { $0["detail"] as String? }
                .joined(separator: " | ")
        }
        XCTAssertFalse(planDetail.isEmpty, "EXPLAIN QUERY PLAN returned no rows")
        // The strongest guarantee: SQLite walks the index leaves and
        // never reads the events table rows. "COVERING INDEX" means
        // payload_json / inverse_payload_json — the two largest
        // columns — are never touched. Anything weaker (e.g.
        // "SCAN events" without the covering-index suffix) means
        // SQLite still reads row data and the win is reduced.
        XCTAssertTrue(
            planDetail.contains("COVERING INDEX events_batch_agg"),
            "Plan should use events_batch_agg as a covering index; got: \(planDetail)"
        )
    }
}
