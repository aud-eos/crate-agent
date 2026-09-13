import Foundation
import GRDB

/// One row in the `events` table — a single state change applied
/// through the OperationEngine's `applyMutation` primitive.
///
/// The table is append-only and serves two queries:
///   Undo: WHERE batch_id = ? ORDER BY event_id DESC
///   History: WHERE file_id = ? (or track_id = ?) ORDER BY timestamp DESC
///
/// Every mutation writes both a forward `payloadJson` (what we did) and
/// an `inversePayloadJson` (how to undo it). Without the inverse, undo
/// breaks; without the event itself, history breaks. Both fields are
/// load-bearing per the project's event-sourcing invariant.
public struct EventRecord: Codable, FetchableRecord, MutablePersistableRecord,
    Hashable, Identifiable {

    public static let databaseTableName = "events"
    public static let databaseColumnDecodingStrategy =
        DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy =
        DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var eventId: Int64?
    public var batchId: String
    public var timestamp: Int64
    public var fileId: Int64?
    public var trackId: Int64?
    public var eventType: EventType
    public var payloadJson: String
    public var inversePayloadJson: String

    public var id: Int64? { eventId }

    public init(
        eventId: Int64? = nil,
        batchId: String,
        timestamp: Int64,
        fileId: Int64? = nil,
        trackId: Int64? = nil,
        eventType: EventType,
        payloadJson: String,
        inversePayloadJson: String
    ) {
        self.eventId = eventId
        self.batchId = batchId
        self.timestamp = timestamp
        self.fileId = fileId
        self.trackId = trackId
        self.eventType = eventType
        self.payloadJson = payloadJson
        self.inversePayloadJson = inversePayloadJson
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        eventId = inserted.rowID
    }
}

/// Discrete event types written to the log. Add a new case here when a
/// new mutation type lands in OperationEngine (e.g. `setTagField` in
/// SP-1.5, `applyMusicBrainzMatch` in SP-2). The string value is the
/// stored representation; it must stay stable across releases — never
/// rename a case after it has appeared in a shipped database.
public enum EventType: String, Codable, DatabaseValueConvertible,
    Hashable, Sendable {
    case trackImported = "track_imported"
    case fileRenamed = "file_renamed"
    case fileRemoved = "file_removed"
    case metadataSet = "metadata_set"
    case metadataCommittedToSerato = "metadata_committed_to_serato"
    case trackAddedToSerato = "track_added_to_serato"
    case fileTagsWritten = "file_tags_written"
    case fileTrashed = "file_trashed"
    case trackRemovedFromSerato = "track_removed_from_serato"
    case fileRemovedFromCrates = "file_removed_from_crates"
    case musicBrainzMatchApplied = "music_brainz_match_applied"
    case musicBrainzMatchReverted = "music_brainz_match_reverted"
}
