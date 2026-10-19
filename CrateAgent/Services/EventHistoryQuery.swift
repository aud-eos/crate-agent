import Foundation
import GRDB

/// A user-visible roll-up of a batch from the `events` table. One
/// row in the History view = one `BatchSummary`. The summary is a
/// pure projection of the underlying event rows: `description` and
/// `canUndo` are derived from the set of `EventType` values, not
/// stored anywhere.
public struct BatchSummary: Sendable, Equatable, Identifiable {
    public var id: String {
        batchId
    }

    public let batchId: String
    public let firstTimestampMillis: Int64
    public let eventCount: Int
    /// Human-readable summary like "Renamed 1 file · Updated metadata
    /// for 2 files". Built from per-event-type counts.
    public let description: String
    /// Why `OperationEngine.undoBatch` can't undo the batch today, or nil
    /// when it can: an event type with no supported inverse, or a removal
    /// journaled before removals were undoable. Disables the Undo button.
    public let undoUnavailableReason: String?
    public var canUndo: Bool {
        undoUnavailableReason == nil
    }

    /// `true` when the batch id starts with `undo:` — i.e., this
    /// batch was itself produced by an undoBatch call. Surfaced so
    /// the UI can label "Undo of …" rows differently if desired.
    public let isUndoBatch: Bool
    /// `true` when `OperationEngine.discardQueuedChange` produced this batch.
    public let isDiscardBatch: Bool
    /// `true` when at least one event in the batch projects onto
    /// Serato/audio-file writes that `resyncSeratoForBatch` can replay
    /// (`EventType.hasReplayableSeratoProjection`). Drives the "Re-sync
    /// Serato" button visibility. Previously this tracked only renames, which
    /// left an Auto-Tag-only batch whose external writes partially failed with
    /// no reachable recovery once the user navigated away from the review
    /// panel (finding #3999114447) — the recovery is idempotent, so exposing
    /// it for every re-syncable batch is safe.
    public let canResync: Bool
    /// Queued Serato or audio-tag changes from this batch that were recorded
    /// as not applied (`serato_write_dispositions`).
    public let notApplied: NotAppliedSummary
    /// This batch's queued changes that cannot apply, one per file: a write
    /// failed, or waits behind one that did. Each can be discarded.
    public let stuckChanges: [QueuedSeratoChange]

    public var timestamp: Date {
        Date(timeIntervalSince1970: TimeInterval(firstTimestampMillis) / 1000)
    }
}

/// Why a batch's queued changes were not applied, for its History row.
public struct NotAppliedSummary: Sendable, Equatable {
    public static let none = NotAppliedSummary(changeCount: 0, fileCount: 0, resolvedChangeCount: 0, listedFileCount: 0, reasons: [])

    /// Distinct changes still not applied, each counted once.
    public let changeCount: Int
    /// Distinct files those changes touch.
    public let fileCount: Int
    /// Changes recorded as not applied that a later write, such as a
    /// Re-sync, applied.
    public let resolvedChangeCount: Int
    /// Entries `EventHistoryQuery.loadNotAppliedFiles` lists: every file with
    /// a recorded change, open or resolved.
    public let listedFileCount: Int
    /// One plain-language line per disposition of the open changes, with its count.
    public let reasons: [String]

    public var hasRecordedChanges: Bool {
        changeCount + resolvedChangeCount > 0
    }
}

/// One file whose queued changes in a batch were recorded as not applied.
public struct NotAppliedFile: Sendable, Equatable, Identifiable {
    public var id: String {
        fileID.map { fileID in "file:\(fileID)" } ?? "event:\(firstEventID)"
    }

    /// Nil when the change's event names no file.
    public let fileID: Int64?
    let firstEventID: Int64
    let cursor: NotAppliedFileCursor
    /// Nil when the file is no longer in the library.
    public let path: String?
    /// Why each of the file's open changes was not applied.
    public let reasons: [String]
    /// `true` when later writes applied every recorded change.
    public var isResolved: Bool {
        reasons.isEmpty
    }

    /// `true` when re-syncing this file through
    /// `OperationEngine.resyncSeratoForBatch(_:fileID:)` can replay its
    /// changes: the batch is re-syncable, some change is still open, and the
    /// file's events project onto Serato or audio-tag writes.
    public let canResync: Bool
}

public enum EventHistoryQuery {
    public static let notAppliedFilePageSize = 50

    /// One page of the files `batch`'s not-applied changes touch, with each
    /// file's open reasons, resuming after `after`, the last file of the
    /// previous page. A page shorter than `limit` is the last one. Loaded
    /// only when the History row is expanded.
    public static func loadNotAppliedFiles(for batch: BatchSummary, database: LibraryDatabase,
                                           limit: Int = notAppliedFilePageSize, after: NotAppliedFile? = nil) async throws -> [NotAppliedFile]
    {
        precondition(limit > 0)
        let batchID = batch.batchId
        let cursor = after?.cursor
        let records = try await database.writer.read { db in
            try SeratoWriteDispositions.notAppliedFiles(batchID: batchID, after: cursor, limit: limit, in: db)
        }
        return records.map { record in
            let open = reasons(record.byDisposition)
            return NotAppliedFile(fileID: record.fileID, firstEventID: record.firstEventID, cursor: record.cursor, path: record.path, reasons: open,
                                  canResync: batch.canResync && !open.isEmpty && record.fileID != nil && record.path != nil
                                      && canResyncBatch(typeList: record.eventTypes))
        }
    }

    static func notAppliedSummary(_ counts: NotAppliedBatchCounts?) -> NotAppliedSummary {
        guard let counts else { return .none }
        return NotAppliedSummary(changeCount: counts.changes, fileCount: counts.files, resolvedChangeCount: counts.resolvedChanges,
                                 listedFileCount: counts.listedFiles, reasons: reasons(counts.byDisposition))
    }

    private static func reasons(_ counts: SeratoWriteDispositionCounts) -> [String] {
        let known = SeratoWriteDisposition.allCases.filter { disposition in counts[disposition] > 0 }
            .map { disposition in SeratoWriteDispositionMessages.summary(disposition, count: counts[disposition]) }
        return known + (counts.unrecognized > 0 ? [SeratoWriteDispositionMessages.unrecognizedSummary(count: counts.unrecognized)] : [])
    }

    static func loadFileHistory(fileID: Int64, in database: GRDB.Database, limit: Int = 200, offset: Int = 0) throws -> [EventRecord] {
        precondition(limit > 0 && offset >= 0)
        return try EventRecord.filter(Column("file_id") == fileID)
            .order(Column("timestamp").desc, Column("event_id").desc)
            .limit(limit, offset: offset)
            .fetchAll(database)
    }

    static func fileEventDescription(_ event: EventRecord) throws -> String {
        if event.eventType == .fileLibraryStateChanged {
            let payload = try JSONDecoder().decode(SetFileLibraryStatePayload.self, from: Data(event.payloadJson.utf8))
            return "\(payload.state.membership.displayTitle) · \(payload.state.availability.displayTitle)"
        }
        return phrase(for: event.eventType, count: 1)
    }

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
            let eventTypes: String // comma-separated EventType raw values
            let eventCount: Int
            let hasLegacyRemoval: Bool
        }

        // GROUP BY batch_id; for each batch capture earliest timestamp,
        // total event count, and a delimited list of event types so
        // we can derive the description in Swift.
        let sql = """
        SELECT
            batch_id AS batchId,
            MIN(timestamp) AS firstTimestamp,
            GROUP_CONCAT(event_type) AS eventTypes,
            COUNT(*) AS eventCount,
            MAX(CASE WHEN event_type IN (\(legacyRemovalTypes))
                THEN COALESCE(json_extract(inverse_payload_json, '$.reason') = ?, 0) ELSE 0 END) AS hasLegacyRemoval
        FROM events
        GROUP BY batch_id
        ORDER BY MIN(timestamp) DESC
        LIMIT ?
        """

        let (rows, notApplied, stuck): ([Row], [String: NotAppliedBatchCounts], [QueuedSeratoChange]) = try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [OperationEngine.NonUndoableInverse.reasonValue, limit])
            return try (rows, SeratoWriteDispositions.notAppliedByBatch(rows.map(\.batchId), in: db), QueuedSeratoChanges.stuck(in: db))
        }
        let stuckByBatch = Dictionary(grouping: stuck, by: \.batchID)

        let allBatchIds = Set(rows.map(\.batchId))
        return rows.map { row in
            let typeList = row.eventTypes.split(separator: ",").map(String.init)
            let typeCounts = countOccurrences(in: typeList)
            return BatchSummary(
                batchId: row.batchId,
                firstTimestampMillis: row.firstTimestamp,
                eventCount: row.eventCount,
                description: describeBatch(typeCounts: typeCounts),
                undoUnavailableReason: row.hasLegacyRemoval ? RemovalUndoMessages.legacyRemovalNotUndoable
                    : canUndoBatch(typeList: typeList) ? nil : HistoryMessages.undoUnsupported,
                isUndoBatch: row.batchId.hasPrefix("undo:"),
                isDiscardBatch: row.batchId.hasPrefix(OperationEngine.discardBatchPrefix),
                canResync: canResyncBatch(typeList: typeList)
                    && !batchHasBeenUndone(row.batchId, allBatchIds: allBatchIds),
                notApplied: notAppliedSummary(notApplied[row.batchId]),
                stuckChanges: stuckByBatch[row.batchId] ?? []
            )
        }
    }

    /// Removals journaled before this version carry the non-undoable sentinel
    /// inverse; only their types can, so only they are decoded as JSON.
    private static let legacyRemovalTypes = [EventType.fileTrashed, .trackRemovedFromSerato, .fileRemovedFromCrates]
        .map { eventType in "'\(eventType.rawValue)'" }.joined(separator: ", ")

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
        // Mirror OperationEngine.decodeInverseMutation: these event types
        // have no inverse it accepts. Observations and import requests
        // record state rather than change it, `trackAddedToSerato` has no
        // inverse yet, and the two removal-restore types refuse redo.
        let unsupportedRaw: Set<String> = [
            EventType.trackAddedToSerato.rawValue,
            EventType.fileLocationObserved.rawValue,
            EventType.fileIdentityObserved.rawValue,
            EventType.fileModificationTimeRecorded.rawValue,
            EventType.fileLibraryStateChanged.rawValue,
            EventType.fileImportRequested.rawValue,
            // Redo of an undone removal is #270.
            EventType.fileRestoredFromTrash.rawValue,
            EventType.seratoRecordsRestored.rawValue,
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
            if counts[eventType] == nil {
                seen.append(eventType)
            }
            counts[eventType, default: 0] += 1
        }
        return seen.map { ($0, counts[$0]!) }
    }

    private static func phrase(for eventType: EventType, count: Int) -> String {
        let pluralS = count == 1 ? "" : "s"
        switch eventType {
        case .fileLocationObserved:
            return "Observed location for \(count) file\(pluralS)"
        case .fileIdentityObserved:
            return "Observed identity for \(count) file\(pluralS)"
        case .fileModificationTimeRecorded:
            return "Recorded precise modification time for \(count) file\(pluralS)"
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
        case .fileRestoredFromTrash:
            return RemovalUndoMessages.restoredFromTrashPhrase(count: count)
        case .seratoRecordsRestored:
            return RemovalUndoMessages.recordsRestoredPhrase(count: count)
        case .trackAddedToSerato:
            return "Added \(count) track\(pluralS) to Serato"
        case .musicBrainzMatchApplied:
            return "Applied MusicBrainz match to \(count) track\(pluralS)"
        case .musicBrainzMatchReverted:
            return "Reverted MusicBrainz match on \(count) track\(pluralS)"
        case .songFamilyCreated:
            return "Created \(songFamilies(count))"
        case .songFamilyMembersAttached:
            return "Added versions to \(songFamilies(count))"
        case .songFamilyMembersDetached:
            return "Removed versions from \(songFamilies(count))"
        case .songFamiliesMerged:
            return "Merged song families into \(songFamilies(count))"
        case .songFamilySplit:
            return "Split \(songFamilies(count))"
        case .songFamilyRepresentativeChanged:
            return "Changed the main version of \(songFamilies(count))"
        case .songFamilyRestored:
            return "Restored \(songFamilies(count))"
        case .songFamilyRecordingLinked:
            return "Linked \(count) file\(pluralS) to \(count == 1 ? "its recording" : "their recordings") for grouping"
        case .songFamilyRecordingUnlinked:
            return "Unlinked \(count) file\(pluralS) from \(count == 1 ? "its grouping recording" : "their grouping recordings")"
        case .duplicateLabelsKeptBoth:
            return "Kept every copy in \(count) duplicate group\(pluralS) whose labels disagree"
        case .duplicateLabelsReopened:
            return "Reopened label review for \(count) duplicate group\(pluralS)"
        case .queuedSeratoChangeDiscarded:
            return QueuedChangeDiscardMessages.batchPhrase(count: count)
        case .recordingSeparated:
            return "Gave \(count) file\(pluralS) a recording of \(count == 1 ? "its" : "their") own"
        case .recordingSeparatedForGrouping:
            return "Gave \(count) file\(pluralS) a recording of \(count == 1 ? "its" : "their") own for grouping"
        case .recordingRejoined:
            return "Returned \(count) file\(pluralS) to \(count == 1 ? "its" : "their") shared recording"
        case .musicBrainzWorkRecorded:
            return MusicBrainzWorkMessages.recordedPhrase(count: count)
        case .musicBrainzWorkCleared:
            return MusicBrainzWorkMessages.clearedPhrase(count: count)
        case .keeperMarked:
            return HistoryMessages.keeperMarkedPhrase(count: count)
        case .keeperCleared:
            return HistoryMessages.keeperClearedPhrase(count: count)
        }
    }

    private static func songFamilies(_ count: Int) -> String {
        count == 1 ? "1 song family" : "\(count) song families"
    }
}
