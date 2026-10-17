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
            "File \(fileId) cannot record a Trash location unless it is in Trash."
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
        let trashLocation = try nextTrashLocation(payload, previous: previousTrashLocation)
        let readded = payload.observedReadditionAfterOwnedRemoval == true
        guard startsImportIntent || readded || previousState != payload.state || previousTrashLocation != trashLocation else { return nil }

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
    /// about whether that item still exists, so they keep it for the next check.
    private static func nextTrashLocation(_ payload: SetFileLibraryStatePayload, previous: FileMetadata?) throws -> FileMetadata? {
        guard payload.state.availability == .trashed else {
            guard payload.trashLocation == nil else { throw FileLibraryStateMutationError.trashLocationWithoutTrash(fileId: payload.fileId) }
            return payload.state.availability == .offline || payload.state.availability == .inaccessible ? previous : nil
        }
        guard let location = payload.trashLocation else { return previous }
        guard try FileTrashLocation.availability(of: location, resolver: FileAvailabilityResolver()) == .trashed else {
            throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
        }
        return location
    }
}
