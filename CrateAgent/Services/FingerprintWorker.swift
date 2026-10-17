import Foundation
import GRDB
import os.log

/// Background pool that computes Chromaprint fingerprints for every
/// indexed file. Drives `files.chromaprint_fingerprint` and
/// `files.fingerprint_status` from `.pending` to `.done`/`.failed`.
///
/// The fingerprint is the canonical track-identity primitive (Rule 4):
/// SP-2's MusicBrainz auto-tagger consumes it to look up Recording IDs,
/// SP-1's library state stays usable without it (a file with status
/// `.pending` is still indexed, just not yet linked to a `tracks` row).
///
/// Design:
/// - actor-isolated state (counters, current task) so progress
///   reporting and start/stop are race-free
/// - bounded concurrency: `activeProcessorCount / 4` (min 1) — leaves
///   headroom for UI + the Serato sync pipeline
/// - resumable: state lives in the `files` table, so a relaunch picks
///   up wherever we stopped
/// - injectable fingerprint function so tests don't need real audio
///   fixtures
/// - progress is pushed via a handler closure, mirroring LibraryScanner;
///   AppServices bridges it onto a `@Published` for SwiftUI
public actor FingerprintWorker {
    public struct Progress: Sendable, Equatable {
        public let totalDone: Int
        public let totalFailed: Int
        public let totalPending: Int
        public let lastFingerprintedPath: String?
        public let error: String?

        public init(totalDone: Int, totalFailed: Int, totalPending: Int, lastFingerprintedPath: String?, error: String? = nil) {
            self.totalDone = totalDone
            self.totalFailed = totalFailed
            self.totalPending = totalPending
            self.lastFingerprintedPath = lastFingerprintedPath
            self.error = error
        }
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void
    public typealias FingerprintFunction = @Sendable (String) throws -> [UInt32]

    private static let logger = Logger(
        subsystem: "com.crateagent.app",
        category: "FingerprintWorker"
    )

    private let readiness: LibrarySyncReadiness?
    private let database: LibraryDatabase
    private let concurrency: Int
    private let fingerprintFunction: FingerprintFunction
    private let pollIntervalNanos: UInt64
    private let batchCooldownNanos: UInt64

    private var progressHandler: ProgressHandler?
    private var workTask: Task<Void, Never>?
    private var runID: UUID?
    private var restartRequested = false
    private var restartProgressHandler: ProgressHandler?
    public private(set) var lastError: String?
    private var totalDone: Int = 0
    private var totalFailed: Int = 0

    public init(
        database: LibraryDatabase,
        concurrency: Int? = nil,
        fingerprintFunction: @escaping FingerprintFunction = { try fingerprintAudioFile(filePath: $0) },
        pollIntervalSeconds: Double = 5,
        batchCooldownMillis: UInt64 = 200,
        readiness: LibrarySyncReadiness? = nil
    ) {
        self.readiness = readiness
        self.database = database
        // Conservative default: a *quarter* of the cores. Earlier
        // versions used cores - 2 which pegged a real 32k-track
        // library at full CPU on every available core, making the
        // user's machine unusable. Fingerprinting is a background
        // task — taking 4× longer in wall time but leaving the
        // user's computer responsive is the right tradeoff.
        let defaultConcurrency = max(1, ProcessInfo.processInfo.activeProcessorCount / 4)
        self.concurrency = max(1, concurrency ?? defaultConcurrency)
        self.fingerprintFunction = fingerprintFunction
        pollIntervalNanos = UInt64(pollIntervalSeconds * 1_000_000_000)
        batchCooldownNanos = batchCooldownMillis * 1_000_000
    }

    /// Start the background loop, or resume after an in-flight stop finishes.
    public func start(progress: ProgressHandler? = nil) {
        if let workTask {
            if workTask.isCancelled {
                restartRequested = true
                restartProgressHandler = progress
            }
            return
        }
        progressHandler = progress
        let runID = UUID()
        self.runID = runID
        lastError = nil

        let database = database
        let concurrency = concurrency
        let fingerprintFunction = fingerprintFunction
        let pollIntervalNanos = pollIntervalNanos
        let workerRef = self
        workTask = Task.detached(priority: .background) {
            await workerRef.runLoop(
                database: database,
                concurrency: concurrency,
                fingerprintFunction: fingerprintFunction,
                pollIntervalNanos: pollIntervalNanos,
                runID: runID
            )
        }
    }

    /// Cancel the loop. In-flight fingerprints complete; no new ones
    /// start. Safe to call multiple times.
    public func stop() {
        restartRequested = false
        restartProgressHandler = nil
        workTask?.cancel()
    }

    /// Wait for the worker to drain — used by tests so they don't
    /// need to busy-poll. Returns when `runLoop` exits, which only
    /// happens after `stop()`, task cancellation, or a reported infrastructure error.
    public func waitUntilStopped() async {
        await workTask?.value
    }

    /// Run one full sweep of the pending queue and return — used by
    /// tests that want deterministic completion without managing the
    /// long-running loop. The instance is reusable afterward; calling
    /// this again will pick up any newly-pending rows.
    @discardableResult
    public func processAllPendingOnce() async throws -> Progress {
        let pendingCount = try await fetchPendingCount()
        if pendingCount > 0 {
            let batch = try await fetchPendingBatch(limit: max(pendingCount, concurrency * 4))
            try await processBatch(
                batch,
                totalPending: pendingCount,
                fingerprintFunction: fingerprintFunction
            )
        }
        return try await Progress(
            totalDone: totalDone,
            totalFailed: totalFailed,
            totalPending: fetchPendingCount(),
            lastFingerprintedPath: nil
        )
    }

    // MARK: - Loop

    private func runLoop(
        database _: LibraryDatabase,
        concurrency: Int,
        fingerprintFunction: @escaping FingerprintFunction,
        pollIntervalNanos: UInt64,
        runID: UUID
    ) async {
        Self.logger.info("FingerprintWorker started (concurrency=\(concurrency))")
        defer {
            if self.runID == runID {
                workTask = nil
                self.runID = nil
                if restartRequested {
                    let progress = restartProgressHandler
                    restartRequested = false
                    restartProgressHandler = nil
                    start(progress: progress)
                }
            }
        }
        while !Task.isCancelled {
            var pendingCount = 0
            do {
                pendingCount = try await fetchPendingCount()
                if pendingCount == 0 {
                    try? await Task.sleep(nanoseconds: pollIntervalNanos)
                    continue
                }
                let batch = try await fetchPendingBatch(limit: concurrency * 4)
                if batch.isEmpty {
                    try? await Task.sleep(nanoseconds: pollIntervalNanos)
                    continue
                }
                try await processBatch(batch, totalPending: pendingCount, fingerprintFunction: fingerprintFunction)
            } catch is LibrarySyncReadinessError {
                try? await Task.sleep(nanoseconds: pollIntervalNanos)
                continue
            } catch is SeratoPathConflictError {
                try? await Task.sleep(nanoseconds: pollIntervalNanos)
                continue
            } catch {
                guard !Task.isCancelled, self.runID == runID else { return }
                lastError = "Fingerprint processing stopped: \(error.localizedDescription)"
                progressHandler?(Progress(totalDone: totalDone, totalFailed: totalFailed, totalPending: pendingCount,
                                          lastFingerprintedPath: nil, error: lastError))
                return
            }

            // Cooperative cooldown so we don't pin CPU continuously
            // across batches. Even at 200ms per batch, this dwarfs
            // the fingerprint work itself in % CPU dropped — the
            // user's machine stays responsive between bursts.
            if batchCooldownNanos > 0 {
                try? await Task.sleep(nanoseconds: batchCooldownNanos)
            }
        }
        Self.logger.info("FingerprintWorker stopped")
    }

    private func processBatch(
        _ batch: [FileRecord],
        totalPending: Int,
        fingerprintFunction: @escaping FingerprintFunction
    ) async throws {
        let authorization = try readiness?.capture()
        try Task.checkCancellation()
        // Build a dedup plan: copy from already-done byte-twins
        // where possible, fingerprint one representative per
        // (size, hash) group and propagate to siblings.
        let eligibleBatch = batch.filter { file in readiness?.conflictPath(for: .file(file)) == nil }
        let plan = try await planBatch(eligibleBatch)
        let database = database

        var representativeResults: [(BatchPlan.Group, ProcessResult)] = []
        representativeResults.reserveCapacity(plan.toFingerprint.count)

        try await withThrowingTaskGroup(of: GroupResult.self) { group in
            var iterator = plan.toFingerprint.enumerated().makeIterator()

            // Seed `concurrency` representative fingerprint tasks.
            for _ in 0 ..< concurrency {
                guard let (index, assignment) = iterator.next() else { break }
                let representative = assignment.representative
                group.addTask {
                    let result = try await Self.runOne(
                        file: representative, database: database, function: fingerprintFunction, authorization: authorization
                    )
                    return GroupResult(index: index, result: result)
                }
            }

            while let groupResult = try await group.next() {
                let assignment = plan.toFingerprint[groupResult.index]
                representativeResults.append((assignment, groupResult.result))
                if !Task.isCancelled, let (index, next) = iterator.next() {
                    let representative = next.representative
                    group.addTask {
                        let result = try await Self.runOne(
                            file: representative, database: database, function: fingerprintFunction, authorization: authorization
                        )
                        return GroupResult(index: index, result: result)
                    }
                }
            }
        }

        // Flush plan in one transaction: copy-from-existing rows +
        // representative results (propagated to siblings).
        try await flushBatchPlan(
            plan: plan,
            representativeResults: representativeResults,
            totalPending: totalPending, authorization: authorization
        )
    }

    private func flushBatchPlan(
        plan: BatchPlan,
        representativeResults: [(BatchPlan.Group, ProcessResult)],
        totalPending _: Int,
        authorization: LibrarySyncReadiness.Authorization?
    ) async throws {
        let totalFiles = plan.toCopyFromExistingTwin.count
            + representativeResults.reduce(0) { $0 + 1 + $1.0.siblingIds.count }
        guard totalFiles > 0 else { return }

        let counts = try await database.writer.write { database in
            let files = try FileRecord.filter(Array(plan.membershipTokens.keys).contains(Column("id"))).fetchAll(database)
                .filter { file in authorization?.gate.conflictPath(for: .file(file)) == nil }
            let permittedIDs = Set(files.compactMap(\.id))
            return try FingerprintPersistence.withAuthorization(authorization, targets: files.map(SeratoConflictTarget.file)) {
                var completed = 0
                var failed = 0
                for entry in plan.toCopyFromExistingTwin where permittedIDs.contains(entry.fileId) {
                    if try FingerprintPersistence.write(
                        fileID: entry.fileId, fingerprint: entry.fingerprint, status: .done,
                        requirePendingStatus: true, expectedMembershipToken: plan.membershipTokens[entry.fileId]!, in: database
                    ) {
                        completed += 1
                    }
                }
                for (assignment, result) in representativeResults {
                    let fingerprint: Data?
                    let status: FingerprintStatus
                    switch result.outcome {
                    case let .success(bytes): fingerprint = bytes; status = .done
                    case .failure: fingerprint = nil; status = .failed
                    case .notDecoded: continue
                    }
                    for fileID in [result.fileId] + assignment.siblingIds where permittedIDs.contains(fileID) {
                        if try FingerprintPersistence.write(
                            fileID: fileID, fingerprint: fingerprint, status: status,
                            requirePendingStatus: true, expectedMembershipToken: plan.membershipTokens[fileID]!, in: database
                        ) {
                            if status == .done {
                                completed += 1
                            } else {
                                failed += 1
                            }
                        }
                    }
                }
                return (completed, failed)
            }
        }
        let doneCount = counts.0
        let failedCount = counts.1
        let lastPath = representativeResults.last?.1.path

        totalDone += doneCount
        totalFailed += failedCount

        try await emitProgress(
            lastPath: lastPath,
            pending: fetchPendingCount()
        )
    }

    // MARK: - Batch planning (byte-twin dedup)

    /// Build the dedup plan for a batch. Three sources of work:
    /// - `toCopyFromExistingTwin`: a row outside the batch already
    ///   has the same (file_size, lightweight_hash) with a non-null
    ///   fingerprint and `fingerprint_status = .done`. Copy that
    ///   fingerprint, skip the decode entirely.
    /// - `toFingerprint[].representative`: one file per
    ///   (size, hash) group that has no DB twin gets fingerprinted;
    ///   the result fans out to `siblingIds`.
    /// - Files with no `lightweight_hash`: standalone groups of
    ///   one. They can't be deduplicated until backfill populates
    ///   their hash on a later scan.
    private struct GroupingKey: Hashable {
        let fileSize: Int64
        let hash: Data
    }

    private func planBatch(_ batch: [FileRecord]) async throws -> BatchPlan {
        var groups: [GroupingKey: [FileRecord]] = [:]
        var groupOrder: [GroupingKey] = []
        var standaloneFiles: [FileRecord] = []
        for file in batch {
            guard let hash = file.lightweightHash else {
                standaloneFiles.append(file)
                continue
            }
            let key = GroupingKey(fileSize: file.fileSize, hash: hash)
            if groups[key] == nil {
                groupOrder.append(key)
            }
            groups[key, default: []].append(file)
        }

        var copyFromExisting: [BatchPlan.CopyEntry] = []
        var assignments: [BatchPlan.Group] = []

        // Files with no hash: each is its own representative.
        for file in standaloneFiles {
            assignments.append(BatchPlan.Group(
                representative: file,
                siblingIds: []
            ))
        }

        // One DB query for every (file_size, lightweight_hash) group
        // in the batch. The previous shape — one query per group
        // serially — meant the batch's "is there a done twin?" check
        // fired N times per batch, awaiting each result. For a 32k-
        // track import (batches of 16, ~2k batches), that compounded
        // to ~32k DB round-trips just for planning.
        let inBatchIds: Set<Int64> = Set(batch.compactMap(\.id))
        let twins = try await lookupExistingDoneFingerprints(
            for: groupOrder,
            excludingFileIds: inBatchIds
        )

        for key in groupOrder {
            let groupFiles = groups[key]!
            if let fingerprint = twins[key] {
                for file in groupFiles {
                    guard let identifier = file.id else { continue }
                    copyFromExisting.append(
                        BatchPlan.CopyEntry(fileId: identifier, fingerprint: fingerprint)
                    )
                }
                continue
            }

            // No external twin: fingerprint one representative,
            // copy result to siblings.
            let representative = groupFiles[0]
            let siblings = groupFiles.dropFirst().compactMap(\.id)
            assignments.append(BatchPlan.Group(
                representative: representative,
                siblingIds: Array(siblings)
            ))
        }

        return BatchPlan(
            membershipTokens: Dictionary(uniqueKeysWithValues: batch.compactMap { file in
                file.id.map { fileID in (fileID, FileMembershipToken(fileId: fileID, revision: file.membershipRevision)) }
            }),
            toCopyFromExistingTwin: copyFromExisting,
            toFingerprint: assignments
        )
    }

    /// Single-query twin lookup for an entire batch's worth of
    /// `(file_size, lightweight_hash)` groups. Returns a map from
    /// grouping key → existing done fingerprint for every group that
    /// has one. Groups without a twin are absent from the map.
    private func lookupExistingDoneFingerprints(
        for keys: [GroupingKey],
        excludingFileIds: Set<Int64>
    ) async throws -> [GroupingKey: Data] {
        guard !keys.isEmpty else { return [:] }

        // SQLite row-value IN: `(col1, col2) IN (VALUES (?,?), (?,?), ...)`.
        // Available since SQLite 3.15; macOS ships modern SQLite.
        let placeholders = keys.map { _ in "(?, ?)" }.joined(separator: ", ")
        let excludeList = excludingFileIds.map(String.init).joined(separator: ",")
        let excludeClause = excludeList.isEmpty ? "" : " AND id NOT IN (\(excludeList))"
        let sql = """
        SELECT file_size, lightweight_hash, chromaprint_fingerprint
        FROM files
        WHERE fingerprint_status = 'done'
          AND chromaprint_fingerprint IS NOT NULL
          AND (file_size, lightweight_hash) IN (VALUES \(placeholders))
        \(excludeClause)
        """
        var arguments: [DatabaseValueConvertible] = []
        for key in keys {
            arguments.append(key.fileSize)
            arguments.append(key.hash)
        }

        struct TwinRow: FetchableRecord, Decodable {
            let fileSize: Int64
            let lightweightHash: Data
            let chromaprintFingerprint: Data
            static let databaseColumnDecodingStrategy =
                DatabaseColumnDecodingStrategy.convertFromSnakeCase
        }
        let queryArguments = StatementArguments(arguments)!
        let rows = try await database.writer.read { db -> [TwinRow] in
            try TwinRow.fetchAll(
                db,
                sql: sql,
                arguments: queryArguments
            )
        }
        // Multiple rows may share the same (size, hash) — pick
        // the first; any done fingerprint is interchangeable
        // since the byte twin guarantee asserts they're equal.
        var twins: [GroupingKey: Data] = [:]
        for row in rows {
            let key = GroupingKey(fileSize: row.fileSize, hash: row.lightweightHash)
            if twins[key] == nil {
                twins[key] = row.chromaprintFingerprint
            }
        }
        return twins
    }

    private static func runOne(
        file: FileRecord,
        database: LibraryDatabase,
        function: @escaping FingerprintFunction,
        authorization: LibrarySyncReadiness.Authorization?
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        try authorization?.check()
        guard let fileId = file.id else {
            return ProcessResult(fileId: 0, path: file.path, outcome: .failure)
        }
        do {
            try await database.writer.read { database in
                let current = try FileProcessingEligibility.currentFile(FileMembershipToken(fileId: fileId, revision: file.membershipRevision), in: database)
                try authorization?.check(target: .file(current))
            }
        } catch is FileProcessingEligibilityError {
            return ProcessResult(fileId: fileId, path: file.path, outcome: .notDecoded)
        } catch is SeratoPathConflictError {
            return ProcessResult(fileId: fileId, path: file.path, outcome: .notDecoded)
        }
        do {
            let hashes = try function(file.path)
            return ProcessResult(
                fileId: fileId,
                path: file.path,
                outcome: .success(FingerprintEncoder.serialize(hashes))
            )
        } catch {
            return ProcessResult(fileId: fileId, path: file.path, outcome: .failure)
        }
    }

    private func emitProgress(lastPath: String?, pending: Int) {
        let snapshot = Progress(
            totalDone: totalDone,
            totalFailed: totalFailed,
            totalPending: pending,
            lastFingerprintedPath: lastPath
        )
        progressHandler?(snapshot)
    }

    // MARK: - DB helpers

    private func fetchPendingCount() async throws -> Int {
        try await database.writer.read { db in
            try FileRecord
                .all().processableInLibrary()
                .filter(Column("fingerprint_status") == FingerprintStatus.pending.rawValue)
                .fetchCount(db)
        }
    }

    private func fetchPendingBatch(limit: Int) async throws -> [FileRecord] {
        let readiness = readiness
        return try await database.writer.read { database in
            var result: [FileRecord] = []
            var cursor: Int64 = 0
            let pageSize = min(max(limit, 32), 256)
            while result.count < limit {
                try Task.checkCancellation()
                let page = try FileRecord.all().processableInLibrary()
                    .filter(Column("fingerprint_status") == FingerprintStatus.pending.rawValue)
                    .filter(Column("id") > cursor).order(Column("id")).limit(pageSize).fetchAll(database)
                guard let lastID = page.last?.id else { break }
                cursor = lastID
                for file in page where readiness?.conflictPath(for: .file(file)) == nil {
                    result.append(file)
                    if result.count == limit {
                        break
                    }
                }
            }
            return result
        }
    }
}

private struct ProcessResult: Sendable {
    let fileId: Int64
    let path: String
    let outcome: Outcome

    enum Outcome: Sendable {
        case success(Data)
        case failure
        case notDecoded
    }
}

/// One representative result paired with the index of its
/// assignment in `BatchPlan.toFingerprint`, so we can pull the
/// sibling list back out at flush time without searching.
private struct GroupResult: Sendable {
    let index: Int
    let result: ProcessResult
}

/// Output of `planBatch` — the unit of work the FingerprintWorker
/// is about to do, factored so the same plan covers (a) files
/// whose byte-twin already has a fingerprint (free), (b)
/// representatives that need to be fingerprinted with their
/// fingerprint copied to siblings, and (c) standalone files with
/// no hash to dedup against.
struct BatchPlan: Sendable, Equatable {
    let membershipTokens: [Int64: FileMembershipToken]
    /// Files that get a fingerprint copied from a DB row whose
    /// (file_size, lightweight_hash) matches. No Chromaprint work
    /// needed at all — these write straight to the DB at flush
    /// time.
    let toCopyFromExistingTwin: [CopyEntry]
    /// One Chromaprint run per group; the resulting hash gets
    /// fanned out across the representative + every sibling.
    let toFingerprint: [Group]

    struct CopyEntry: Sendable, Equatable {
        let fileId: Int64
        let fingerprint: Data
    }

    struct Group: Sendable, Equatable {
        let representative: FileRecord
        let siblingIds: [Int64]
    }
}
