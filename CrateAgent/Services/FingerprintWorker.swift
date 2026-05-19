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
        var completedResults: [ProcessResult] = []
        completedResults.reserveCapacity(batch.count)

        await withTaskGroup(of: ProcessResult.self) { group in
            var iterator = batch.makeIterator()

            // Seed up to `concurrency` worker tasks. The outer scope
            // owns the iterator (sequential), but each `runOne` body
            // executes concurrently — that's the standard bounded-
            // parallelism pattern with TaskGroup.
            for _ in 0..<concurrency {
                guard let next = iterator.next() else { break }
                group.addTask { await Self.runOne(file: next, function: fingerprintFunction) }
            }

            while let result = await group.next() {
                // Accumulate first; flush below in one transaction.
                // Per-file writes flood ValueObservation subscribers
                // (the library browser re-renders 13k rows on every
                // tick), beach-balling MainActor under heavy load.
                completedResults.append(result)
                if !Task.isCancelled, let next = iterator.next() {
                    group.addTask { await Self.runOne(file: next, function: fingerprintFunction) }
                }
            }
        }

        // One SQL transaction per batch instead of one per file.
        // ValueObservation now fires roughly once per ~40 files
        // (concurrency × 4) instead of once per file — MainActor
        // can render in between.
        await flushBatchResults(completedResults, totalPending: totalPending)
    }

    private func flushBatchResults(
        _ results: [ProcessResult],
        totalPending: Int
    ) async {
        guard !results.isEmpty else { return }
        do {
            try await database.writer.write { db in
                for result in results {
                    let (hash, status): (Data?, FingerprintStatus) = {
                        switch result.outcome {
                        case .success(let bytes): return (bytes, .done)
                        case .failure: return (nil, .failed)
                        }
                    }()
                    try db.execute(
                        sql: "UPDATE files SET chromaprint_fingerprint = ?, fingerprint_status = ? WHERE id = ?",
                        arguments: [hash, status.rawValue, result.fileId]
                    )
                }
            }
            for result in results {
                switch result.outcome {
                case .success: totalDone += 1
                case .failure: totalFailed += 1
                }
            }
        } catch {
            // Whole-batch failure: count every result as failed for
            // progress purposes and log. Future runs pick up the
            // still-pending rows (their DB state didn't change).
            Self.logger.error(
                "Batch persist of \(results.count) fingerprints failed: \(error.localizedDescription, privacy: .public)"
            )
            totalFailed += results.count
        }

        emitProgress(
            lastPath: results.last?.path,
            pending: max(0, totalPending - results.count)
        )
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
                outcome: .success(serializeHashesToBytes(hashes))
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

    // MARK: - Encoding (testable static)

    /// Little-endian byte-serialization of Chromaprint's `[UInt32]`.
    /// Length-prefix isn't needed — the blob's length divided by 4
    /// gives the count back, and the column is opaque to SQLite.
    static func serializeHashesToBytes(_ hashes: [UInt32]) -> Data {
        var data = Data(capacity: hashes.count * 4)
        for hash in hashes {
            var littleEndian = hash.littleEndian
            withUnsafeBytes(of: &littleEndian) { rawBuffer in
                data.append(contentsOf: rawBuffer)
            }
        }
        return data
    }

    static func deserializeHashesFromBytes(_ data: Data) -> [UInt32] {
        guard data.count % 4 == 0 else { return [] }
        var hashes: [UInt32] = []
        hashes.reserveCapacity(data.count / 4)
        data.withUnsafeBytes { rawBuffer in
            let typedBuffer = rawBuffer.bindMemory(to: UInt32.self)
            for hash in typedBuffer {
                hashes.append(UInt32(littleEndian: hash))
            }
        }
        return hashes
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
