import Foundation
import GRDB

public struct BeginFileImportPayload: Codable, Sendable {
    public let fileId: Int64
    public let expectedRevision: Int64
    public let identity: FileMetadata

    public init(fileId: Int64, expectedRevision: Int64, identity: FileMetadata) {
        self.fileId = fileId
        self.expectedRevision = expectedRevision
        self.identity = identity
    }
}

enum FileImportIdentity {
    static func matches(_ file: FileRecord, identity: FileMetadata) -> Bool {
        file.volumeUuid == identity.volumeUuid && matchesAttributes(file, identity: identity)
    }

    static func matchesAttributes(_ file: FileRecord, identity: FileMetadata) -> Bool {
        SeratoPath.normalized(file.path) == SeratoPath.normalized(identity.path)
            && file.inode == identity.inode && file.fileSize == identity.fileSize && file.hasSameModificationTime(as: identity)
            && (file.lightweightHash == nil || file.lightweightHash == identity.lightweightHash)
    }
}

extension FileLibraryStateMutation {
    static func beginImport(_ payload: BeginFileImportPayload, batchId: String, timestamp: Int64, in database: GRDB.Database) throws -> Int64? {
        guard let file = try FileRecord.fetchOne(database, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        guard file.libraryMembership != .active, FileImportIdentity.matches(file, identity: payload.identity),
              try FileMetadataCollector.collectVerified(at: payload.identity.path) == payload.identity
        else {
            throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
        }
        if file.lightweightHash == nil {
            _ = try FileIdentityObservationMutation.apply(.init(fileId: payload.fileId, expectedRevision: payload.expectedRevision,
                                                                previousIdentity: file.identity, identity: payload.identity),
                                                          batchId: batchId, timestamp: timestamp, in: database)
        }
        let state = SetFileLibraryStatePayload(fileId: payload.fileId, expectedRevision: payload.expectedRevision,
                                               state: FileLibraryState(membership: .pendingImport, availability: .available, libraryID: file.seratoLibraryId, retiredAt: nil))
        return try updateAndLog(state, batchId: batchId, timestamp: timestamp,
                                startsImportIntent: true, eventType: .fileImportRequested, forwardPayload: payload, in: database)
    }
}
