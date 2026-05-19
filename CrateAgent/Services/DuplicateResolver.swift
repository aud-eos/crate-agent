import Foundation

/// Carries out the destructive side of duplicate resolution. Given
/// a group of duplicate files and the user's chosen keeper, the
/// resolver fires a four-mutation batch per non-keeper:
///
///   1. `removeTrackFromSerato` — drop the otrk from `database V2`
///      so Serato stops showing it
///   2. `removeFileFromCrates` — sweep every `.crate` and remove
///      the path so individual crates lose their broken reference
///   3. `trashFile` — move the file to macOS Trash (reversible
///      via Finder's "Put Back" until Trash is emptied)
///   4. `removeFile` — drop the FileRecord from crate-agent's DB
///
/// All four under the same `batch_id`, surfaced in the History
/// view. The events are journaled but undoNotSupported — recovery
/// is via Finder Trash plus manual Serato re-add. The History
/// entry is an audit log, not an undo handle, for this workflow.
///
/// Serato-closed precondition is enforced by `SeratoWatchdog`
/// inside the engine (every Serato side effect queues if Serato is
/// running). The caller (the UI's Resolve button) is also expected
/// to gate on `isSeratoRunning` for clearer UX.
public actor DuplicateResolver {

    public struct Outcome: Sendable, Equatable {
        /// The single batch id all events from this resolution
        /// share. Hand to the History view for cross-reference.
        public let batchId: String
        /// Number of files that were trashed.
        public let trashedCount: Int
    }

    public enum ResolverError: LocalizedError, Equatable {
        case keeperNotInGroup
        case noFilesToTrash

        public var errorDescription: String? {
            switch self {
            case .keeperNotInGroup:
                return "The chosen keeper isn't a member of this duplicate group."
            case .noFilesToTrash:
                return "Nothing to do — the group has only the keeper file."
            }
        }
    }

    private let operationEngine: OperationEngine

    public init(operationEngine: OperationEngine) {
        self.operationEngine = operationEngine
    }

    /// Resolve one duplicate group by trashing every file except
    /// the chosen keeper and cleaning the Serato references.
    @discardableResult
    public func resolve(
        group: DuplicateFinder.DuplicateGroup,
        keeperId: Int64,
        batchId: String? = nil
    ) async throws -> Outcome {
        let keeperIsInGroup = group.files.contains { $0.id == keeperId }
        guard keeperIsInGroup else { throw ResolverError.keeperNotInGroup }

        let toTrash: [Int64] = group.files.compactMap { file -> Int64? in
            guard let identifier = file.id, identifier != keeperId else { return nil }
            return identifier
        }
        guard !toTrash.isEmpty else { throw ResolverError.noFilesToTrash }

        let effectiveBatchId = batchId ?? "duplicate-resolution-\(UUID().uuidString)"

        for fileId in toTrash {
            // Order matters for FK behavior: the Serato cleanups and
            // the trash all read the FileRecord by id to resolve the
            // path. `removeFile` deletes the row last, so it can't
            // pull the path out from under earlier steps.
            try await operationEngine.apply(
                .removeTrackFromSerato(RemoveTrackFromSeratoPayload(fileId: fileId)),
                batchId: effectiveBatchId
            )
            try await operationEngine.apply(
                .removeFileFromCrates(RemoveFileFromCratesPayload(fileId: fileId)),
                batchId: effectiveBatchId
            )
            try await operationEngine.apply(
                .trashFile(TrashFilePayload(fileId: fileId)),
                batchId: effectiveBatchId
            )
            try await operationEngine.apply(
                .removeFile(RemoveFilePayload(fileId: fileId)),
                batchId: effectiveBatchId
            )
        }

        return Outcome(batchId: effectiveBatchId, trashedCount: toTrash.count)
    }
}
