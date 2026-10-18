import Foundation
import GRDB

/// Undoes a removal's Trash move, produced by `decodeInverseMutation` from a
/// `.fileTrashed` event. `removalEventID` names the Trash item recorded when the
/// move landed; `identity` is the file's identity at `originalPath` before it.
public struct RestoreFromTrashPayload: Codable, Sendable, Equatable {
    public let originalPath: String
    public let identity: FileMetadata
    public let removalEventID: Int64
}

/// Undoes a removal from database V2 or the crates, produced by
/// `decodeInverseMutation`, by reinserting the records captured when it landed.
/// `trackPath` is the audio file's absolute path.
public struct RestoreSeratoRecordsPayload: Codable, Sendable, Equatable {
    public let removalEventID: Int64
    public let trackPath: String
}

/// Queued reinsertion of one removal's captured records into each store it took them from.
struct SeratoPendingRestore: Codable, Sendable, Equatable {
    let absolutePath: String
    let removalEventID: Int64
    let storePaths: [String]
}

public enum RestoreBlockReason: Sendable, Equatable {
    case trashItemMissing
    case trashItemChanged
    /// A file is at the recorded path, but it is no longer in a Trash.
    case trashItemNotInTrash
    case originalPathOccupied
    case trashItemNotRecorded
    /// The store's records were removed, but their capture was lost.
    case recordsNotRecorded(store: String)
    case fileNotRestored
}

enum RemovalRestoreMutation {
    /// A Trash move's inverse; undo supplies the removal event's own id.
    struct TrashInverse: Codable {
        let originalPath: String
        let identity: FileMetadata

        func payload(removalEventID: Int64) -> RestoreFromTrashPayload {
            RestoreFromTrashPayload(originalPath: originalPath, identity: identity, removalEventID: removalEventID)
        }
    }

    /// A Serato removal's inverse; undo supplies the removal event's own id.
    struct RecordsInverse: Codable {
        let trackPath: String

        func payload(removalEventID: Int64) -> RestoreSeratoRecordsPayload {
            RestoreSeratoRecordsPayload(removalEventID: removalEventID, trackPath: trackPath)
        }
    }

    /// What redoing a records restore would remove again. Journaled for the
    /// record; redo is refused until it runs through a cleanup intent.
    private struct Redo: Codable {
        let fileId: Int64
        let removalEventType: EventType
    }

    /// Moves the file back from its recorded Trash item into the re-indexed row
    /// at its original path, refusing when the item is gone or changed, or the
    /// path holds another file.
    static func restoreFromTrash(_ payload: RestoreFromTrashPayload, batchId: String, timestamp: Int64,
                                 physicalMoves: PhysicalFileMoveTransaction?, resolver: FileAvailabilityResolver,
                                 in database: GRDB.Database) throws -> Int64
    {
        func blocked(_ reason: RestoreBlockReason) -> OperationEngineError {
            .restoreBlocked(path: payload.originalPath, reason: reason)
        }
        guard let trashItem = try SeratoRemovalCaptureStore.trashDestination(eventID: payload.removalEventID, in: database)?.identity else {
            throw blocked(.trashItemNotRecorded)
        }
        switch try resolver.inspect(path: trashItem.path, volumeID: trashItem.volumeUuid) {
        case .trashed:
            guard try FileTrashLocation.availability(of: trashItem, resolver: resolver) == .trashed else {
                throw blocked(FileManager.default.fileExists(atPath: trashItem.path) ? .trashItemChanged : .trashItemMissing)
            }
        case .available: throw blocked(.trashItemNotInTrash)
        case .missing, .offline, .inaccessible, .unknown: throw blocked(.trashItemMissing)
        }
        guard !FileManager.default.fileExists(atPath: payload.originalPath) else { throw blocked(.originalPathOccupied) }
        guard let physicalMoves else { preconditionFailure("Restoring from Trash runs only inside a physical move transaction") }
        guard var file = try FileRecord.filter(Column("path") == payload.originalPath).fetchOne(database),
              let fileID = file.id, file.identity == payload.identity
        else {
            throw blocked(.fileNotRestored)
        }
        let restored = try physicalMoves.restore(trashItem, to: payload.originalPath)
        file.volumeUuid = restored.volumeUuid
        file.inode = restored.inode
        file.libraryMembership = .active
        file.fileAvailability = .available
        file.membershipRevision += 1
        try file.update(database)
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: fileID, eventType: .fileRestoredFromTrash,
                                               forwardPayload: payload, inversePayload: TrashFilePayload(fileId: fileID), in: database)
    }

    /// Queues the reinsertion of every store's captured records for the file at
    /// `trackPath`. A removal that removed nothing queues nothing; one whose
    /// capture was lost refuses rather than restore only part of it.
    static func restoreSeratoRecords(_ payload: RestoreSeratoRecordsPayload, batchId: String, timestamp: Int64,
                                     in database: GRDB.Database) throws -> (Int64, SeratoPendingRestore?)
    {
        guard let removal = try EventRecord.fetchOne(database, key: payload.removalEventID),
              [EventType.trackRemovedFromSerato, .fileRemovedFromCrates].contains(removal.eventType)
        else {
            throw OperationEngineError.undoNotSupported(eventType: .seratoRecordsRestored)
        }
        guard let file = try FileRecord.filter(Column("path") == payload.trackPath).fetchOne(database), let fileID = file.id else {
            throw OperationEngineError.restoreBlocked(path: payload.trackPath, reason: .fileNotRestored)
        }
        try FileProcessingEligibility.requireProcessable(file)
        let captures = try SeratoRemovalCaptureStore.captures(eventID: payload.removalEventID, in: database).filter { capture in
            capture.outcome != .nothingRemoved
        }
        // A store deleted since has nothing to restore into; the drain reports it as not applied.
        if let unrecorded = captures.first(where: { capture in capture.isUnrecorded && FileManager.default.fileExists(atPath: capture.storePath) }) {
            throw OperationEngineError.restoreBlocked(path: payload.trackPath, reason: .recordsNotRecorded(store: unrecorded.storePath))
        }
        let eventID = try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: fileID, eventType: .seratoRecordsRestored,
                                                      forwardPayload: payload, inversePayload: Redo(fileId: fileID, removalEventType: removal.eventType),
                                                      in: database)
        let restore = captures.isEmpty ? nil : SeratoPendingRestore(absolutePath: file.path, removalEventID: payload.removalEventID,
                                                                    storePaths: captures.map(\.storePath))
        return (eventID, restore)
    }
}
