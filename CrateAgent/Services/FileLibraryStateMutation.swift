import Foundation
import GRDB

public enum FileLibraryStateMutationError: LocalizedError, Equatable {
    case staleRevision(fileId: Int64, expected: Int64, actual: Int64)
    case trashLocationWithoutTrash(fileId: Int64)

    public var errorDescription: String? {
        switch self {
        case let .staleRevision(fileId, expected, actual):
            "File \(fileId) membership changed: expected revision \(expected), found \(actual). Refresh before retrying."
        case let .trashLocationWithoutTrash(fileId):
            "File \(fileId) can keep a Trash location only while it is in Trash, offline or inaccessible."
        }
    }
}

enum FileLibraryStateMutation {
    static func apply(_ payload: SetFileLibraryStatePayload, batchId: String, timestamp: Int64, in database: GRDB.Database) throws -> Int64? {
        try updateAndLog(payload, batchId: batchId, timestamp: timestamp, startsImportIntent: false,
                         eventType: .fileLibraryStateChanged, forwardPayload: payload, in: database)
    }

    static func updateAndLog(_ payload: SetFileLibraryStatePayload, batchId: String, timestamp: Int64,
                             startsImportIntent: Bool, eventType: EventType, forwardPayload: some Encodable, in database: GRDB.Database) throws -> Int64?
    {
        guard var file = try FileRecord.fetchOne(database, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        guard file.membershipRevision == payload.expectedRevision else {
            throw FileLibraryStateMutationError.staleRevision(fileId: payload.fileId, expected: payload.expectedRevision, actual: file.membershipRevision)
        }
        let previousState = file.libraryState
        let previousTrashLocation = try FileTrashLocation.load(fileID: payload.fileId, in: database)
        let readded = payload.observedReadditionAfterOwnedRemoval == true
        let suppliesNewLocation = payload.trashLocation.map { location in location != previousTrashLocation } ?? false
        guard startsImportIntent || readded || previousState != payload.state || suppliesNewLocation else { return nil }
        let trashLocation = try nextTrashLocation(payload, file: file, previous: previousTrashLocation)

        if startsImportIntent || readded || file.libraryMembership != payload.state.membership {
            file.membershipRevision += 1
            if readded || payload.state.membership == .retired {
                // Legacy History stays invalid after retirement or content replacement.
                file.lastProjectionInvalidationRevision = file.membershipRevision
            }
        }
        file.libraryMembership = payload.state.membership
        file.fileAvailability = payload.state.availability
        file.seratoLibraryId = payload.state.libraryID
        file.retiredAt = payload.state.retiredAt
        try file.update(database)
        try FileTrashLocation.store(trashLocation, fileID: payload.fileId, in: database)

        let inverse = SetFileLibraryStatePayload(fileId: payload.fileId, expectedRevision: file.membershipRevision, state: previousState,
                                                 trashLocation: previousTrashLocation)
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: file.id, trackId: file.trackId, eventType: eventType, forwardPayload: forwardPayload, inversePayload: inverse, in: database)
    }

    /// A recorded Trash item belongs to a trashed row. Offline and inaccessible say nothing
    /// about whether that item still exists, so they keep it for the next check. A change to
    /// trashed is re-checked here, under the write lock, because Trash can be emptied while
    /// the caller awaits the commit; the caller's own pre-check already compared content.
    /// Without a supplied location the caller relied on the row's own path or its recorded
    /// item, so both are checked against the row's identity, the own path first.
    private static func nextTrashLocation(_ payload: SetFileLibraryStatePayload, file: FileRecord, previous: FileMetadata?) throws -> FileMetadata? {
        switch payload.state.availability {
        case .trashed:
            let resolver = FileAvailabilityResolver()
            if payload.trashLocation == nil,
               try FileTrashLocation.ownPathAvailability(path: file.path, volumeUuid: file.volumeUuid, inode: file.inode, resolver: resolver) == .trashed
            {
                return nil
            }
            guard let location = payload.trashLocation ?? previous,
                  try FileTrashLocation.availability(of: location, resolver: resolver, comparingContent: false) == .trashed
            else {
                throw FileTrashLocationError.itemChanged(fileId: payload.fileId)
            }
            return location
        case .offline, .inaccessible:
            return payload.trashLocation ?? previous
        case .available, .missing, .unknown:
            guard payload.trashLocation == nil else { throw FileLibraryStateMutationError.trashLocationWithoutTrash(fileId: payload.fileId) }
            return nil
        }
    }
}
