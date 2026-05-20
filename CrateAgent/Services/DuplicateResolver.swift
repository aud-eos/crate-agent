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
        /// Number of files that fully completed the 4-mutation
        /// sequence (Serato cleanup → trash → DB removal).
        public let trashedCount: Int
        /// Number of files where one or more of the per-file
        /// mutations threw. Earlier mutations on these files may
        /// have already applied — see `errors` for context.
        public let failureCount: Int
        /// One human-readable error string per failed file.
        public let errors: [String]

        public init(
            batchId: String,
            trashedCount: Int,
            failureCount: Int = 0,
            errors: [String] = []
        ) {
            self.batchId = batchId
            self.trashedCount = trashedCount
            self.failureCount = failureCount
            self.errors = errors
        }
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
    private let activityLog: ActivityLog?

    public init(
        operationEngine: OperationEngine,
        activityLog: ActivityLog? = nil
    ) {
        self.operationEngine = operationEngine
        self.activityLog = activityLog
    }

    private func note(_ message: String) async {
        guard let log = activityLog else { return }
        await log.log(message, category: .duplicate)
    }

    /// Resolve one duplicate group by trashing every file except
    /// the chosen keeper and cleaning the Serato references.
    @discardableResult
    public func resolve(
        group: DuplicateFinder.DuplicateGroup,
        keeperId: Int64,
        batchId: String? = nil
    ) async throws -> Outcome {
        let keeperIsInGroup = group.files.contains { file in file.id == keeperId }
        guard keeperIsInGroup else { throw ResolverError.keeperNotInGroup }

        let toTrash: [Int64] = group.files.compactMap { file -> Int64? in
            guard let identifier = file.id, identifier != keeperId else { return nil }
            return identifier
        }
        guard !toTrash.isEmpty else { throw ResolverError.noFilesToTrash }

        let effectiveBatchId = batchId ?? "duplicate-resolution-\(UUID().uuidString)"

        await note("Resolving duplicate group: trashing \(toTrash.count) non-keeper\(toTrash.count == 1 ? "" : "s")…")

        var trashedCount = 0
        var failureCount = 0
        var errors: [String] = []
        for fileId in toTrash {
            do {
                try await resolveOne(fileId: fileId, batchId: effectiveBatchId)
                trashedCount += 1
            } catch {
                // Per-file fault tolerance: one failure must not
                // abort the rest of the batch. The earlier
                // mutations for THIS file may have partially
                // applied — the audit trail in the events table
                // captures what landed; the activity-log note
                // surfaces it to the user. Without this guard a
                // single mid-loop throw left every untouched file
                // forever unresolved.
                failureCount += 1
                let message = "file id \(fileId): \(error.localizedDescription)"
                errors.append(message)
                await note("Skipped \(message) — earlier steps for this file may have partially applied; subsequent files continue.")
            }
        }

        await note("Resolved group — \(trashedCount) file\(trashedCount == 1 ? "" : "s") trashed, \(failureCount) skipped")
        return Outcome(
            batchId: effectiveBatchId,
            trashedCount: trashedCount,
            failureCount: failureCount,
            errors: errors
        )
    }

    private func resolveOne(fileId: Int64, batchId: String) async throws {
        await note("Trashing file id \(fileId) (Serato cleanup → trash → DB)")
        // Order matters for FK behavior: the Serato cleanups and
        // the trash all read the FileRecord by id to resolve the
        // path. `removeFile` deletes the row last, so it can't
        // pull the path out from under earlier steps.
        try await operationEngine.apply(
            .removeTrackFromSerato(RemoveTrackFromSeratoPayload(fileId: fileId)),
            batchId: batchId
        )
        try await operationEngine.apply(
            .removeFileFromCrates(RemoveFileFromCratesPayload(fileId: fileId)),
            batchId: batchId
        )
        try await operationEngine.apply(
            .trashFile(TrashFilePayload(fileId: fileId)),
            batchId: batchId
        )
        try await operationEngine.apply(
            .removeFile(RemoveFilePayload(fileId: fileId)),
            batchId: batchId
        )
    }
}
