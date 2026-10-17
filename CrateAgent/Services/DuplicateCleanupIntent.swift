import Foundation
import GRDB

struct FileActionAuthority: Codable, Sendable, Equatable {
    let token: FileMembershipToken
    let identity: FileMetadata

    init(_ file: FileRecord) throws {
        guard let fileID = file.id else { throw OperationEngineError.insertDidNotReturnRowId }
        token = FileMembershipToken(fileId: fileID, revision: file.membershipRevision)
        identity = file.identity
    }

    func validate(in database: Database, audioWasTrashed: Bool = false) throws {
        try FileProcessingEligibility.requireCurrent(token, in: database)
        guard let current = try FileRecord.fetchOne(database, key: token.fileId), current.identity == identity else {
            throw FileProcessingEligibilityError.superseded(fileId: token.fileId)
        }
        if audioWasTrashed {
            guard !FileManager.default.fileExists(atPath: identity.path) else { throw FileProcessingEligibilityError.superseded(fileId: token.fileId) }
        } else {
            do {
                guard try FileMetadataCollector.collectVerified(at: identity.path) == identity else {
                    throw FileProcessingEligibilityError.superseded(fileId: token.fileId)
                }
            } catch { throw FileProcessingEligibilityError.superseded(fileId: token.fileId) }
        }
    }
}

struct PendingDuplicateCleanup: Sendable {
    let target: FileActionAuthority
    let keeper: FileActionAuthority
    let batchID: String
    var step = 0
    var waitingEventID: Int64?
    var removedV2 = false
    var failure: String?

    init(target: FileActionAuthority, keeper: FileActionAuthority, batchID: String) {
        self.target = target
        self.keeper = keeper
        self.batchID = batchID
    }

    var mutations: [TrackMutation] {
        [.removeTrackFromSerato(.init(fileId: target.token.fileId)),
         .removeFileFromCrates(.init(fileId: target.token.fileId)),
         .trashFile(.init(fileId: target.token.fileId)),
         .removeFile(.init(fileId: target.token.fileId))]
    }
}

enum DuplicateCleanupResult: Equatable, Sendable {
    case pending
    case completed
    case superseded(String)
    case failed(String)
}
