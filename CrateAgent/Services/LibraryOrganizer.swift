import Foundation

/// Bulk file-organization orchestrator. Finds files whose current
/// path doesn't match their canonical destination
/// (`<MusicFolder>/<Letter>/<rendered-filename>.<ext>`, per
/// Invariants 5–6) and moves them there in one undoable batch.
///
/// First use case: pulling tracks from `~/Downloads`, soulseek dirs,
/// etc. into the user's main music folder. Same primitive also
/// covers cleanup of already-inside files that are in the wrong
/// letter bucket or have a non-canonical filename.
///
/// Built on the same primitives as the single-file rename dialog:
///   1. `RenameDestinationPlanner.destination` computes the
///      canonical URL from artist/title/etc. metadata.
///   2. OperationEngine validates the original plan and moves audio
///      with its journaled rename under a compensated transaction.
///   3. Successful renames share one coalesced Serato rewrite.
///
/// Per-file errors don't abort the loop — the move set is
/// best-effort and partial outcomes are reported in
/// `Outcome.errors`. Every successful move shares one `batch_id`
/// so Undo on History reverts the whole sweep.
public actor LibraryOrganizer {
    /// One proposed move. Returned from `findMoves` for the
    /// preview UI; consumed by `organize` at apply time.
    public struct Plan: Identifiable, Hashable, Sendable {
        public let membershipRevision: Int64
        public let metadataRequirements: OrganizeMetadataRequirements
        public let id: Int64
        public let sourcePath: String
        public let destinationPath: String
        /// `true` when the source is outside the configured music
        /// folder (the priority case from issue #57 —
        /// `~/Downloads`, etc.). Drives the default filter in the
        /// Organize view.
        public let isOutsideMusicFolder: Bool

        public init(
            id: Int64,
            sourcePath: String,
            destinationPath: String,
            isOutsideMusicFolder: Bool,
            membershipRevision: Int64 = 0,
            metadataRequirements: OrganizeMetadataRequirements = .essential
        ) {
            self.id = id
            self.membershipRevision = membershipRevision
            self.metadataRequirements = metadataRequirements
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
            self.isOutsideMusicFolder = isOutsideMusicFolder
        }
    }

    struct BlockedFile: Sendable {
        let id: Int64
        let missingFields: [SeratoMetadataField]
        let isOutsideMusicFolder: Bool
        var conflictReason: String?
    }

    struct Preview: Sendable {
        let plans: [Plan]
        let blockedFiles: [BlockedFile]
    }

    public struct Outcome: Sendable {
        public let batchId: String
        public let movedCount: Int
        public let failureCount: Int
        public let errors: [String]
    }

    public enum OrganizerError: LocalizedError, Equatable {
        case noPlans
        case sourceNoLongerExists(path: String)
        case destinationAlreadyExists(path: String)

        public var errorDescription: String? {
            switch self {
            case .noPlans:
                "Nothing to organize — every file is already in its canonical location."
            case .sourceNoLongerExists:
                "Source file no longer exists."
            case .destinationAlreadyExists:
                "Destination already exists — re-scan and retry."
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

    /// Pure planner. Compute the proposed destination for every
    /// file; emit a `Plan` for any file whose current path doesn't
    /// match. Disambiguates colliding destinations within the plan
    /// set with sequential `(1)`, `(2)`, ... suffixes.
    ///
    /// `findMoves` is `nonisolated static` so the view can call it
    /// without round-tripping through the actor — pure computation,
    /// no engine access.
    public nonisolated static func findMoves(
        in files: [some HygieneFileSource], musicFolder: URL, template: String
    ) -> [Plan] {
        findMoves(in: files, musicFolder: musicFolder, template: template, checkCancellation: {})
    }

    public nonisolated static func findMoves(
        in files: [some HygieneFileSource],
        musicFolder: URL,
        template: String,
        checkCancellation: () throws -> Void
    ) rethrows -> [Plan] {
        try preview(in: files, musicFolder: musicFolder, template: template, checkCancellation: checkCancellation).plans
    }

    nonisolated static func preview(
        in files: [some HygieneFileSource], musicFolder: URL, template: String,
        readiness: LibrarySyncReadiness? = nil,
        checkCancellation: () throws -> Void
    ) rethrows -> Preview {
        let requirements = OrganizeMetadataRequirements(template: template)
        var blockedFiles: [BlockedFile] = []
        let musicFolderPath = musicFolder.path
        var plans: [Plan] = []
        var claimedDestinations: Set<String> = []
        var nextSuffixByDestination: [String: Int] = [:]

        for file in files {
            try checkCancellation()
            guard let fileId = file.id else { continue }
            let isOutside = !file.path.hasPrefix(musicFolderPath + "/") && file.path != musicFolderPath
            if let conflict = readiness?.conflictPath(for: SeratoConflictTarget(fileIDs: [fileId], paths: [file.path])) {
                blockedFiles.append(BlockedFile(id: fileId, missingFields: [], isOutsideMusicFolder: isOutside, conflictReason: SeratoConflictMessages.blocked(conflict)))
                continue
            }
            let missing = requirements.missingFields(in: file)
            guard missing.isEmpty else {
                blockedFiles.append(BlockedFile(id: fileId, missingFields: missing, isOutsideMusicFolder: isOutside))
                continue
            }
            let canonical = RenameDestinationPlanner.destination(
                forFile: file,
                musicFolder: musicFolder,
                template: template
            )
            // Skip if already canonical (case-sensitive path
            // comparison; the filesystem is case-insensitive on
            // default APFS volumes but `==` here is the right
            // gate — we don't want to "fix" a casing-only
            // difference as if it were a real move).
            if file.path == canonical.path {
                continue
            }
            let resolvedDestination = try disambiguatedPath(
                desired: canonical.path,
                takenWithinBatch: claimedDestinations,
                nextSuffixByDestination: &nextSuffixByDestination,
                checkCancellation: checkCancellation
            )
            if let conflict = readiness?.conflictPath(for: SeratoConflictTarget(fileIDs: [fileId], paths: [file.path, resolvedDestination])) {
                blockedFiles.append(BlockedFile(id: fileId, missingFields: [], isOutsideMusicFolder: isOutside, conflictReason: SeratoConflictMessages.blocked(conflict)))
                continue
            }
            claimedDestinations.insert(resolvedDestination)
            plans.append(Plan(
                id: fileId,
                sourcePath: file.path,
                destinationPath: resolvedDestination,
                isOutsideMusicFolder: isOutside,
                membershipRevision: file.membershipRevision,
                metadataRequirements: requirements
            ))
        }
        return Preview(plans: plans, blockedFiles: blockedFiles)
    }

    /// Per-file compensated transactions preserve partial outcomes;
    /// coalescing their Serato writes avoids rewriting V2 per track.
    @discardableResult
    public func organize(
        _ plans: [Plan],
        batchId: String? = nil
    ) async throws -> Outcome {
        guard !plans.isEmpty else { throw OrganizerError.noPlans }

        let effectiveBatchId = batchId ?? "organize-\(UUID().uuidString)"
        await note("Organizing \(plans.count) file\(plans.count == 1 ? "" : "s")…")

        let outcome = try await operationEngine.organizeFiles(plans, batchId: effectiveBatchId)
        await note("Organize complete — moved \(outcome.movedCount), \(outcome.failureCount) skipped")
        return outcome
    }

    // MARK: - Internals

    private func note(_ message: String) async {
        guard let log = activityLog else { return }
        await log.log(message, category: .rename)
    }

    /// If `desired` collides with another path already claimed in
    /// this organize batch, append ` (1)`, ` (2)`, ... before the
    /// extension until unique. Remember the next suffix so a repeated
    /// destination does not restart the search through earlier claims.
    private nonisolated static func disambiguatedPath(
        desired: String,
        takenWithinBatch: Set<String>,
        nextSuffixByDestination: inout [String: Int],
        checkCancellation: () throws -> Void
    ) rethrows -> String {
        if !takenWithinBatch.contains(desired) {
            return desired
        }
        let url = URL(fileURLWithPath: desired)
        let nameWithoutExt = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let parent = url.deletingLastPathComponent()
        var attempt = nextSuffixByDestination[desired, default: 1]
        while true {
            try checkCancellation()
            let suffix = " (\(attempt))"
            let candidateFilename = ext.isEmpty
                ? "\(nameWithoutExt)\(suffix)"
                : "\(nameWithoutExt)\(suffix).\(ext)"
            let candidate = parent
                .appendingPathComponent(candidateFilename)
                .path
            attempt += 1
            if !takenWithinBatch.contains(candidate) {
                nextSuffixByDestination[desired] = attempt
                return candidate
            }
        }
    }
}
