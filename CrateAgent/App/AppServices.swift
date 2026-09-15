import Combine
import Foundation
import os.log

// Bring `assign(to:&)` for @Published into scope.

/// Top-level service container for the running application. Owns
/// every long-lived component and wires them together at startup —
/// the database, the Serato watchdog, the operation engine, both
/// coordinators, the FSEvents watcher, and the library scanner.
///
/// `CrateAgentApp` constructs this once via `@StateObject` so the
/// container's lifetime matches the app's. Views receive the
/// container via `environmentObject` and pull whichever sub-service
/// they need.
///
/// Bootstrap is intentionally synchronous and crash-on-failure: if
/// any required service cannot be brought up, the app cannot do
/// useful work and limping along produces phantom state — the
/// `no-silent-failures` invariant.
@MainActor
public final class AppServices: ObservableObject {
    public let watchedMusicFolder: URL
    public let database: LibraryDatabase
    public let seratoWatchdog: SeratoWatchdog
    public let seratoLocator: SeratoLibraryLocator
    public let operationEngine: OperationEngine
    public let filesystemSyncCoordinator: FilesystemSyncCoordinator
    public let libraryScanner: LibraryScanner
    public let importCoordinator: ImportCoordinator
    public let fingerprintWorker: FingerprintWorker
    public let activityLog: ActivityLog
    let autoTaggerService: AutoTaggerService
    let autoTagSession: AutoTagSession
    let syncSession: SeratoLibrarySyncSession
    @Published private(set) var syncState: SeratoLibrarySyncSession.State = .reconciling

    /// Latest progress from the running initial scan, or nil when no
    /// scan is in flight. Views observe via @Published.
    @Published public private(set) var scanProgress: LibraryScanner.ScanProgress?

    /// `true` once the initial scan task has completed at least once
    /// since launch. The UI can use this to distinguish "still
    /// scanning" from "library appears empty" states.
    @Published public private(set) var initialScanComplete: Bool = false

    /// Number of Serato library rewrites currently queued because
    /// Serato is running. Fed by `OperationEngine.queueDepthPublisher`
    /// so the menu bar reflects state changes immediately.
    @Published public private(set) var pendingSeratoQueueDepth: Int = 0

    /// Latest progress from the fingerprinting worker. Views observe
    /// via @Published; nil before the worker has emitted anything.
    @Published public private(set) var fingerprintProgress: FingerprintWorker.Progress?

    private let seratoSyncCoordinator: SeratoSyncCoordinator
    private let fsEventsWatcher: FSEventsWatcher
    private var filesystemEventsTask: Task<Void, Never>?
    private let filesystemProcessor: FilesystemEventProcessor
    private let filesystemStartupTask: Task<Void, Never>
    private let filesystemContinuation: AsyncStream<FilesystemEventBatch>.Continuation
    private var retryTask: Task<Void, Never>?
    private let readiness: LibrarySyncReadiness
    private var filesystemDeliveryStopped = false

    private static let logger = Logger(
        subsystem: "com.crateagent.app",
        category: "AppServices"
    )

    /// Convenience bootstrap that reads UserPreferences for the
    /// watched music folder and opens the on-disk library database.
    /// Crashes on failure.
    public static func bootstrap() -> AppServices {
        do {
            let watchedFolder = try UserPreferences.resolveMusicFolder()
            let database = try LibraryDatabase.openDefault()
            return try AppServices(
                watchedMusicFolder: watchedFolder,
                database: database
            )
        } catch {
            fatalError("AppServices bootstrap failed: \(error)")
        }
    }

    public init(
        watchedMusicFolder: URL,
        database: LibraryDatabase
    ) throws {
        self.watchedMusicFolder = watchedMusicFolder
        self.database = database
        seratoWatchdog = SeratoWatchdog()
        seratoLocator = try SeratoLibraryLocator.defaultLocation()
        activityLog = ActivityLog()
        let readiness = LibrarySyncReadiness()
        self.readiness = readiness

        let engine = OperationEngine(
            database: database,
            seratoWatchdog: seratoWatchdog,
            seratoLocator: seratoLocator,
            activityLog: activityLog,
            readiness: readiness
        )
        operationEngine = engine

        let filesystemCoordinator = FilesystemSyncCoordinator(
            operationEngine: engine,
            database: database
        )
        filesystemSyncCoordinator = filesystemCoordinator

        let scanner = LibraryScanner(
            operationEngine: engine,
            database: database,
            seratoLocator: seratoLocator
        )
        libraryScanner = scanner

        importCoordinator = ImportCoordinator(
            operationEngine: engine,
            database: database
        )

        let worker = FingerprintWorker(database: database, readiness: readiness)
        fingerprintWorker = worker

        // Shared between AcoustID and MusicBrainz per Ruling G / the
        // design plan: MusicBrainz requires ≤1 request/second, and
        // AcoustID is routed through the same limiter conservatively.
        let lookupRateLimiter = RateLimiter(minInterval: 1.0, clock: SystemClock())
        let applicationSupportUrl = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let lookupCache = LookupCache(
            directory: applicationSupportUrl.appendingPathComponent("crate-agent/lookup-cache", isDirectory: true)
        )
        let taggingService = AutoTaggerService(
            database: database,
            acoustIDClient: AcoustIDClient(loader: URLSession.shared, limiter: lookupRateLimiter, cache: lookupCache),
            musicBrainzClient: MusicBrainzClient(loader: URLSession.shared, limiter: lookupRateLimiter, cache: lookupCache),
            readiness: readiness
        )
        autoTaggerService = taggingService
        autoTagSession = AutoTagSession(
            database: database, lookupService: autoTaggerService,
            applyBatch: { mutations, batchID, tokens in _ = try await engine.applyBatch(mutations, batchId: batchID, expectedMembershipTokens: tokens) },
            resyncBatch: { batchID in try await engine.resyncSeratoForBatch(batchID) }
        )

        let reader = SeratoMembershipSnapshotReader(locator: seratoLocator, watchdog: seratoWatchdog)
        let session = SeratoLibrarySyncSession(reader: reader,
                                               reconciler: SeratoMembershipReconciler(database: database, operationEngine: engine, reader: reader),
                                               scanner: scanner, operationEngine: engine, watchdog: seratoWatchdog, readiness: readiness,
                                               stopProcessing: { taggingService.cancel() }, worker: worker)
        syncSession = session
        seratoSyncCoordinator = SeratoSyncCoordinator(
            session: session,
            seratoWatchdog: seratoWatchdog
        )

        let watchConfiguration = try FilesystemWatchConfiguration(musicFolder: watchedMusicFolder)
        let resumeFromEventId = watchConfiguration.resumeEventID {
            UserPreferences.lastFSEventId(forWatchedPath: $0)
        }

        let eventStream = AsyncStream<FilesystemEventBatch>.makeStream()
        filesystemContinuation = eventStream.continuation
        let batchHandler = FilesystemSyncBatchHandler(coordinator: filesystemCoordinator, session: session)
        let processor = FilesystemEventProcessor(
            initiallyPaused: true,
            handler: { batch in try await batchHandler.handle(batch) },
            checkpoint: { eventId in
                UserPreferences.setLastFSEventId(eventId, forWatchedPath: watchConfiguration.checkpointKey)
            }
        )
        filesystemProcessor = processor
        let watcher = FSEventsWatcher(
            watchedPaths: watchConfiguration.watchedPaths,
            sinceWhen: resumeFromEventId,
            handler: { batch in eventStream.continuation.yield(batch) }
        )
        try watcher.start()
        fsEventsWatcher = watcher
        filesystemStartupTask = processor.resumeAfterInitialSync(session)
        filesystemEventsTask = Task { [weak self] in
            for await batch in eventStream.stream {
                if Task.isCancelled {
                    return
                }
                do { try await processor.enqueue(batch) }
                catch { session.reportFilesystemFailure("Filesystem sync stopped before event \(batch.highestEventID): \(error.localizedDescription)") }
            }
            if !Task.isCancelled {
                self?.filesystemDeliveryStopped = true
                session.reportFilesystemFailure("Filesystem event delivery stopped. Restart crate-agent to resume watching.")
            }
        }

        // All stored properties are now assigned; start lifecycle.
        seratoWatchdog.startObservingWorkspace()

        // Bridge OperationEngine's queue-depth publisher into the
        // @Published var so SwiftUI views observe it like any other
        // ObservableObject state. .receive(on: DispatchQueue.main)
        // ensures MainActor isolation for the assignment.
        engine.queueDepthPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$pendingSeratoQueueDepth)
        session.$state.assign(to: &$syncState)
        session.$initialSyncComplete.assign(to: &$initialScanComplete)
        session.$scanProgress.assign(to: &$scanProgress)
        session.$fingerprintProgress.assign(to: &$fingerprintProgress)

        Self.logger.info(
            "AppServices ready; watching \(watchedMusicFolder.path, privacy: .public)"
        )

        session.requestSync()
    }

    deinit {
        readiness.invalidate()
        filesystemEventsTask?.cancel()
        filesystemStartupTask.cancel()
        filesystemContinuation.finish()
        retryTask?.cancel()
        fsEventsWatcher.stop()
        let worker = fingerprintWorker
        Task { await worker.stop() }
    }

    func retrySync() {
        guard !filesystemDeliveryStopped else { return }
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            guard let self else { return }
            defer { retryTask = nil }
            syncSession.beginFilesystemRetry()
            do {
                try await filesystemProcessor.retry()
                syncSession.finishFilesystemRetry(succeeded: true)
                try await syncSession.synchronize(retryingFailedCleanup: true)
            } catch {
                syncSession.finishFilesystemRetry(succeeded: false)
                syncSession.reportFailure("Sync retry failed: \(error.localizedDescription)")
            }
        }
    }
}
