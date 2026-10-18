import AppKit
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
    public let duplicateEvidenceVerifier: DuplicateEvidenceVerifier
    public let activityLog: ActivityLog
    let trackPlayer = TrackPlayer()
    let autoTaggerService: AutoTaggerService
    let autoTagSession: AutoTagSession
    let syncSession: SeratoLibrarySyncSession
    let playCountService: SeratoPlayCountService
    @Published private(set) var syncState: SeratoLibrarySyncSession.State = .idle
    @Published private(set) var syncPhase: SeratoLibrarySyncSession.SyncPhase?
    @Published private(set) var syncFileInfoFailures: [String] = []
    @Published private(set) var conflictNavigationRequest: UUID?
    lazy var conflictReviewModel = SeratoConflictReviewModel(session: syncSession, copyDetails: { text in
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            throw SeratoConflictActionError(message: "Could not copy the conflict details to the clipboard.")
        }
    }, revealFile: { path in
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }, openSerato: {
        let identifiers = ["com.serato.dj", "com.serato.djpro", "com.serato.djlite"]
        guard let application = identifiers.lazy.compactMap({ identifier in NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) }).first else {
            throw SeratoConflictActionError(message: "Serato DJ could not be found. Open your installed Serato application, save and close its library, then retry sync.")
        }
        _ = try await NSWorkspace.shared.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration())
    }, retrySync: { [weak self] in self?.retrySync() })

    @Published private(set) var sectionRequest: MainWindowView.Section?
    @Published private(set) var librarySearchRequest: String?
    lazy var workersModel = WorkersModel(database: database, restartFingerprinting: { [weak self] in self?.resumeFingerprinting() })

    func open(_ section: MainWindowView.Section) {
        sectionRequest = section
    }

    func consumeSectionRequest() {
        sectionRequest = nil
    }

    /// Library search also matches paths, so a full path narrows the list to that file.
    func showInLibrary(path: String) {
        librarySearchRequest = path
        open(.library)
    }

    func consumeLibrarySearchRequest() -> String? {
        defer { librarySearchRequest = nil }
        return librarySearchRequest
    }

    func consumeConflictNavigation() {
        conflictNavigationRequest = nil
    }

    func reviewConflicts() {
        conflictNavigationRequest = UUID()
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Latest progress from the running file-info scan, or nil when no
    /// scan is in flight. Views observe via @Published.
    @Published public private(set) var scanProgress: LibraryScanner.ScanProgress?

    /// `true` once a file-info scan has completed at least once
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
    private let startupCoordinator: LibraryStartupCoordinator
    private let filesystemContinuation: AsyncStream<FilesystemEventBatch>.Continuation
    private var retryTask: Task<Void, Never>?
    let readiness: LibrarySyncReadiness
    private var filesystemDeliveryStopped = false
    private var fingerprintMilestones = FingerprintActivityMilestones()
    private var scanMilestones = ScanActivityMilestones()
    private var scanActivitySubscription: AnyCancellable?
    private var playCountSubscription: AnyCancellable?

    private static let logger = Logger(
        subsystem: "com.crateagent.app",
        category: "AppServices"
    )

    public static func bootstrap(watchedMusicFolder: URL) -> AppServices {
        do {
            let database = try LibraryDatabase.openDefault()
            return try AppServices(
                watchedMusicFolder: watchedMusicFolder,
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
        try ApplicationRuntime.requireLiveResources()
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
        duplicateEvidenceVerifier = DuplicateEvidenceVerifier(database: database)

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

        let watchConfiguration = try FilesystemWatchConfiguration(musicFolder: watchedMusicFolder)
        let reader = SeratoMembershipSnapshotReader(locator: seratoLocator, watchdog: seratoWatchdog)
        let session = SeratoLibrarySyncSession(reader: reader,
                                               reconciler: SeratoMembershipReconciler(database: database, operationEngine: engine, reader: reader),
                                               scanner: scanner, operationEngine: engine, watchdog: seratoWatchdog, readiness: readiness,
                                               stopProcessing: { taggingService.cancel() },
                                               checkpointStore: SyncCheckpointStore(database: database), watchRoots: watchConfiguration.watchedPaths)
        syncSession = session
        playCountService = SeratoPlayCountService(database: database, seratoLocator: seratoLocator, watchdog: seratoWatchdog)
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
        let startup = LibraryStartupCoordinator(session: session, processor: processor,
                                                captureBoundary: { try await watcher.captureReplayBoundary() },
                                                replay: { batch in
                                                    try await filesystemCoordinator.handleBatch(batch)
                                                    _ = await filesystemCoordinator.takeReconciliationRequest()
                                                })
        startupCoordinator = startup
        seratoSyncCoordinator = SeratoSyncCoordinator(session: session, seratoWatchdog: seratoWatchdog, startup: startup)
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
        scanActivitySubscription = session.$scanProgress.sink { [weak self] progress in
            guard let self else { return }
            logActivity(scanMilestones.entries(for: progress), category: .scan)
        }
        // A finished sync means Serato is closed; the service re-reads History only if it or the library's paths changed.
        playCountSubscription = session.$state.sink { [weak self] state in
            guard case .ready = state, let service = self?.playCountService else { return }
            Task { await service.refresh() }
        }
        session.$phase.assign(to: &$syncPhase)
        session.$fileInfoFailures.assign(to: &$syncFileInfoFailures)

        Self.logger.info(
            "AppServices ready; watching \(watchedMusicFolder.path, privacy: .public)"
        )

        startFingerprinting()
        startup.start()
    }

    deinit {
        readiness.invalidate()
        filesystemEventsTask?.cancel()
        filesystemContinuation.finish()
        retryTask?.cancel()
        fsEventsWatcher.stop()
        let worker = fingerprintWorker
        Task { await worker.stop() }
    }

    func retrySync() {
        guard !filesystemDeliveryStopped, retryTask == nil else { return }
        if !startupCoordinator.completed {
            startupCoordinator.start(retryingFailedCleanup: true); return
        }
        retryTask = Task { [weak self] in
            guard let self else { return }
            defer { retryTask = nil }
            syncSession.beginFilesystemRetry()
            do {
                try await filesystemProcessor.retry()
                syncSession.finishFilesystemRetry(succeeded: true)
                try await syncSession.synchronize(syncSession.retryRequest(), retryingFailedCleanup: true)
                try await filesystemProcessor.retry()
            } catch {
                syncSession.finishFilesystemRetry(succeeded: false)
                syncSession.reportFailure("Sync retry failed: \(error.localizedDescription)")
            }
        }
    }

    func requestLibraryRescan() {
        startupCoordinator.requestRescan()
    }

    func stopLibraryRescan() {
        startupCoordinator.stop()
    }

    /// Requeued files are picked up by a running worker's next poll; a worker that stopped on an
    /// error is started again.
    func resumeFingerprinting() {
        if fingerprintProgress?.error != nil {
            fingerprintProgress = nil
        }
        startFingerprinting()
    }

    func retryFingerprinting() {
        fingerprintProgress = nil
        startFingerprinting(waitingForCurrentRun: true)
    }

    private func startFingerprinting(waitingForCurrentRun: Bool = false) {
        let worker = fingerprintWorker
        Task { [weak self] in
            if waitingForCurrentRun {
                await worker.waitUntilStopped()
            }
            guard let self else { return }
            await worker.start { progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    fingerprintProgress = progress
                    logActivity(fingerprintMilestones.entries(for: progress), category: .fingerprint)
                }
            }
        }
    }

    private func logActivity(_ entries: [String], category: ActivityLog.Category) {
        for entry in entries {
            activityLog.log(entry, category: category)
        }
    }
}
