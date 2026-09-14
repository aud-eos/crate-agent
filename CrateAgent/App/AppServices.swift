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
        self.seratoWatchdog = SeratoWatchdog()
        self.seratoLocator = try SeratoLibraryLocator.defaultLocation()
        self.activityLog = ActivityLog()

        let engine = OperationEngine(
            database: database,
            seratoWatchdog: seratoWatchdog,
            seratoLocator: seratoLocator,
            activityLog: activityLog
        )
        self.operationEngine = engine

        let filesystemCoordinator = FilesystemSyncCoordinator(
            operationEngine: engine,
            database: database
        )
        self.filesystemSyncCoordinator = filesystemCoordinator

        let scanner = LibraryScanner(
            operationEngine: engine,
            database: database,
            seratoLocator: seratoLocator
        )
        self.libraryScanner = scanner

        self.importCoordinator = ImportCoordinator(
            operationEngine: engine,
            database: database
        )

        self.fingerprintWorker = FingerprintWorker(database: database)

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
        self.autoTaggerService = AutoTaggerService(
            database: database,
            acoustIDClient: AcoustIDClient(loader: URLSession.shared, limiter: lookupRateLimiter, cache: lookupCache),
            musicBrainzClient: MusicBrainzClient(loader: URLSession.shared, limiter: lookupRateLimiter, cache: lookupCache)
        )

        // Coordinator needs the scanner to trigger reload-on-exit;
        // wire it last so all upstream deps are constructed.
        self.seratoSyncCoordinator = SeratoSyncCoordinator(
            operationEngine: engine,
            libraryScanner: scanner,
            seratoWatchdog: seratoWatchdog
        )

        // Resume from the last seen event ID if we have one for this
        // exact watched path — events that happened while crate-agent
        // was closed get replayed. First launch (no stored ID) starts
        // from "now."
        let watchedFolderPath = watchedMusicFolder.path
        let resumeFromEventId = UserPreferences.lastFSEventId(
            forWatchedPath: watchedFolderPath
        ) ?? FSEventsWatcher.sinceNow

        // FSEventsWatcher hands the coordinator each batched event
        // group via a detached Task; the watcher's dispatch queue
        // stays free for the next callback. The checkpoint callback
        // persists the highest event ID we've processed so the next
        // launch's `sinceWhen` picks up exactly where we left off.
        self.fsEventsWatcher = FSEventsWatcher(
            watchedPaths: [watchedFolderPath],
            sinceWhen: resumeFromEventId,
            handler: { observations in
                Task { await filesystemCoordinator.handleObservations(observations) }
            },
            onEventIdCheckpoint: { eventId in
                UserPreferences.setLastFSEventId(eventId, forWatchedPath: watchedFolderPath)
            }
        )

        // All stored properties are now assigned; start lifecycle.
        seratoWatchdog.startObservingWorkspace()
        fsEventsWatcher.start()

        // Bridge OperationEngine's queue-depth publisher into the
        // @Published var so SwiftUI views observe it like any other
        // ObservableObject state. .receive(on: DispatchQueue.main)
        // ensures MainActor isolation for the assignment.
        engine.queueDepthPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$pendingSeratoQueueDepth)

        Self.logger.info(
            "AppServices ready; watching \(watchedMusicFolder.path, privacy: .public)"
        )

        // Kick off the initial library scan in the background so the
        // UI shows live progress without blocking app launch. New
        // files discovered between AppServices.init and scan
        // completion are also picked up by the FSEvents watcher and
        // deduplicated by the scanner's path-based skip logic.
        Task { @MainActor in
            await runInitialScan()
        }

        // Start the background fingerprinter. It self-paces against
        // the `files.fingerprint_status = pending` queue, so it's
        // safe to start before the initial scan finishes — every
        // freshly-indexed file will be picked up on the next sweep.
        let worker = fingerprintWorker
        Task { @MainActor [weak self] in
            await worker.start { progressSnapshot in
                Task { @MainActor in
                    self?.fingerprintProgress = progressSnapshot
                }
            }
        }
    }

    deinit {
        fsEventsWatcher.stop()
        let worker = fingerprintWorker
        Task { await worker.stop() }
    }

    private func runInitialScan() async {
        let scanner = libraryScanner

        do {
            _ = try await scanner.scan { [weak self] progress in
                Task { @MainActor in
                    self?.scanProgress = progress
                }
            }
        } catch {
            Self.logger.error(
                "Initial library scan failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        initialScanComplete = true
    }
}
