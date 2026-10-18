import Foundation

/// The actions on a same-audio group whose version labels disagree. Choosing
/// the keeper needs no write; these two do, through `OperationEngine`.
public struct DuplicateLabelReviewer {
    private let operationEngine: OperationEngine
    private let database: LibraryDatabase

    public init(operationEngine: OperationEngine, database: LibraryDatabase) {
        self.operationEngine = operationEngine
        self.database = database
    }

    /// Gives `keeper` the title of `source`, another copy in `group`, by
    /// editing its row, Serato's database V2 and its audio tags. Undoable from
    /// History; the Serato and tag writes queue while Serato runs.
    public func useTitle(of source: DuplicateFileRow, forKeeper keeper: DuplicateFileRow,
                         in group: DuplicateFinder.DuplicateGroup<DuplicateFileRow>) async throws
    {
        guard group.labelsDisagree, group.files.contains(source), group.files.contains(keeper), source != keeper,
              let title = source.title, let keeperID = keeper.id
        else { throw DuplicateLabelReviewError.titleNotInGroup }
        let current = try await database.writer.read { database in try FileRecord.fetchOne(database, key: keeperID) }
        guard let current, current.membershipRevision == keeper.membershipRevision, current.identity == keeper.identity else {
            throw FileProcessingEligibilityError.superseded(fileId: keeperID)
        }
        var edited = current.seratoMetadata
        edited.title = title
        try await operationEngine.applyMetadataEdit(fileId: keeperID, membershipRevision: current.membershipRevision,
                                                    previous: current.seratoMetadata, edited: edited,
                                                    batchId: "duplicate-label-title-\(UUID().uuidString)")
    }

    /// Keeps every copy in `group`: the group stops offering cleanup until
    /// one of its copies changes. Undoable from History.
    public func keepAll(_ group: DuplicateFinder.DuplicateGroup<DuplicateFileRow>) async throws {
        guard let review = group.labelReview, !review.keptBoth else { throw DuplicateLabelReviewError.alreadyKept }
        let payload = DuplicateLabelReviewPayload(signature: review.signature, mode: group.mode, fileIds: group.files.compactMap(\.id).sorted())
        try await operationEngine.apply(.duplicateLabelReview(.keepBoth(payload)), batchId: "duplicate-labels-kept-\(UUID().uuidString)")
    }
}
