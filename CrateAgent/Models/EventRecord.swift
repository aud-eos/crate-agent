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
    Hashable, Identifiable
{
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

    public var id: Int64? {
        eventId
    }

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
    Hashable, Sendable
{
    case fileLocationObserved = "file_location_observed"
    case fileIdentityObserved = "file_identity_observed"
    case fileModificationTimeRecorded = "file_modification_time_recorded"
    case fileLibraryStateChanged = "file_library_state_changed"
    case fileImportRequested = "file_import_requested"
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
    case fileRestoredFromTrash = "file_restored_from_trash"
    case seratoRecordsRestored = "serato_records_restored"
    case musicBrainzMatchApplied = "music_brainz_match_applied"
    case musicBrainzMatchReverted = "music_brainz_match_reverted"
    case songFamilyCreated = "song_family_created"
    case songFamilyMembersAttached = "song_family_members_attached"
    case songFamilyMembersDetached = "song_family_members_detached"
    case songFamiliesMerged = "song_families_merged"
    case songFamilySplit = "song_family_split"
    case songFamilyRepresentativeChanged = "song_family_representative_changed"
    case songFamilyRestored = "song_family_restored"
    case songFamilyRecordingLinked = "song_family_recording_linked"
    case songFamilyRecordingUnlinked = "song_family_recording_unlinked"
    case duplicateLabelsKeptBoth = "duplicate_labels_kept_both"
    case duplicateLabelsReopened = "duplicate_labels_reopened"
    case queuedSeratoChangeDiscarded = "queued_serato_change_discarded"
    case recordingSeparated = "recording_separated"
    case recordingSeparatedForGrouping = "recording_separated_for_grouping"
    case recordingRejoined = "recording_rejoined"
    case musicBrainzWorkRecorded = "music_brainz_work_recorded"
    case musicBrainzWorkCleared = "music_brainz_work_cleared"
    case keeperMarked = "keeper_marked"
    case keeperCleared = "keeper_cleared"

    /// Whether this event type projects onto Serato/audio-file writes that
    /// `OperationEngine.resyncSeratoForBatch` can idempotently replay from the
    /// journal. The single source of truth for "is a batch re-syncable": the
    /// engine's `resyncWrites` reconstructs exactly these types, and
    /// `EventHistoryQuery` uses this to decide whether to offer History's
    /// "Re-sync Serato" recovery action (so a partial-apply of an
    /// Auto-Tag-only batch stays recoverable after navigation — finding
    /// #3999114447). Exhaustive on purpose: a new event type must declare
    /// whether it has a replayable Serato projection.
    public var hasReplayableSeratoProjection: Bool {
        switch self {
        case .fileRenamed, .musicBrainzMatchApplied, .metadataCommittedToSerato,
             .fileTagsWritten, .musicBrainzMatchReverted:
            // `musicBrainzMatchReverted` is replayable too: an undo commits its
            // SQLite revert + event before the audio-tag restore write, so if
            // that write throws mid-`undoBatch` the file/Serato keep the applied
            // metadata with no recovery unless the reverted event can be
            // re-synced (finding #3999974011).
            true
        case .trackImported, .fileRemoved, .metadataSet, .trackAddedToSerato,
             .fileTrashed, .trackRemovedFromSerato, .fileRemovedFromCrates, .fileRestoredFromTrash, .seratoRecordsRestored, .fileLibraryStateChanged, .fileLocationObserved, .fileIdentityObserved, .fileModificationTimeRecorded, .fileImportRequested,
             .songFamilyCreated, .songFamilyMembersAttached, .songFamilyMembersDetached, .songFamiliesMerged,
             .songFamilySplit, .songFamilyRepresentativeChanged, .songFamilyRestored,
             .songFamilyRecordingLinked, .songFamilyRecordingUnlinked,
             .duplicateLabelsKeptBoth, .duplicateLabelsReopened, .queuedSeratoChangeDiscarded,
             .recordingSeparated, .recordingSeparatedForGrouping, .recordingRejoined,
             .musicBrainzWorkRecorded, .musicBrainzWorkCleared, .keeperMarked, .keeperCleared:
            false
        }
    }
}
