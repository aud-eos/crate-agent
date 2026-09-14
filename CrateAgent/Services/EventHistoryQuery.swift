import Foundation
import GRDB

/// A user-visible roll-up of a batch from the `events` table. One
/// row in the History view = one `BatchSummary`. The summary is a
/// pure projection of the underlying event rows: `description` and
/// `canUndo` are derived from the set of `EventType` values, not
/// stored anywhere.
public struct BatchSummary: Sendable, Equatable, Identifiable {

    public var id: String { batchId }
    public let batchId: String
    public let firstTimestampMillis: Int64
    public let eventCount: Int
    /// Human-readable summary like "Renamed 1 file · Updated metadata
    /// for 2 files". Built from per-event-type counts.
    public let description: String
    /// `false` when the batch contains any event whose inverse isn't
    /// supported by `OperationEngine.undoBatch` today (`trackAddedToSerato`,
    /// `metadataCommittedToSerato`). Used to disable the Undo button.
    public let canUndo: Bool
    /// `true` when the batch id starts with `undo:` — i.e., this
    /// batch was itself produced by an undoBatch call. Surfaced so
    /// the UI can label "Undo of …" rows differently if desired.
    public let isUndoBatch: Bool
    /// `true` when at least one event in the batch projects onto
    /// Serato/audio-file writes that `resyncSeratoForBatch` can replay
    /// (`EventType.hasReplayableSeratoProjection`). Drives the "Re-sync
    /// Serato" button visibility. Previously this tracked only renames, which
    /// left an Auto-Tag-only batch whose external writes partially failed with
    /// no reachable recovery once the user navigated away from the review
    /// panel (finding #3999114447) — the recovery is idempotent, so exposing
    /// it for every re-syncable batch is safe.
    public let canResync: Bool

    public var timestamp: Date {
        Date(timeIntervalSince1970: TimeInterval(firstTimestampMillis) / 1000)
    }
}

public enum EventHistoryQuery {

    /// Read the most-recent `limit` batches from the `events` table,
    /// newest-first by earliest event timestamp.
    ///
    /// The implementation pulls the recent events in one pass and
    /// builds summaries client-side rather than running an aggregate
    /// SQL query — for a few hundred batches this is fast, keeps the
    /// derivation logic in Swift where it's testable, and avoids
    /// duplicating the EventType-to-description map between Swift
    /// and SQL.
    public static func loadRecentBatches(
        database: LibraryDatabase,
        limit: Int = 200
    ) async throws -> [BatchSummary] {
        struct Row: FetchableRecord, Decodable {
            let batchId: String
            let firstTimestamp: Int64
            let eventTypes: String   // comma-separated EventType raw values
            let eventCount: Int
        }

        // GROUP BY batch_id; for each batch capture earliest timestamp,
        // total event count, and a delimited list of event types so
        // we can derive the description in Swift.
        let sql = """
            SELECT
                batch_id AS batchId,
                MIN(timestamp) AS firstTimestamp,
                GROUP_CONCAT(event_type) AS eventTypes,
                COUNT(*) AS eventCount
            FROM events
            GROUP BY batch_id
            ORDER BY MIN(timestamp) DESC
            LIMIT ?
            """

        let rows: [Row] = try await database.writer.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [limit])
        }

        let allBatchIds = Set(rows.map(\.batchId))
        return rows.map { row in
            let typeList = row.eventTypes.split(separator: ",").map(String.init)
            let typeCounts = countOccurrences(in: typeList)
            return BatchSummary(
                batchId: row.batchId,
                firstTimestampMillis: row.firstTimestamp,
                eventCount: row.eventCount,
                description: describeBatch(typeCounts: typeCounts),
                canUndo: canUndoBatch(typeList: typeList),
                isUndoBatch: row.batchId.hasPrefix("undo:"),
                canResync: canResyncBatch(typeList: typeList)
                    && !batchHasBeenUndone(row.batchId, allBatchIds: allBatchIds)
            )
        }
    }

    /// A batch has been undone when an `undo:<batchId>:<uuid>` batch exists for
    /// it. Offering Re-sync on such a batch would replay its old forward writes
    /// over the reverted state (finding #3999974013), so it's not eligible. The
    /// undo batch itself remains eligible — that's how a failed tag-restore mid-
    /// undo is recovered.
    static func batchHasBeenUndone(_ batchId: String, allBatchIds: Set<String>) -> Bool {
        let undoPrefix = "undo:\(batchId):"
        return allBatchIds.contains { $0.hasPrefix(undoPrefix) }
    }

    // MARK: - Pure derivations (extracted for testing)

    static func describeBatch(typeCounts: [(EventType, Int)]) -> String {
        if typeCounts.isEmpty {
            return "Empty batch"
        }
        return typeCounts
            .map { phrase(for: $0.0, count: $0.1) }
            .joined(separator: " · ")
    }

    static func canUndoBatch(typeList: [String]) -> Bool {
        // Mirror OperationEngine.decodeInverseMutation's whitelist.
        // `metadataCommittedToSerato` was on this list before SP-1.5
        // landed undo-aware commits — every production caller today
        // (the hygiene runner) supplies `previousMetadata`, so the
        // engine accepts the inverse. Only `trackAddedToSerato`
        // remains unconditionally unsupported (it needs a Rust-side
        // removeTrackFromSerato FFI we don't have yet).
        let unsupportedRaw: Set<String> = [
            EventType.trackAddedToSerato.rawValue,
            EventType.fileLocationObserved.rawValue,
            EventType.fileLibraryStateChanged.rawValue,
            EventType.fileImportRequested.rawValue,
            EventType.fileTrashed.rawValue,
            EventType.trackRemovedFromSerato.rawValue,
            EventType.fileRemovedFromCrates.rawValue,
        ]
        return !typeList.contains(where: unsupportedRaw.contains)
    }

    /// A batch is re-syncable when at least one of its events projects onto
    /// Serato/audio-file writes that `resyncSeratoForBatch` can idempotently
    /// replay — the same set the engine reconstructs. Unknown raw values
    /// (from a newer schema) are conservatively ignored.
    static func canResyncBatch(typeList: [String]) -> Bool {
        typeList.contains { raw in
            EventType(rawValue: raw)?.hasReplayableSeratoProjection ?? false
        }
    }

    private static func countOccurrences(in typeRawValues: [String]) -> [(EventType, Int)] {
        // Preserve first-seen order so the rendered description is
        // deterministic — important for snapshot-style assertions
        // and for the user, who'd be surprised if the same batch
        // displayed differently across reloads.
        var seen: [EventType] = []
        var counts: [EventType: Int] = [:]
        for raw in typeRawValues {
            guard let eventType = EventType(rawValue: raw) else { continue }
            if counts[eventType] == nil { seen.append(eventType) }
            counts[eventType, default: 0] += 1
        }
        return seen.map { ($0, counts[$0]!) }
    }

    private static func phrase(for eventType: EventType, count: Int) -> String {
        let pluralS = count == 1 ? "" : "s"
        switch eventType {
        case .fileLocationObserved:
            return "Observed location for \(count) file\(pluralS)"
        case .fileLibraryStateChanged:
            return "Observed library state for \(count) file\(pluralS)"
        case .fileImportRequested:
            return "Requested import for \(count) file\(pluralS)"
        case .trackImported:
            return "Imported \(count) track\(pluralS)"
        case .fileRenamed:
            return "Renamed \(count) file\(pluralS)"
        case .fileRemoved:
            return "Removed \(count) file\(pluralS)"
        case .metadataSet:
            return "Updated metadata for \(count) file\(pluralS)"
        case .metadataCommittedToSerato:
            return "Committed metadata to Serato for \(count) file\(pluralS)"
        case .fileTagsWritten:
            return "Wrote audio tags on \(count) file\(pluralS)"
        case .fileTrashed:
            return "Moved \(count) file\(pluralS) to Trash"
        case .trackRemovedFromSerato:
            return "Removed \(count) track\(pluralS) from Serato's database"
        case .fileRemovedFromCrates:
            return "Removed \(count) file\(pluralS) from Serato crates"
        case .trackAddedToSerato:
            return "Added \(count) track\(pluralS) to Serato"
        case .musicBrainzMatchApplied:
            return "Applied MusicBrainz match to \(count) track\(pluralS)"
        case .musicBrainzMatchReverted:
            return "Reverted MusicBrainz match on \(count) track\(pluralS)"
        }
    }
}
