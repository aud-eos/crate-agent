import Foundation
import GRDB

public struct ObserveFileLocationPayload: Codable, Sendable {
    public let fileId: Int64
    public let expectedRevision: Int64
    public let path: String
    public let volumeUuid: String
    public let inode: Int64
}

enum FileLocationObservationMutation {
    static func apply(_ payload: ObserveFileLocationPayload, batchId: String, timestamp: Int64, in database: GRDB.Database) throws -> Int64? {
        guard var file = try FileRecord.fetchOne(database, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        guard file.membershipRevision == payload.expectedRevision else {
            throw FileLibraryStateMutationError.staleRevision(fileId: payload.fileId, expected: payload.expectedRevision, actual: file.membershipRevision)
        }
        guard file.path != payload.path || file.volumeUuid != payload.volumeUuid || file.inode != payload.inode else { return nil }
        let inverse = ObserveFileLocationPayload(fileId: payload.fileId, expectedRevision: file.membershipRevision, path: file.path, volumeUuid: file.volumeUuid, inode: file.inode)
        file.path = payload.path
        file.volumeUuid = payload.volumeUuid
        file.inode = payload.inode
        try file.update(database)
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: file.id, trackId: file.trackId, eventType: .fileLocationObserved, forwardPayload: payload, inversePayload: inverse, in: database)
    }
}
