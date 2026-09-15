import Combine
import Foundation

public struct FilesystemEventBatch: Sendable {
    public let observations: [FSEventsObservation]
    public let highestEventID: UInt64
    public let requiresReconciliation: Bool

    public init(observations: [FSEventsObservation], highestEventID: UInt64) {
        self.observations = observations
        self.highestEventID = highestEventID
        requiresReconciliation = observations.contains {
            $0.requiresReconciliation || $0.rootChanged || ($0.isDirectory && $0.wasRenamed)
        }
    }
}

public actor FilesystemEventProcessor {
    private let handler: @Sendable (FilesystemEventBatch) async throws -> Void
    private let checkpoint: @Sendable (UInt64) async throws -> Void
    private var pending: [FilesystemEventBatch] = []
    private var draining = false
    private var failure: Error?
    private var paused: Bool

    public init(initiallyPaused: Bool = false, handler: @escaping @Sendable (FilesystemEventBatch) async throws -> Void,
                checkpoint: @escaping @Sendable (UInt64) async throws -> Void)
    {
        self.handler = handler
        self.checkpoint = checkpoint
        paused = initiallyPaused
    }

    public func enqueue(_ batch: FilesystemEventBatch) async throws {
        pending.append(batch)
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
        do {
            while let batch = pending.first {
                try await handler(batch)
                if batch.highestEventID != 0 {
                    try await checkpoint(batch.highestEventID)
                }
                pending.removeFirst()
            }
        } catch {
            failure = error
            throw error
        }
    }
}
