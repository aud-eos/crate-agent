import Foundation
import GRDB

/// Bulk library-relocation. Rebases every tracked file's path from
/// one music-folder root to another, preserving the relative
/// structure (letter buckets etc.) inside.
///
/// Concrete use case from issue #59: the project owner ended up
/// with files sprawled across `~/Music/<Letter>/` because the
/// onboarding default put them there. The migrator moves them
/// into `~/Music/_DJ_Library_/<Letter>/` in one undoable batch.
///
/// Migration and Organize share guarded physical moves through
/// OperationEngine, but calculate their destinations separately.
///
/// Same-volume only for SP-1 (issue #69 tracks cross-volume).
/// Files not under the old root are skipped — Apple Music library
/// and other unrelated content in `~/Music/` stays untouched.
public actor LibraryMigrator {
    public struct Destination: Identifiable, Hashable, Sendable {
        public let id: Int64
        public let sourcePath: String
        public let destinationPath: String
        public let membershipToken: FileMembershipToken

        public init(id: Int64, sourcePath: String, destinationPath: String, membershipRevision: Int64) {
            self.id = id
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
            membershipToken = FileMembershipToken(fileId: id, revision: membershipRevision)
        }
    }

    public struct Plan: Identifiable, Hashable, Sendable {
        public var id: Int64 {
            destination.id
        }

        public var sourcePath: String {
            destination.sourcePath
        }

        public var destinationPath: String {
            destination.destinationPath
        }

        public var membershipToken: FileMembershipToken {
            destination.membershipToken
        }

        private let destination: Destination
        let sourceIdentity: SeratoSourceIdentity

        fileprivate init(destination: Destination, sourceIdentity: SeratoSourceIdentity) {
            self.destination = destination
            self.sourceIdentity = sourceIdentity
        }
    }

    public struct Outcome: Sendable {
        public let batchId: String
        public let movedCount: Int
        public let failureCount: Int
        public let errors: [String]
    }

    public enum MigratorError: LocalizedError, Equatable {
        case noPlans
        case sameRoot
        case crossVolumeUnsupported(reason: String)
        case sourceNoLongerExists(path: String)
        case destinationAlreadyExists(path: String)
        case cannotInspectSource(path: String)

        public var errorDescription: String? {
            switch self {
            case .noPlans:
                return "Nothing to migrate — every tracked file is already under the new root."
            case .sameRoot:
                return "Source and destination are the same folder."
            case let .crossVolumeUnsupported(reason):
                return "Cross-volume migration isn't supported yet (\(reason))."
            case .sourceNoLongerExists:
                return "Source no longer exists."
            case .destinationAlreadyExists:
                return "Destination already exists — re-scan and retry."
            case let .cannotInspectSource(path):
                return "Cannot inspect \(path). Check that the audio is available, then re-scan."
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

    /// Build a plan to migrate every file under `oldRoot` to the
    /// equivalent path under `newRoot`. Files whose current path
    /// isn't a child of `oldRoot` are skipped (e.g., files the
    /// user already manually moved elsewhere). Disambiguates
    /// destination collisions within the planned set with
    /// `(1)`, `(2)`, ... suffixes.
    ///
    /// `findMoves` is `nonisolated static` so the destination
    /// preview UI can call it without round-tripping through the
    /// actor — pure path arithmetic, no engine access.
    public nonisolated static func findMoves<F: HygieneFileSource>(
        in files: [F],
        oldRoot: URL,
        newRoot: URL
    ) -> [Destination] {
        let oldPrefix = ensureTrailingSlash(oldRoot.path)
        let newPrefix = ensureTrailingSlash(newRoot.path)
        guard oldPrefix != newPrefix else { return [] }

        var plans: [Destination] = []
        var claimed: Set<String> = []
        for file in files {
            guard let fileId = file.id else { continue }
            guard requiresMove(file.path, oldPrefix: oldPrefix, newPrefix: newPrefix) else { continue }
            let relative = String(file.path.dropFirst(oldPrefix.count))
            // Skip if the file is already at the canonical
            // location under the new root — covers the rerun case.
            let proposed = newPrefix + relative
            if file.path == proposed {
                continue
            }
            let resolved = disambiguatedPath(desired: proposed, taken: claimed)
            claimed.insert(resolved)
            plans.append(Destination(
                id: fileId,
                sourcePath: file.path,
                destinationPath: resolved,
                membershipRevision: file.membershipRevision
            ))
        }
        return plans
    }

    public nonisolated static func remainingFileCount(in database: LibraryDatabase, oldRoot: URL, newRoot: URL) async throws -> Int {
        let oldPrefix = ensureTrailingSlash(oldRoot.path)
        let newPrefix = ensureTrailingSlash(newRoot.path)
        return try await database.writer.read { connection in
            let paths = try String.fetchAll(connection, sql: "SELECT path FROM files WHERE \(FileProcessingEligibility.activeSQL)")
            return paths.filter { path in requiresMove(path, oldPrefix: oldPrefix, newPrefix: newPrefix) }.count
        }
    }

    public nonisolated static func prepareMoves<F: HygieneFileSource>(
        in files: [F], oldRoot: URL, newRoot: URL
    ) throws -> [Plan] {
        try findMoves(in: files, oldRoot: oldRoot, newRoot: newRoot).map { destination in
            try Task.checkCancellation()
            let identity: SeratoSourceIdentity
            do { identity = try SeratoSourceIdentity.read(URL(fileURLWithPath: destination.sourcePath)) }
            catch { throw MigratorError.cannotInspectSource(path: destination.sourcePath) }
            return Plan(destination: destination, sourceIdentity: identity)
        }
    }

    @discardableResult
    public func migrate(
        _ plans: [Plan],
        batchId: String? = nil
    ) async throws -> Outcome {
        guard !plans.isEmpty else { throw MigratorError.noPlans }

        let effectiveBatchId = batchId ?? "migrate-\(UUID().uuidString)"
        await note("Migrating \(plans.count) file\(plans.count == 1 ? "" : "s") to the new library root…")

        let outcome = try await operationEngine.migrateFiles(plans, batchId: effectiveBatchId)
        for error in outcome.errors {
            await note(error)
        }
        await note("Migration complete — moved \(outcome.movedCount), \(outcome.failureCount) skipped")
        return outcome
    }

    private func note(_ message: String) async {
        guard let log = activityLog else { return }
        await log.log(message, category: .rename)
    }

    private nonisolated static func requiresMove(_ path: String, oldPrefix: String, newPrefix: String) -> Bool {
        oldPrefix != newPrefix && path.hasPrefix(oldPrefix)
            && !(newPrefix.hasPrefix(oldPrefix) && path.hasPrefix(newPrefix))
    }

    /// Ensure the directory path ends with `/` so `hasPrefix`
    /// matches whole path components — without this, `/Music`
    /// would match `/Music Folder` as well as `/Music/A/...`.
    private nonisolated static func ensureTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    private nonisolated static func disambiguatedPath(
        desired: String,
        taken: Set<String>
    ) -> String {
        if !taken.contains(desired) {
            return desired
        }
        let url = URL(fileURLWithPath: desired)
        let nameWithoutExt = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let parent = url.deletingLastPathComponent()
        for attempt in 1 ... 1000 {
            let candidateFilename = ext.isEmpty
                ? "\(nameWithoutExt) (\(attempt))"
                : "\(nameWithoutExt) (\(attempt)).\(ext)"
            let candidate = parent.appendingPathComponent(candidateFilename).path
            if !taken.contains(candidate) {
                return candidate
            }
        }
        return desired
    }
}
