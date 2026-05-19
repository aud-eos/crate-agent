import Foundation
import os.log

/// Top-level service container for the running application. Owns
/// every long-lived component and wires them together at startup —
/// the database, the Serato watchdog, the operation engine, both
/// coordinators, and the FSEvents watcher.
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

    // Retained for their side-effects (subscriptions, stream
    // lifetime) — not directly accessed by views.
    private let seratoSyncCoordinator: SeratoSyncCoordinator
    private let fsEventsWatcher: FSEventsWatcher

    private static let logger = Logger(
        subsystem: "com.crateagent.app",
        category: "AppServices"
    )

    /// Convenience bootstrap that uses the default music folder and
    /// the on-disk library database. Crashes on failure.
    public static func bootstrap() -> AppServices {
        do {
            let watchedFolder = try Self.defaultMusicFolder()
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

        let coordinator = FilesystemSyncCoordinator(
            operationEngine: engine,
            database: database
        )
        self.filesystemSyncCoordinator = coordinator

        // FSEventsWatcher hands the coordinator each batched event
        // group. The closure is @Sendable and captures the
        // (Sendable, actor-isolated) coordinator; per-batch handling
        // happens in a detached Task to keep the watcher's dispatch
        // queue free for the next callback.
        self.fsEventsWatcher = FSEventsWatcher(
            watchedPaths: [watchedMusicFolder.path]
        ) { observations in
            Task { await coordinator.handleObservations(observations) }
        }

        // All stored properties are now assigned; start lifecycle.
        seratoWatchdog.startObservingWorkspace()
        fsEventsWatcher.start()

        Self.logger.info(
            "AppServices ready; watching \(watchedMusicFolder.path, privacy: .public)"
        )
    }

    deinit {
        fsEventsWatcher.stop()
    }

    private static func defaultMusicFolder() throws -> URL {
        try FileManager.default.url(
            for: .musicDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }
}
