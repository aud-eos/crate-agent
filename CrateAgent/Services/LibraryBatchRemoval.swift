import Foundation
import GRDB

/// Removes several Library files as one reviewed, undoable History batch. `plan`
/// resolves the selected identities to files, refusing when one changed since it
/// was selected, and totals the bytes the removal frees; `remove` runs each file
/// through `OperationEngine.removeFile`, the staged cleanup every removal uses, so
/// one undo from History restores them all. A file that fails is reported and the
/// others still go.
@MainActor
struct LibraryBatchRemoval {
    struct Plan: Equatable, Sendable {
        let files: [FileRecord]

        var totalBytes: Int64 {
            files.reduce(0) { total, file in total + file.fileSize }
        }
    }

    struct Outcome: Equatable, Sendable {
        let batchID: String
        var completed = 0
        var pending = 0
        var superseded = 0
        var failures: [(path: String, message: String)] = []

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.batchID == rhs.batchID && lhs.completed == rhs.completed && lhs.pending == rhs.pending && lhs.superseded == rhs.superseded
                && lhs.failures.map(\.path) == rhs.failures.map(\.path) && lhs.failures.map(\.message) == rhs.failures.map(\.message)
        }
    }

    let database: LibraryDatabase
    let engine: OperationEngine

    /// Refuses, rather than trims, a selection the engine would partly refuse:
    /// files that are not active and on disk, and files whose removal is already
    /// saved and waiting, which a new batch would count but neither move nor undo.
    func plan(_ identities: [PagedIdentity<Int64>]) async throws -> Plan {
        let revisions = Dictionary(uniqueKeysWithValues: identities.map { identity in (identity.id, identity.revision) })
        let (files, alreadyRemoving) = try await database.writer.read { connection in
            let files = try FileRecord.filter(keys: identities.map(\.id)).order(Column("id")).fetchAll(connection)
            let removing = try DuplicateCleanupStore.pendingTargetFileIDs(among: identities.map(\.id), in: connection)
            return (files, removing)
        }
        let changed = files.filter { file in file.id.map { identifier in revisions[identifier] != file.membershipRevision } ?? true }
        let missing = identities.count - files.count
        guard changed.isEmpty, missing == 0 else {
            throw LibrarySelectionError.changedSinceSelected(files: changed.map(\.displayName) + Array(repeating: LibraryRemovalMessages.missingFile, count: missing))
        }
        let notProcessable = files.filter { file in !FileProcessingEligibility.isProcessable(membership: file.libraryMembership, availability: file.fileAvailability) }
        guard notProcessable.isEmpty else { throw LibraryBatchRemovalError.notRemovable(files: notProcessable.map(\.displayName)) }
        let waiting = files.filter { file in file.id.map(alreadyRemoving.contains) ?? false }
        guard waiting.isEmpty else { throw LibraryBatchRemovalError.alreadyRemoving(files: waiting.map(\.displayName)) }
        return Plan(files: files)
    }

    func remove(_ plan: Plan) async -> Outcome {
        var outcome = Outcome(batchID: "library-remove-\(UUID().uuidString)")
        for file in plan.files {
            do {
                switch try await engine.removeFile(target: file, batchID: outcome.batchID) {
                case .completed: outcome.completed += 1
                case .pending: outcome.pending += 1
                case let .superseded(message):
                    outcome.superseded += 1
                    outcome.failures.append((file.path, message))
                case let .failed(message): outcome.failures.append((file.path, message))
                }
            } catch {
                outcome.failures.append((file.path, error.localizedDescription))
            }
        }
        return outcome
    }
}

enum LibraryBatchRemovalError: LocalizedError, Equatable {
    case notRemovable(files: [String])
    case alreadyRemoving(files: [String])

    var errorDescription: String? {
        switch self {
        case let .notRemovable(files): LibraryRemovalMessages.notRemovable(files)
        case let .alreadyRemoving(files): LibraryRemovalMessages.alreadyRemoving(files)
        }
    }
}
