import Foundation

/// Bulk library-relocation. Rebases every tracked file's path from
/// one music-folder root to another, preserving the relative
/// structure (letter buckets etc.) inside.
///
/// Concrete use case from issue #59: the project owner ended up
/// with files sprawled across `~/Music/<Letter>/` because the
/// onboarding default put them there. The migrator moves them
/// into `~/Music/_DJ_Library_/<Letter>/` in one undoable batch.
///
/// Architecturally identical to `LibraryOrganizer` (file move +
/// `renameFile` mutation through `OperationEngine` under one
/// `batch_id`). Difference is the destination calculation: organize
/// re-renders filenames via the template, migrate just rebases the
/// prefix.
///
/// Same-volume only for SP-1 (issue #69 tracks cross-volume).
/// Files not under the old root are skipped — Apple Music library
/// and other unrelated content in `~/Music/` stays untouched.
public actor LibraryMigrator {

    public struct Plan: Identifiable, Hashable, Sendable {
        public let id: Int64
        public let sourcePath: String
        public let destinationPath: String

        public init(id: Int64, sourcePath: String, destinationPath: String) {
            self.id = id
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
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

        public var errorDescription: String? {
            switch self {
            case .noPlans:
                return "Nothing to migrate — every tracked file is already under the new root."
            case .sameRoot:
                return "Source and destination are the same folder."
            case .crossVolumeUnsupported(let reason):
                return "Cross-volume migration isn't supported yet (\(reason))."
            case .sourceNoLongerExists:
                return "Source no longer exists."
            case .destinationAlreadyExists:
                return "Destination already exists — re-scan and retry."
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
    ) -> [Plan] {
        let oldPrefix = ensureTrailingSlash(oldRoot.path)
        let newPrefix = ensureTrailingSlash(newRoot.path)
        guard oldPrefix != newPrefix else { return [] }

        var plans: [Plan] = []
        var claimed: Set<String> = []
        for file in files {
            guard let fileId = file.id else { continue }
            guard file.path.hasPrefix(oldPrefix) else { continue }
            let relative = String(file.path.dropFirst(oldPrefix.count))
            // Skip if the file is already at the canonical
            // location under the new root — covers the rerun case.
            let proposed = newPrefix + relative
            if file.path == proposed {
                continue
            }
            let resolved = disambiguatedPath(desired: proposed, taken: claimed)
            claimed.insert(resolved)
            plans.append(Plan(
                id: fileId,
                sourcePath: file.path,
                destinationPath: resolved
            ))
        }
        return plans
    }

    /// Apply the migration. Each file: ensure parent dir exists,
    /// `moveItem` on disk, then fire `renameFile` to update Serato
    /// + DB under the shared batch_id. Best-effort — per-file
    /// failures append to `Outcome.errors` and the loop continues.
    /// After success, the caller updates
    /// `UserPreferences.watchedMusicFolder` to the new root.
    @discardableResult
    public func migrate(
        _ plans: [Plan],
        batchId: String? = nil
    ) async throws -> Outcome {
        guard !plans.isEmpty else { throw MigratorError.noPlans }

        let effectiveBatchId = batchId ?? "migrate-\(UUID().uuidString)"
        await note("Migrating \(plans.count) file\(plans.count == 1 ? "" : "s") to the new library root…")

        var moved = 0
        var failures = 0
        var errors: [String] = []
        for plan in plans {
            do {
                try await applyOne(plan, batchId: effectiveBatchId)
                moved += 1
            } catch {
                failures += 1
                let filename = (plan.sourcePath as NSString).lastPathComponent
                errors.append("\(filename): \(error.localizedDescription)")
                await note("Skipped \(filename) — \(error.localizedDescription)")
            }
        }

        await note("Migration complete — moved \(moved), \(failures) skipped")
        return Outcome(
            batchId: effectiveBatchId,
            movedCount: moved,
            failureCount: failures,
            errors: errors
        )
    }

    // MARK: - Internals

    private func applyOne(_ plan: Plan, batchId: String) async throws {
        let source = URL(fileURLWithPath: plan.sourcePath)
        let destination = URL(fileURLWithPath: plan.destinationPath)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: source.path) else {
            throw MigratorError.sourceNoLongerExists(path: source.path)
        }
        if fileManager.fileExists(atPath: destination.path) {
            throw MigratorError.destinationAlreadyExists(path: destination.path)
        }

        let parentDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )

        await note("Moving \(source.lastPathComponent) → \(destination.path)")
        try fileManager.moveItem(at: source, to: destination)

        _ = try await operationEngine.apply(
            .renameFile(RenameFilePayload(
                fileId: plan.id,
                newPath: destination.path
            )),
            batchId: batchId
        )
    }

    private func note(_ message: String) async {
        guard let log = activityLog else { return }
        await log.log(message, category: .rename)
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
        if !taken.contains(desired) { return desired }
        let url = URL(fileURLWithPath: desired)
        let nameWithoutExt = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let parent = url.deletingLastPathComponent()
        for attempt in 1...1000 {
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
