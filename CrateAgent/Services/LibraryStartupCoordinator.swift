import Foundation

@MainActor
final class LibraryStartupCoordinator {
    private let session: SeratoLibrarySyncSession
    private let processor: FilesystemEventProcessor
    private let captureBoundary: @Sendable () async throws -> UInt64
    private let replay: @Sendable (FilesystemEventBatch) async throws -> Void
    private var task: Task<Void, Never>?
    private var restartRequested = false
    private var pendingRequest: LibrarySyncRequest?
    private var retryingFailedCleanup = false
    private(set) var completed = false

    init(session: SeratoLibrarySyncSession, processor: FilesystemEventProcessor,
         captureBoundary: @escaping @Sendable () async throws -> UInt64,
         replay: @escaping @Sendable (FilesystemEventBatch) async throws -> Void = { _ in })
    {
        self.session = session
        self.processor = processor
        self.captureBoundary = captureBoundary
        self.replay = replay
    }

    func start(_ request: LibrarySyncRequest? = nil, retryingFailedCleanup: Bool = false) {
        if request == .forceRefresh || pendingRequest == nil {
            pendingRequest = request
        }
        self.retryingFailedCleanup = self.retryingFailedCleanup || retryingFailedCleanup
        guard task == nil else { restartRequested = true; return }
        if completed {
            session.requestSync(pendingRequest ?? .incremental)
            pendingRequest = nil
            return
        }
        task = Task { [weak self] in await self?.run() }
    }

    func requestRescan() {
        start(.forceRefresh)
    }

    func stop() {
        restartRequested = false
        task?.cancel()
        session.stopSync()
    }

    func waitUntilIdle() async {
        while let task {
            await task.value
        }
    }

    private func run() async {
        defer {
            task = nil
            if restartRequested {
                restartRequested = false; start()
            }
        }
        while !Task.isCancelled {
            do {
                let boundary = try await captureBoundary()
                let receipt = try await processor.collectStartupReplay(through: boundary)
                let readiness = session.readiness
                await processor.observeStartupBoundary(boundary) { readiness.invalidate() }
                session.prepareStartupReplay(receipt, handler: replay)
                let request = pendingRequest ?? session.retryRequest()
                pendingRequest = nil
                try await session.synchronize(request, retryingFailedCleanup: retryingFailedCleanup)
                retryingFailedCleanup = false
                try Task.checkCancellation()
                try await processor.finishStartupReplay(receipt, retained: session.retainedStartupObservations)
                session.clearStartupReplay()
                completed = true
                try await processor.retry()
                do { _ = try readiness.capture() }
                catch LibrarySyncReadinessError.synchronizationRequired {
                    try await session.synchronize(session.retryRequest())
                }
                return
            } catch {
                if Task.isCancelled {
                    return
                }
                if case .waitingForSerato = session.state {
                    return
                }
                if completed {
                    session.reportFilesystemFailure("Filesystem delivery failed: \(error.localizedDescription)")
                    return
                }
                if session.validationWasSuperseded {
                    continue
                }
                session.reportFailure("Filesystem startup validation failed: \(error.localizedDescription)")
                return
            }
        }
    }
}
