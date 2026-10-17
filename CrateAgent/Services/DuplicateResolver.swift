import Foundation

/// Carries out the destructive side of duplicate resolution. Given
/// a group of duplicate files and the user's chosen keeper, the
/// engine retains an original-authority sequence per non-keeper:
///
///   1. `removeTrackFromSerato` — drop the otrk from `database V2`
///      so Serato stops showing it
///   2. `removeFileFromCrates` — sweep every `.crate` / `.scrate` and remove
///      the path so individual crates lose their broken reference
///   3. `trashFile` — move the file to macOS Trash (reversible
///      via Finder's "Put Back" until Trash is emptied)
///   4. `removeFile` — drop the FileRecord from crate-agent's DB
///
/// All four under the same `batch_id`, surfaced in the History
/// view. The events are journaled but undoNotSupported — recovery
/// is via Finder Trash plus manual Serato re-add. The History
/// entry is an audit log, not an undo handle, for this workflow.
/// Pending/failed external stages retain their owner row. Completion and
/// final row deletion follow actual successful Trash I/O; Retry Sync resumes
/// a retained failed stage only after fresh saved-library authorization.
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
        public let pendingCount: Int
        /// Number of files where one or more of the per-file
        /// mutations threw. Earlier mutations on these files may
        /// have already applied — see `errors` for context.
        public let failureCount: Int
        /// One human-readable error string per failed file.
        public let errors: [String]

        public init(
            batchId: String,
            trashedCount: Int,
            pendingCount: Int = 0,
            failureCount: Int = 0,
            errors: [String] = []
        ) {
            self.batchId = batchId
            self.trashedCount = trashedCount
            self.pendingCount = pendingCount
            self.failureCount = failureCount
            self.errors = errors
        }
    }

    public enum ResolverError: LocalizedError, Equatable {
        case keeperNotInGroup
        case noFilesToTrash
        case audioNotConfirmed

        public var errorDescription: String? {
            switch self {
            case .keeperNotInGroup:
                "The chosen keeper isn't a member of this duplicate group."
            case .noFilesToTrash:
                "Nothing to do — the group has only the keeper file."
            case .audioNotConfirmed:
                "These files' audio hasn't been confirmed the same, so none of them were moved to Trash."
            }
        }
    }

    private let operationEngine: OperationEngine
    private let database: LibraryDatabase
    private let activityLog: ActivityLog?

    public init(
        operationEngine: OperationEngine,
        database: LibraryDatabase,
        activityLog: ActivityLog? = nil
    ) {
        self.operationEngine = operationEngine
        self.database = database
        self.activityLog = activityLog
    }

    private func note(_ message: String) async {
        guard let log = activityLog else { return }
        await log.log(message, category: .duplicate)
    }

    /// Resolve one duplicate group by trashing every file except
    /// the chosen keeper and cleaning the Serato references. Groups
    /// may hold lightweight projections; the full rows are fetched by
    /// id here, and a row whose revision or physical identity no
    /// longer matches the reviewed one is reported as superseded.
    /// A group needing listening trashes only `explicitlySelectedFileIDs`; every
    /// other group trashes all non-keepers.
    @discardableResult
    public func resolve(
        group: DuplicateFinder.DuplicateGroup<some DuplicateFileSource>,
        keeperId: Int64,
        batchId: String? = nil,
        explicitlySelectedFileIDs: Set<Int64> = []
    ) async throws -> Outcome {
        guard let reviewedKeeper = group.files.first(where: { file in file.id == keeperId }) else { throw ResolverError.keeperNotInGroup }
        let audioRequirement: DuplicateAudioRequirement
        switch group.audioCheck {
        case .notRequired:
            guard group.mode == .byteLevel else { throw ResolverError.audioNotConfirmed }
            audioRequirement = .none
        case .confirmed: audioRequirement = .identical
        case .needsListening: audioRequirement = .identicalOrExplicitFingerprintMatch
        case .checking, .differs: throw ResolverError.audioNotConfirmed
        }

        let reviewedTargets = group.files.compactMap { file in
            file.id.flatMap { identifier in
                identifier == keeperId || (group.audioCheck == .needsListening && !explicitlySelectedFileIDs.contains(identifier))
                    ? nil : (fileID: identifier, file: file)
            }
        }
        guard !reviewedTargets.isEmpty else { throw ResolverError.noFilesToTrash }
        let currentByID = try await database.writer.read { connection in
            try FileRecord.fetchAll(connection, keys: group.files.compactMap(\.id))
        }.reduce(into: [Int64: FileRecord]()) { records, record in
            if let identifier = record.id {
                records[identifier] = record
            }
        }
        func current(_ fileID: Int64, reviewed: some DuplicateFileSource) throws -> FileRecord {
            guard let record = currentByID[fileID], record.membershipRevision == reviewed.membershipRevision,
                  record.identity == reviewed.identity
            else { throw FileProcessingEligibilityError.superseded(fileId: fileID) }
            return record
        }

        let effectiveBatchId = batchId ?? "duplicate-resolution-\(UUID().uuidString)"

        await note("Resolving duplicate group: trashing \(reviewedTargets.count) non-keeper\(reviewedTargets.count == 1 ? "" : "s")…")

        var trashedCount = 0
        var pendingCount = 0
        var failureCount = 0
        var errors: [String] = []
        for (fileId, reviewed) in reviewedTargets {
            do {
                let result = try await operationEngine.resolveDuplicate(
                    target: current(fileId, reviewed: reviewed), keeper: current(keeperId, reviewed: reviewedKeeper), batchID: effectiveBatchId,
                    audioRequirement: audioRequirement
                )
                switch result {
                case .completed: trashedCount += 1
                case .pending: pendingCount += 1
                case let .superseded(message), let .failed(message):
                    failureCount += 1
                    errors.append("file id \(fileId): \(message)")
                }
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

        await note("Resolved group — \(trashedCount) trashed, \(pendingCount) pending, \(failureCount) skipped")
        return Outcome(
            batchId: effectiveBatchId,
            trashedCount: trashedCount,
            pendingCount: pendingCount,
            failureCount: failureCount,
            errors: errors
        )
    }
}
