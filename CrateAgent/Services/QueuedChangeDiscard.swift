import Foundation
import GRDB

/// One History batch's queued Serato and audio-tag writes for one file.
public struct QueuedSeratoChange: Sendable, Equatable, Identifiable {
    public var id: String {
        "\(batchID):\(fileID)"
    }

    public let batchID: String
    public let fileID: Int64
    public let path: String
    /// The error a row of this change last failed with; nil when the change
    /// only waits behind another that failed.
    public let failure: String?
}

/// One value a discard puts back.
public struct DiscardedFieldChange: Sendable, Equatable, Hashable {
    public let field: String
    public let discarded: String
    public let restored: String
}

/// What `OperationEngine.discardQueuedChange(batchID:fileID:)` would do.
public struct QueuedChangeDiscardPreview: Sendable, Equatable {
    public let change: QueuedSeratoChange
    public let fieldChanges: [DiscardedFieldChange]
    /// Some of the change may already have reached Serato or the audio file,
    /// so the revert queues a write of the old values back.
    public let writesBackOldValues: Bool
    /// Later queued changes the drain holds behind this one. The discard is
    /// refused until they are discarded first.
    public let laterChanges: [QueuedSeratoChange]
}

/// A queued row as the discard confirmation read it. The discard commits
/// only while every row still matches, so a retry or reduction between the
/// confirmation and the commit cannot be discarded unseen.
struct DiscardedSeratoWrite: Codable, Sendable, Equatable {
    let queueID: Int64
    let eventID: Int64
    let membershipRevision: Int64
    let queued: SeratoQueuedWritePayload
    let attempts: Int
    let mayHaveLanded: Bool

    init(_ row: GuardedSeratoWrite) throws {
        guard let queueID = row.queueID else { throw OperationEngineError.insertDidNotReturnRowId }
        self.queueID = queueID
        eventID = row.eventId
        membershipRevision = row.token.revision
        queued = SeratoWriteQueue.payload(of: row)
        attempts = row.attempts
        mayHaveLanded = row.mayHaveLanded
    }
}

/// Drops one batch's queued writes for one file. Its batch also holds the
/// inverses of the change's events, which revert it; undoing that batch
/// applies their inverses, which queue the change again, so this event
/// needs no inverse of its own and its inverse payload repeats what it dropped.
public struct DiscardQueuedSeratoChangePayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    let expectedRevision: Int64
    let discardedBatchID: String
    let revertedEventIDs: [Int64]
    let writes: [DiscardedSeratoWrite]
}

enum QueuedChangeDiscardMutation {
    static func apply(_ payload: DiscardQueuedSeratoChangePayload, batchId: String, timestamp: Int64, in database: Database) throws -> Int64 {
        guard let file = try FileRecord.fetchOne(database, key: payload.fileId), file.membershipRevision == payload.expectedRevision else {
            throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
        }
        let rows = try SeratoWriteQueue.fetch(eventIDs: payload.revertedEventIDs, in: database)
        guard try rows.map(DiscardedSeratoWrite.init) == payload.writes else {
            throw OperationEngineError.queuedChangeChanged(path: file.path)
        }
        let later = try QueuedSeratoChanges.later(than: rows, in: database)
        guard later.isEmpty else {
            throw OperationEngineError.queuedChangeHasLaterChanges(path: file.path, later: later.map(\.path))
        }
        for row in rows {
            try SeratoWriteQueue.delete(row, in: database)
            try SeratoWriteDispositions.record(eventID: row.eventId, kind: row.write.kind, disposition: .discarded,
                                               detail: QueuedChangeDiscardMessages.dispositionDetail, reported: true, in: database)
        }
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: payload.fileId, eventType: .queuedSeratoChangeDiscarded,
                                               forwardPayload: payload, inversePayload: payload, in: database)
    }

    /// The queued write kinds an event of `eventType` produces, which its
    /// inverse produces too.
    static func writeKinds(of eventType: EventType) -> Set<SeratoWriteKind> {
        switch eventType {
        case .fileRenamed: [.rename]
        case .metadataCommittedToSerato: [.metadataUpdate]
        case .fileTagsWritten: [.fileTagWrite]
        case .musicBrainzMatchApplied, .musicBrainzMatchReverted: [.metadataUpdate, .fileTagWrite]
        case .trackAddedToSerato: [.addTrack]
        case .trackRemovedFromSerato: [.removeFromDatabase]
        case .fileRemovedFromCrates: [.removeFromCrates]
        case .fileTrashed: [.trashFile]
        case .trackImported, .fileRemoved, .metadataSet, .fileLibraryStateChanged, .fileLocationObserved, .fileIdentityObserved,
             .fileModificationTimeRecorded, .fileImportRequested, .songFamilyCreated, .songFamilyMembersAttached,
             .songFamilyMembersDetached, .songFamiliesMerged, .songFamilySplit, .songFamilyRepresentativeChanged,
             .songFamilyRestored, .songFamilyRecordingLinked, .songFamilyRecordingUnlinked, .duplicateLabelsKeptBoth,
             .duplicateLabelsReopened, .queuedSeratoChangeDiscarded:
            []
        }
    }

    /// The write kinds whose inverse would only repeat what Serato or the
    /// file still holds: the write is queued and never reached its I/O, or
    /// was recorded as not applied. A write that completed, or may have
    /// landed before its process stopped, is written back.
    static func kindsNeedingNoWriteBack(for event: EventRecord, rows: [GuardedSeratoWrite], in database: Database) throws -> Set<SeratoWriteKind> {
        guard let eventID = event.eventId else { return [] }
        let notApplied = try SeratoWriteDispositions.openDispositions(eventID: eventID, in: database)
        return writeKinds(of: event.eventType).filter { kind in
            if let row = rows.first(where: { row in row.eventId == eventID && row.write.kind == kind }) {
                return !row.mayHaveLanded
            }
            return notApplied[kind.rawValue].map { disposition in disposition != SeratoWriteDisposition.interrupted.rawValue } ?? false
        }
    }

    static func fieldChanges(of events: [EventRecord]) throws -> [DiscardedFieldChange] {
        let decoder = JSONDecoder()
        var seen = Set<DiscardedFieldChange>()
        return try events.flatMap { event in try fieldChanges(of: event, decoder: decoder) }.filter { change in seen.insert(change).inserted }
    }

    private static func fieldChanges(of event: EventRecord, decoder: JSONDecoder) throws -> [DiscardedFieldChange] {
        let payload = Data(event.payloadJson.utf8)
        switch event.eventType {
        case .fileRenamed:
            let rename = try decoder.decode(RenameFilePayload.self, from: payload)
            return [DiscardedFieldChange(field: "Location", discarded: rename.newPath, restored: rename.previousPath)]
        case .metadataSet:
            let edit = try decoder.decode(SetMetadataPayload.self, from: payload)
            return changes(edit.metadata, from: edit.previousMetadata, unsetMeansUnchanged: false)
        case .metadataCommittedToSerato:
            let commit = try decoder.decode(CommitMetadataToSeratoPayload.self, from: payload)
            return commit.previousMetadata.map { previous in changes(commit.metadata, from: previous, unsetMeansUnchanged: true) } ?? []
        case .fileTagsWritten:
            let tags = try decoder.decode(WriteFileTagsPayload.self, from: payload)
            return tags.previousMetadata.map { previous in changes(tags.metadata, from: previous, unsetMeansUnchanged: true) } ?? []
        case .musicBrainzMatchApplied:
            return try matchChanges(decoder.decode(ApplyMusicBrainzMatchPayload.self, from: payload))
        case .musicBrainzMatchReverted:
            return try matchChanges(decoder.decode(RevertMusicBrainzMatchPayload.self, from: payload).applied).map { change in
                DiscardedFieldChange(field: change.field, discarded: change.restored, restored: change.discarded)
            }
        case .trackImported, .fileRemoved, .trackAddedToSerato, .fileTrashed, .trackRemovedFromSerato, .fileRemovedFromCrates,
             .fileLibraryStateChanged, .fileLocationObserved, .fileIdentityObserved, .fileModificationTimeRecorded, .fileImportRequested,
             .songFamilyCreated, .songFamilyMembersAttached, .songFamilyMembersDetached, .songFamiliesMerged, .songFamilySplit,
             .songFamilyRepresentativeChanged, .songFamilyRestored, .songFamilyRecordingLinked, .songFamilyRecordingUnlinked,
             .duplicateLabelsKeptBoth, .duplicateLabelsReopened, .queuedSeratoChangeDiscarded:
            return []
        }
    }

    private static func changes(_ metadata: SeratoMetadata, from previous: SeratoMetadata, unsetMeansUnchanged: Bool) -> [DiscardedFieldChange] {
        SeratoMetadata.fields.compactMap { field in
            let value = metadata[keyPath: field.keyPath]
            let earlier = previous[keyPath: field.keyPath]
            guard value != earlier, value != nil || !unsetMeansUnchanged else { return nil }
            return change(field.name, from: earlier, to: value)
        }
    }

    private static func matchChanges(_ match: ApplyMusicBrainzMatchPayload) -> [DiscardedFieldChange] {
        let previous = match.previousMetadata ?? .empty
        let fields: [(String, String?, String?)] = [
            ("artist", previous.artist, match.artist), ("title", previous.title, match.title), ("album", previous.album, match.album),
            ("year", match.previousFileYear.map(String.init), match.year.map(String.init)),
        ]
        return fields.compactMap { name, earlier, value in
            guard let value, value != earlier else { return nil }
            return change(name, from: earlier, to: value)
        }
    }

    private static func change(_ name: String, from earlier: String?, to value: String?) -> DiscardedFieldChange {
        DiscardedFieldChange(field: QueuedChangeDiscardMessages.fieldLabel(name), discarded: value ?? QueuedChangeDiscardMessages.emptyValue,
                             restored: earlier ?? QueuedChangeDiscardMessages.emptyValue)
    }
}

/// Queued changes as the drain orders them: a row that failed holds back
/// every later row sharing its file, path, physical file or recording, and
/// those hold back theirs in turn.
enum QueuedSeratoChanges {
    /// Every queued change that cannot apply, in queue order: one of its rows
    /// failed, or it waits behind a change that did.
    static func stuck(in database: Database) throws -> [QueuedSeratoChange] {
        guard try Bool.fetchOne(database, sql: "SELECT EXISTS (SELECT 1 FROM serato_write_queue WHERE last_error IS NOT NULL)") == true else { return [] }
        return try changes(of: held(SeratoWriteQueue.fetchOrdered(in: database), behind: { row in row.lastError != nil }, in: database), in: database)
    }

    /// The later queued changes held behind `rows`.
    static func later(than rows: [GuardedSeratoWrite], in database: Database) throws -> [QueuedSeratoChange] {
        let own = Set(rows.compactMap(\.queueID))
        guard let first = own.min() else { return [] }
        let queue = try SeratoWriteQueue.fetchOrdered(in: database).filter { row in row.queueID.map { queueID in queueID >= first } == true }
        let held = try held(queue, behind: { row in row.queueID.map(own.contains) == true }, in: database)
        return try changes(of: held.filter { row in row.queueID.map(own.contains) != true }, in: database)
    }

    private static func held(_ rows: [GuardedSeratoWrite], behind isHead: (GuardedSeratoWrite) -> Bool, in database: Database) throws -> [GuardedSeratoWrite] {
        var holding = SeratoQueueDependency()
        var held: [GuardedSeratoWrite] = []
        for row in rows {
            // A row its file no longer permits is dropped by the next drain and holds nothing back.
            guard try SeratoWriteEligibility.permits(row, file: FileRecord.fetchOne(database, key: row.token.fileId)) else { continue }
            let dependency = try SeratoQueueDependency(target: SeratoConflictTargets.write(row, in: database), eventID: row.eventId)
            guard isHead(row) || dependency.intersects(holding) else { continue }
            holding.formUnion(dependency)
            held.append(row)
        }
        return held
    }

    private static func changes(of rows: [GuardedSeratoWrite], in database: Database) throws -> [QueuedSeratoChange] {
        var order: [String] = []
        var changes: [String: QueuedSeratoChange] = [:]
        for row in rows {
            guard let batchID = try String.fetchOne(database, sql: "SELECT batch_id FROM events WHERE event_id = ?", arguments: [row.eventId]),
                  let path = try String.fetchOne(database, sql: "SELECT path FROM files WHERE id = ?", arguments: [row.token.fileId])
            else { continue }
            let change = QueuedSeratoChange(batchID: batchID, fileID: row.token.fileId, path: path, failure: row.lastError ?? changes["\(batchID):\(row.token.fileId)"]?.failure)
            if changes[change.id] == nil {
                order.append(change.id)
            }
            changes[change.id] = change
        }
        return order.compactMap { id in changes[id] }
    }
}
