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

/// Why a file may be removed: it duplicates a keeper the user chose, or the
/// user chose to remove it outright.
enum RemovalAuthority: Codable, Sendable, Equatable {
    /// Rechecked against cached digests in every attempt of the first
    /// step's transaction, including a resume after a rolled-back attempt;
    /// later steps rely on the identity revalidation. The requirement is nil
    /// only for intents saved before digests existed, which can no longer start.
    case duplicateOf(FileActionAuthority, DuplicateEvidenceRequirement?)
    case ownerChoice

    var keeper: FileActionAuthority? {
        switch self {
        case let .duplicateOf(keeper, _): keeper
        case .ownerChoice: nil
        }
    }

    func validateKeeper(in database: Database) throws {
        try keeper?.validate(in: database)
    }
}

struct PendingFileRemoval: Sendable {
    let target: FileActionAuthority
    let authority: RemovalAuthority
    let batchID: String
    var step = 0
    var waitingEventID: Int64?
    var removedV2 = false
    var failure: String?

    init(target: FileActionAuthority, authority: RemovalAuthority, batchID: String) {
        self.target = target
        self.authority = authority
        self.batchID = batchID
    }

    var mutations: [TrackMutation] {
        [.removeTrackFromSerato(.init(fileId: target.token.fileId)),
         .removeFileFromCrates(.init(fileId: target.token.fileId)),
         .trashFile(.init(fileId: target.token.fileId)),
         .removeFile(.init(fileId: target.token.fileId))]
    }
}

public enum FileRemovalResult: Equatable, Sendable {
    case pending
    case completed
    case superseded(String)
    case failed(String)
}
