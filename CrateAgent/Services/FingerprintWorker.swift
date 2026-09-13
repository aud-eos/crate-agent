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
/// - bounded concurrency: `activeProcessorCount - 2` (min 1) — leaves
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
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void
    public typealias FingerprintFunction = @Sendable (String) throws -> [UInt32]

    private static let logger = Logger(
        subsystem: "com.crateagent.app",
        category: "FingerprintWorker"
    )

    private let database: LibraryDatabase
    private let concurrency: Int
    private let fingerprintFunction: FingerprintFunction
    private let pollIntervalNanos: UInt64
    private let batchCooldownNanos: UInt64

    private var progressHandler: ProgressHandler?
    private var workTask: Task<Void, Never>?
    private var totalDone: Int = 0
    private var totalFailed: Int = 0

    public init(
        database: LibraryDatabase,
        concurrency: Int? = nil,
        fingerprintFunction: @escaping FingerprintFunction = { try fingerprintAudioFile(filePath: $0) },
        pollIntervalSeconds: Double = 5,
        batchCooldownMillis: UInt64 = 200
    ) {
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
        self.pollIntervalNanos = UInt64(pollIntervalSeconds * 1_000_000_000)
        self.batchCooldownNanos = batchCooldownMillis * 1_000_000
    }

    /// Start the background loop. No-op if already running.
    public func start(progress: ProgressHandler? = nil) {
        guard workTask == nil else { return }
        progressHandler = progress

        let database = self.database
        let concurrency = self.concurrency
        let fingerprintFunction = self.fingerprintFunction
        let pollIntervalNanos = self.pollIntervalNanos
        let workerRef = self
        workTask = Task.detached(priority: .background) {
            await workerRef.runLoop(
                database: database,
                concurrency: concurrency,
                fingerprintFunction: fingerprintFunction,
                pollIntervalNanos: pollIntervalNanos
            )
        }
    }

    /// Cancel the loop. In-flight fingerprints complete; no new ones
    /// start. Safe to call multiple times.
    public func stop() {
        workTask?.cancel()
        workTask = nil
    }

    /// Wait for the worker to drain — used by tests so they don't
    /// need to busy-poll. Returns when `runLoop` exits, which only
    /// happens after `stop()` or task cancellation.
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
            await processBatch(
                batch,
                totalPending: pendingCount,
                fingerprintFunction: fingerprintFunction
            )
        }
        return Progress(
            totalDone: totalDone,
            totalFailed: totalFailed,
            totalPending: 0,
            lastFingerprintedPath: nil
        )
    }

    // MARK: - Loop

    private func runLoop(
        database: LibraryDatabase,
        concurrency: Int,
        fingerprintFunction: @escaping FingerprintFunction,
        pollIntervalNanos: UInt64
    ) async {
        Self.logger.info("FingerprintWorker started (concurrency=\(concurrency))")
        while !Task.isCancelled {
            let pendingCount: Int
            do {
                pendingCount = try await fetchPendingCount()
            } catch {
                Self.logger.error("Failed to fetch pending count: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(nanoseconds: pollIntervalNanos)
                continue
            }

            if pendingCount == 0 {
                try? await Task.sleep(nanoseconds: pollIntervalNanos)
                continue
            }

            let batch: [FileRecord]
            do {
                batch = try await fetchPendingBatch(limit: concurrency * 4)
            } catch {
                Self.logger.error("Failed to fetch pending batch: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(nanoseconds: pollIntervalNanos)
                continue
            }
            if batch.isEmpty { continue }

            await processBatch(
                batch,
                totalPending: pendingCount,
                fingerprintFunction: fingerprintFunction
            )

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
    ) async {
        // Build a dedup plan: copy from already-done byte-twins
        // where possible, fingerprint one representative per
        // (size, hash) group and propagate to siblings.
        let plan = await planBatch(batch)

        var representativeResults: [(BatchPlan.Group, ProcessResult)] = []
        representativeResults.reserveCapacity(plan.toFingerprint.count)

        await withTaskGroup(of: GroupResult.self) { group in
            var iterator = plan.toFingerprint.enumerated().makeIterator()

            // Seed `concurrency` representative fingerprint tasks.
            for _ in 0..<concurrency {
                guard let (index, assignment) = iterator.next() else { break }
                let representative = assignment.representative
                group.addTask {
                    let result = await Self.runOne(
                        file: representative, function: fingerprintFunction
                    )
                    return GroupResult(index: index, result: result)
                }
            }

            while let groupResult = await group.next() {
                let assignment = plan.toFingerprint[groupResult.index]
                representativeResults.append((assignment, groupResult.result))
                if !Task.isCancelled, let (index, next) = iterator.next() {
                    let representative = next.representative
                    group.addTask {
                        let result = await Self.runOne(
                            file: representative, function: fingerprintFunction
                        )
                        return GroupResult(index: index, result: result)
                    }
                }
            }
        }

        // Flush plan in one transaction: copy-from-existing rows +
        // representative results (propagated to siblings).
        await flushBatchPlan(
            plan: plan,
            representativeResults: representativeResults,
            totalPending: totalPending
        )
    }

    private func flushBatchPlan(
        plan: BatchPlan,
        representativeResults: [(BatchPlan.Group, ProcessResult)],
        totalPending: Int
    ) async {
        let totalFiles = plan.toCopyFromExistingTwin.count
            + representativeResults.reduce(0) { $0 + 1 + $1.0.siblingIds.count }
        guard totalFiles > 0 else { return }

        var doneCount = 0
        var failedCount = 0
        var lastPath: String?

        do {
            try await database.writer.write { db in
                // Step 1: copy-from-existing — files whose byte-twin
                // already had a fingerprint in the DB. No decode work
                // was needed; just write the same hash to this row.
                for entry in plan.toCopyFromExistingTwin {
                    try db.execute(
                        sql: """
                            UPDATE files
                            SET chromaprint_fingerprint = ?,
                                fingerprint_status = ?
                            WHERE id = ?
                            """,
                        arguments: [
                            entry.fingerprint,
                            FingerprintStatus.done.rawValue,
                            entry.fileId,
                        ]
                    )
                }

                // Step 2: representative results — write the outcome
                // to the representative AND to every sibling. Siblings
                // share the byte content so they share the outcome
                // (success or failure).
                for (assignment, result) in representativeResults {
                    let (hash, status): (Data?, FingerprintStatus) = {
                        switch result.outcome {
                        case .success(let bytes): return (bytes, .done)
                        case .failure: return (nil, .failed)
                        }
                    }()
                    // Apply to the representative.
                    try db.execute(
                        sql: """
                            UPDATE files
                            SET chromaprint_fingerprint = ?,
                                fingerprint_status = ?
                            WHERE id = ?
                            """,
                        arguments: [hash, status.rawValue, result.fileId]
                    )
                    // Propagate to siblings.
                    for siblingId in assignment.siblingIds {
                        try db.execute(
                            sql: """
                                UPDATE files
                                SET chromaprint_fingerprint = ?,
                                    fingerprint_status = ?
                                WHERE id = ?
                                """,
                            arguments: [hash, status.rawValue, siblingId]
                        )
                    }
                }
            }

            doneCount = plan.toCopyFromExistingTwin.count
            for (assignment, result) in representativeResults {
                switch result.outcome {
                case .success: doneCount += 1 + assignment.siblingIds.count
                case .failure: failedCount += 1 + assignment.siblingIds.count
                }
            }
            lastPath = representativeResults.last?.1.path
        } catch {
            Self.logger.error(
                "Batch persist of \(totalFiles) fingerprints failed: \(error.localizedDescription, privacy: .public)"
            )
            failedCount = totalFiles
        }

        totalDone += doneCount
        totalFailed += failedCount

        emitProgress(
            lastPath: lastPath,
            pending: max(0, totalPending - totalFiles)
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

    private func planBatch(_ batch: [FileRecord]) async -> BatchPlan {
        var groups: [GroupingKey: [FileRecord]] = [:]
        var groupOrder: [GroupingKey] = []
        var standaloneFiles: [FileRecord] = []
        for file in batch {
            guard let hash = file.lightweightHash else {
                standaloneFiles.append(file)
                continue
            }
            let key = GroupingKey(fileSize: file.fileSize, hash: hash)
            if groups[key] == nil { groupOrder.append(key) }
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
        let twins = await lookupExistingDoneFingerprints(
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
    ) async -> [GroupingKey: Data] {
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
        do {
            let rows = try await database.writer.read { db -> [TwinRow] in
                try TwinRow.fetchAll(
                    db,
                    sql: sql,
                    arguments: StatementArguments(arguments)
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
        } catch {
            Self.logger.error(
                "Batch twin lookup failed: \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    private static func runOne(
        file: FileRecord,
        function: @escaping FingerprintFunction
    ) async -> ProcessResult {
        guard let fileId = file.id else {
            return ProcessResult(fileId: 0, path: file.path, outcome: .failure)
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
                .filter(Column("fingerprint_status") == FingerprintStatus.pending.rawValue)
                .fetchCount(db)
        }
    }

    private func fetchPendingBatch(limit: Int) async throws -> [FileRecord] {
        try await database.writer.read { db in
            try FileRecord
                .filter(Column("fingerprint_status") == FingerprintStatus.pending.rawValue)
                .limit(limit)
                .fetchAll(db)
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
