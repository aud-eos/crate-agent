import Foundation
import GRDB

/// Composite index covering the History panel's batch-aggregation
/// query in `EventHistoryQuery.loadRecentBatches`:
///
/// ```sql
/// SELECT batch_id, MIN(timestamp), GROUP_CONCAT(event_type), COUNT(*)
/// FROM events
/// GROUP BY batch_id
/// ORDER BY MIN(timestamp) DESC
/// LIMIT ?
/// ```
///
/// Without this index SQLite must full-scan `events` to satisfy the
/// GROUP BY, which means reading every row including `payload_json`
/// and `inverse_payload_json` — the two largest columns, each
/// carrying a complete JSON object per event. The events table is
/// append-only and grows unbounded; the History panel gets
/// proportionally slower with every mutation forever.
///
/// With `(batch_id, timestamp, event_type)` the aggregation is
/// satisfied entirely from index leaf pages: SQLite walks the index
/// in batch_id order, finds the MIN(timestamp) per group from the
/// second column, builds the GROUP_CONCAT from the third, and
/// counts entries — never touching the row data.
enum AddEventsBatchAggIndexMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("006_add_events_batch_agg_index") { db in
            try db.create(
                index: "events_batch_agg",
                on: "events",
                columns: ["batch_id", "timestamp", "event_type"]
            )
        }
    }
}
