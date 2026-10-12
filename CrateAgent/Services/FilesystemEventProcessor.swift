import Combine
import Foundation

public struct FilesystemEventBatch: Sendable {
    public let observations: [FSEventsObservation]
    public let highestEventID: UInt64
    public let requiresReconciliation: Bool
    public let deliverySequence: UInt64?
    public let replayBoundary: Bool
    public let historyComplete: Bool

    public init(observations: [FSEventsObservation], highestEventID: UInt64, deliverySequence: UInt64? = nil, replayBoundary: Bool = false, historyComplete: Bool = false) {
        self.deliverySequence = deliverySequence
        self.replayBoundary = replayBoundary
        self.historyComplete = historyComplete
        self.observations = observations
        self.highestEventID = highestEventID
        requiresReconciliation = observations.contains {
            $0.requiresReconciliation || $0.rootChanged || ($0.isDirectory && $0.wasRenamed)
        }
    }
}

struct FilesystemConflictDeferral: Error {
    let observations: [FSEventsObservation]
}

public actor FilesystemEventProcessor {
    private let handler: @Sendable (FilesystemEventBatch) async throws -> Void
    private let checkpoint: @Sendable (UInt64) async throws -> Void
    private var pending: [FilesystemEventBatch] = []
    private var draining = false
    private var failure: Error?
    private var paused: Bool
    private var heldCheckpoint: UInt64 = 0

    public init(initiallyPaused: Bool = false, handler: @escaping @Sendable (FilesystemEventBatch) async throws -> Void,
                checkpoint: @escaping @Sendable (UInt64) async throws -> Void)
    {
        self.handler = handler
        self.checkpoint = checkpoint
        paused = initiallyPaused
    }

    private var nextDeliverySequence: UInt64 = 1
    private var deliveries: [UInt64: FilesystemEventBatch] = [:]
    private var replayWaiters: [UUID: (UInt64, CheckedContinuation<FilesystemReplayReceipt, Error>)] = [:]

    func collectStartupReplay(through sequence: UInt64) async throws -> FilesystemReplayReceipt {
        try Task.checkCancellation()
        guard paused else { throw FilesystemReplayError.deliveryActive }
        if let receipt = try replayReceipt(through: sequence) {
            return receipt
        }
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                replayWaiters[identifier] = (sequence, continuation)
                if Task.isCancelled {
                    cancelReplay(identifier)
                }
            }
        } onCancel: {
            Task { await self.cancelReplay(identifier) }
        }
    }

    private func cancelReplay(_ identifier: UUID) {
        replayWaiters.removeValue(forKey: identifier)?.1.resume(throwing: CancellationError())
    }

    private func replayReceipt(through sequence: UInt64) throws -> FilesystemReplayReceipt? {
        guard sequence < nextDeliverySequence else { return nil }
        guard let boundary = pending.first(where: { batch in batch.deliverySequence == sequence }), boundary.replayBoundary else {
            throw FilesystemReplayError.invalidBoundary
        }
        let captured = pending.filter { batch in (batch.deliverySequence ?? 0) <= sequence }
        return FilesystemReplayReceipt(sequence: sequence, observations: captured.flatMap(\.observations),
                                       eventID: captured.map(\.highestEventID).max() ?? 0,
                                       requiresReconciliation: !boundary.historyComplete || captured.contains(where: \.requiresReconciliation))
    }

    private func resolveReplayWaiters() {
        for (identifier, waiting) in replayWaiters {
            do {
                if let receipt = try replayReceipt(through: waiting.0) {
                    replayWaiters.removeValue(forKey: identifier)
                    waiting.1.resume(returning: receipt)
                }
            } catch {
                replayWaiters.removeValue(forKey: identifier)
                waiting.1.resume(throwing: error)
            }
        }
    }

    func finishStartupReplay(_ receipt: FilesystemReplayReceipt) async throws {
        guard paused, try replayReceipt(through: receipt.sequence) != nil else { throw FilesystemReplayError.invalidBoundary }
        if receipt.eventID != 0 {
            try await checkpoint(receipt.eventID)
        }
        pending.removeAll { batch in (batch.deliverySequence ?? 0) <= receipt.sequence }
        try await resumeDelivery()
    }

    public func enqueue(_ batch: FilesystemEventBatch) async throws {
        if let sequence = batch.deliverySequence {
            guard sequence >= nextDeliverySequence, deliveries[sequence] == nil else { throw FilesystemReplayError.invalidBoundary }
            deliveries[sequence] = batch
            while let ordered = deliveries.removeValue(forKey: nextDeliverySequence) {
                pending.append(ordered)
                nextDeliverySequence += 1
            }
        } else {
            pending.append(batch)
        }
        resolveReplayWaiters()
        if let failure {
            throw failure
        }
        try await drain()
    }

    public func retry() async throws {
        failure = nil
        try await drain()
    }

    private func resumeDelivery() async throws {
        paused = false
        if let failure {
            throw failure
        }
        try await drain()
    }

    @MainActor
    func resumeAfterInitialSync(_ session: SeratoLibrarySyncSession) -> Task<Void, Never> {
        Task { @MainActor [weak session] in
            guard let session else { return }
            for await completed in session.$initialSyncComplete.values {
                guard !Task.isCancelled else { return }
                guard completed else { continue }
                // Replay can request synchronization itself; never await it from
                // the session task that is publishing initial completion.
                await session.waitUntilIdle()
                guard !Task.isCancelled else { return }
                guard case .ready = session.state else { continue }
                do { try await self.resumeDelivery() }
                catch { session.reportFilesystemFailure("Filesystem startup replay failed: \(error.localizedDescription)") }
                return
            }
        }
    }

    private func drain() async throws {
        guard !paused, !draining else { return }
        draining = true
        defer { draining = false }
        var cursor = 0
        do {
            while cursor < pending.count {
                let batch = pending[cursor]
                do { try await handler(batch) }
                catch let deferred as FilesystemConflictDeferral {
                    pending[cursor] = FilesystemEventBatch(observations: deferred.observations, highestEventID: batch.highestEventID)
                    cursor += 1
                    continue
                }
                if cursor == 0 {
                    let completedThrough = pending.count == 1 ? max(batch.highestEventID, heldCheckpoint) : batch.highestEventID
                    if completedThrough != 0 {
                        try await checkpoint(completedThrough)
                    }
                    if pending.count == 1 {
                        heldCheckpoint = 0
                    }
                } else {
                    heldCheckpoint = max(heldCheckpoint, batch.highestEventID)
                }
                pending.remove(at: cursor)
            }
        } catch {
            failure = error
            throw error
        }
    }
}
