import Combine
import Foundation
import os.log

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

    /// Latest progress from the running initial scan, or nil when no
    /// scan is in flight. Views observe via @Published.
    @Published public private(set) var scanProgress: LibraryScanner.ScanProgress?

    /// `true` once the initial scan task has completed at least once
    /// since launch. The UI can use this to distinguish "still
    /// scanning" from "library appears empty" states.
    @Published public private(set) var initialScanComplete: Bool = false

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

        let engine = OperationEngine(
            database: database,
            seratoWatchdog: seratoWatchdog,
            seratoLocator: seratoLocator
        )
        self.operationEngine = engine

        self.seratoSyncCoordinator = SeratoSyncCoordinator(
            operationEngine: engine,
            seratoWatchdog: seratoWatchdog
        )

        let filesystemCoordinator = FilesystemSyncCoordinator(
            operationEngine: engine,
            database: database
        )
        self.filesystemSyncCoordinator = filesystemCoordinator

        self.libraryScanner = LibraryScanner(
            operationEngine: engine,
            database: database
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
    }

    deinit {
        fsEventsWatcher.stop()
    }

    private func runInitialScan() async {
        let watchedFolder = watchedMusicFolder
        let scanner = libraryScanner

        do {
            _ = try await scanner.scan(watchedFolder) { [weak self] progress in
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
