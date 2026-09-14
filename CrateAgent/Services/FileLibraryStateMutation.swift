import Foundation
import GRDB

public enum FileLibraryStateMutationError: LocalizedError, Equatable {
    case staleRevision(fileId: Int64, expected: Int64, actual: Int64)

    public var errorDescription: String? {
        switch self {
        case let .staleRevision(fileId, expected, actual):
            return "File \(fileId) membership changed: expected revision \(expected), found \(actual). Refresh before retrying."
        }
    }
}

enum FileLibraryStateMutation {
    static func apply(_ payload: SetFileLibraryStatePayload, batchId: String, timestamp: Int64, in database: GRDB.Database) throws -> Int64? {
        try updateAndLog(payload, batchId: batchId, timestamp: timestamp, startsImportIntent: false,
                         eventType: .fileLibraryStateChanged, forwardPayload: payload, in: database)
    }

    static func updateAndLog<Payload: Encodable>(_ payload: SetFileLibraryStatePayload, batchId: String, timestamp: Int64,
                                                 startsImportIntent: Bool, eventType: EventType, forwardPayload: Payload, in database: GRDB.Database) throws -> Int64?
    {
        guard var file = try FileRecord.fetchOne(database, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        guard file.membershipRevision == payload.expectedRevision else {
            throw FileLibraryStateMutationError.staleRevision(fileId: payload.fileId, expected: payload.expectedRevision, actual: file.membershipRevision)
        }
        let previousState = file.libraryState
        guard startsImportIntent || previousState != payload.state else { return nil }

        if startsImportIntent || file.libraryMembership != payload.state.membership {
            file.membershipRevision += 1
            if payload.state.membership == .retired {
                // Unversioned History intent stays invalid after reactivation or inverse application.
                file.lastRetirementRevision = file.membershipRevision
            }
        }
        file.libraryMembership = payload.state.membership
        file.fileAvailability = payload.state.availability
        file.seratoLibraryId = payload.state.libraryID
        file.retiredAt = payload.state.retiredAt
        try file.update(database)

        let inverse = SetFileLibraryStatePayload(fileId: payload.fileId, expectedRevision: file.membershipRevision, state: previousState)
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: file.id, trackId: file.trackId, eventType: eventType, forwardPayload: forwardPayload, inversePayload: inverse, in: database)
    }
}
