import Combine
import Foundation

private struct LibrarySyncFailure: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

@MainActor
final class SeratoLibrarySyncSession: ObservableObject {
    enum State: Equatable {
        case waitingForSerato
        case reconciling
        case ready(ReconciliationSummary)
        case failed(String)
    }

    @Published private(set) var state: State = .reconciling
    @Published private(set) var initialSyncComplete = false
    @Published private(set) var scanProgress: LibraryScanner.ScanProgress?
    @Published private(set) var fingerprintProgress: FingerprintWorker.Progress?
    private let reader: SeratoMembershipSnapshotReader
    private let reconciler: SeratoMembershipReconciler
    private let scanner: LibraryScanner
    private let operationEngine: OperationEngine
    private let watchdog: SeratoWatchdog
    let readiness: LibrarySyncReadiness
    private let stopProcessing: @MainActor () async -> Void
    private let startProcessing: @MainActor () async -> Void
    private let worker: FingerprintWorker?
    private var task: Task<Void, Never>?
    private var requested = false
    private var filesystemFailure: String?
    private var filesystemRetryActive = false
    private var successfulPass: UInt64 = 0

    init(reader: SeratoMembershipSnapshotReader, reconciler: SeratoMembershipReconciler,
         scanner: LibraryScanner, operationEngine: OperationEngine, watchdog: SeratoWatchdog,
         readiness: LibrarySyncReadiness, stopProcessing: @escaping @MainActor () async -> Void = {},
         startProcessing: @escaping @MainActor () async -> Void = {}, worker: FingerprintWorker? = nil)
    {
        self.reader = reader
        self.reconciler = reconciler
        self.scanner = scanner
        self.operationEngine = operationEngine
        self.watchdog = watchdog
        self.readiness = readiness
        self.stopProcessing = stopProcessing
        self.startProcessing = startProcessing
        self.worker = worker
    }

    func requestSync() {
        if let filesystemFailure, !filesystemRetryActive {
            state = .failed(filesystemFailure)
            return
        }
        requested = true
        readiness.invalidate()
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func waitUntilIdle() async {
        while let task {
            await task.value
        }
    }

    func synchronize() async throws {
        let previousPass = successfulPass
        requestSync()
        await waitUntilIdle()
        try Task.checkCancellation()
        guard successfulPass > previousPass else {
            if case let .failed(message) = state {
                throw LibrarySyncFailure(message: message)
            }
            if case .waitingForSerato = state {
                throw SeratoMembershipSnapshotError.seratoRunning
            }
            throw LibrarySyncReadinessError.synchronizationRequired
        }
    }

    func suspend() {
        requested = false
        readiness.invalidate()
        task?.cancel()
        state = .waitingForSerato
    }

    func reportFailure(_ message: String) {
        requested = false
        readiness.invalidate()
        task?.cancel()
        state = .failed(message)
        if task == nil {
            task = Task { [weak self] in
                guard let self else { return }
                await stopProcessing()
                await worker?.stop()
                task = nil
                if requested {
                    requestSync()
                }
            }
        }
    }

    func reportFilesystemFailure(_ message: String) {
        filesystemFailure = message
        reportFailure(message)
    }

    func beginFilesystemRetry() {
        filesystemRetryActive = true
        readiness.invalidate()
    }

    func finishFilesystemRetry(succeeded: Bool) {
        filesystemRetryActive = false
        if succeeded {
            filesystemFailure = nil
        }
    }

    func seratoStateChanged(isRunning: Bool) {
        if isRunning {
            if task != nil {
                suspend()
            } else if case .failed = state {} else {
                state = .waitingForSerato
            }
        } else {
            requestSync()
        }
    }

    private func run() async {
        defer {
            task = nil
            scanProgress = nil
            if requested {
                requestSync()
            }
        }
        await stopProcessing()
        await worker?.stop()
        do {
            while requested {
                requested = false
                try Task.checkCancellation()
                watchdog.refresh()
                guard !watchdog.isSeratoRunning else { state = .waitingForSerato; return }
                state = .reconciling
                let snapshot = try await reader.read()
                let summary = try await reconciler.reconcile(snapshot)
                try await refreshMetadata(snapshot)
                try await reader.validate(snapshot)
                try Task.checkCancellation()
                if filesystemRetryActive {
                    successfulPass += 1
                    if let filesystemFailure {
                        state = .failed(filesystemFailure)
                    }
                    return
                }
                let revision = watchdog.stateRevision
                let authorization = readiness.prepareDrain()
                _ = try await LibrarySyncReadiness.$drainAuthorization.withValue(authorization) {
                    try await operationEngine.drainPendingSeratoUpdates()
                }
                try Task.checkCancellation()
                guard watchdog.isClosed(atRevision: revision) else { throw SeratoMembershipSnapshotError.seratoRunning }
                if requested {
                    continue
                }
                try readiness.markReady(authorization)
                fingerprintProgress = nil
                await startProcessing()
                let processingAuthorization = try readiness.capture()
                await worker?.start { [weak self] progress in
                    Task { @MainActor in
                        guard let self, (try? processingAuthorization.check()) != nil else { return }
                        self.fingerprintProgress = progress
                        if let error = progress.error {
                            self.reportFailure(error)
                        }
                    }
                }
                try Task.checkCancellation()
                initialSyncComplete = true
                successfulPass += 1
                state = .ready(summary)
            }
        } catch {
            readiness.invalidate()
            await stopProcessing()
            await worker?.stop()
            if !Task.isCancelled {
                state = watchdog.isSeratoRunning ? .waitingForSerato : .failed("Library sync failed: \(error.localizedDescription)")
            }
        }
    }

    private func refreshMetadata(_ snapshot: SeratoMembershipSnapshot) async throws {
        let progressStream = AsyncStream<LibraryScanner.ScanProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { [weak self] in
            for await progress in progressStream.stream {
                guard !Task.isCancelled else { return }
                self?.scanProgress = progress
            }
        }
        defer {
            progressStream.continuation.finish()
            consumer.cancel()
        }
        _ = try await scanner.scan(snapshot: snapshot, reader: reader) { progress in
            progressStream.continuation.yield(progress)
        }
        progressStream.continuation.finish()
        await consumer.value
    }
}
