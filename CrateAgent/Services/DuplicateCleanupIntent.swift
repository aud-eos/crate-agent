import Foundation
import GRDB
import os

struct FileActionAuthority: Sendable, Equatable {
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
    let receipt: DuplicateCleanupReceipt
    var step = 0
    var waitingEventID: Int64?

    init(target: FileActionAuthority, keeper: FileActionAuthority, batchID: String) {
        self.target = target
        self.keeper = keeper
        self.batchID = batchID
        receipt = DuplicateCleanupReceipt(target: target, keeper: keeper, batchID: batchID)
    }

    var mutations: [TrackMutation] {
        [.removeTrackFromSerato(.init(fileId: target.token.fileId)),
         .removeFileFromCrates(.init(fileId: target.token.fileId)),
         .trashFile(.init(fileId: target.token.fileId)),
         .removeFile(.init(fileId: target.token.fileId))]
    }
}

/// Receipts are set before the serialized external-write boundary releases, so
/// a concurrent strict snapshot cannot mistake our completed removal for an
/// unrelated retirement while the engine actor resumes its next step.
final class DuplicateCleanupReceipt: Sendable, Equatable {
    let target: FileActionAuthority
    let keeper: FileActionAuthority
    let batchID: String
    private let state = OSAllocatedUnfairLock(initialState: (removedV2: false, removedRow: false))
    init(target: FileActionAuthority, keeper: FileActionAuthority, batchID: String) {
        self.target = target
        self.keeper = keeper
        self.batchID = batchID
    }

    var removedV2: Bool {
        state.withLock { $0.removedV2 }
    }

    var removedRow: Bool {
        state.withLock { $0.removedRow }
    }

    func confirmV2Removal() {
        state.withLock { $0.removedV2 = true }
    }

    func confirmRowRemoval() {
        state.withLock { $0.removedRow = true }
    }

    static func == (left: DuplicateCleanupReceipt, right: DuplicateCleanupReceipt) -> Bool {
        left === right
    }
}

enum DuplicateCleanupResult: Equatable, Sendable {
    case pending
    case completed
    case superseded(String)
    case failed(String)
}
