import Foundation

@MainActor
final class LibraryStartupCoordinator {
    private let session: SeratoLibrarySyncSession
    private let processor: FilesystemEventProcessor
    private let captureBoundary: @Sendable () async throws -> UInt64
    private let replay: @Sendable (FilesystemEventBatch) async throws -> Void
    private var task: Task<Void, Never>?
    private var restartRequested = false
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

    func start() {
        guard task == nil else { restartRequested = true; return }
        if completed {
            session.requestSync(); return
        }
        task = Task { [weak self] in await self?.run() }
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
                try await session.synchronize(session.retryRequest())
                try Task.checkCancellation()
                try await processor.finishStartupReplay(receipt, retained: session.retainedStartupObservations)
                session.clearStartupReplay()
                completed = true
                return
            } catch {
                if Task.isCancelled {
                    return
                }
                if session.validationWasSuperseded {
                    continue
                }
                if case .waitingForSerato = session.state {
                    return
                }
                session.reportFailure("Filesystem startup validation failed: \(error.localizedDescription)")
                return
            }
        }
    }
}
