import AppKit
import Combine
import Foundation

/// Observes whether any Serato application is currently running and
/// publishes the state to UI bindings and to the OperationEngine.
///
/// When Serato is running, writes to `~/Music/_Serato_/*.crate` and
/// `database V2` MUST be deferred — Serato caches the library in
/// memory and overwrites the disk version when it saves. This is the
/// project invariant that this watchdog enforces by signalling state
/// changes.
///
/// Bundle-id prefix check covers every Serato variant in one go: DJ
/// Pro (`com.serato.dj`, `com.serato.djpro`), DJ Lite
/// (`com.serato.djlite`), Studio (`com.serato.serato-studio`), and
/// any future product Serato ships under the same prefix. We watch the
/// prefix rather than enumerate exact IDs so a future Serato release
/// doesn't silently break the guard.
@MainActor
public final class SeratoWatchdog: ObservableObject {
    /// Bundle identifiers starting with this prefix are treated as
    /// Serato applications.
    public static let seratoBundleIdentifierPrefix = "com.serato."

    @Published public private(set) var isSeratoRunning: Bool = false

    private let runningBundleIdentifiersProvider: () -> [String]
    private var observers: [NSObjectProtocol] = []

    /// Pass `nil` (or rely on the default) for production behavior —
    /// reads NSWorkspace.shared.runningApplications. Tests pass a
    /// closure that returns the set they want to simulate.
    ///
    /// The provider is resolved inside init rather than via a default
    /// argument that references `defaultRunningBundleIdentifiersProvider`
    /// because the latter was a MainActor-isolated static property,
    /// which Swift 6 strict-concurrency rejects when referenced from
    /// a default-argument expression.
    public init(
        runningBundleIdentifiersProvider customProvider: (() -> [String])? = nil
    ) {
        self.runningBundleIdentifiersProvider = customProvider ?? {
            NSWorkspace.shared.runningApplications.compactMap { app in
                app.bundleIdentifier
            }
        }
        refresh()
    }

    deinit {
        // Synchronous cleanup is safe here — removeObserver doesn't
        // hop actors and observers is a value-typed array.
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Subscribe to NSWorkspace launch/terminate notifications. Call
    /// once during app startup. Idempotent — repeated calls do not
    /// register duplicate observers.
    public func startObservingWorkspace() {
        guard observers.isEmpty else { return }
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        let launchObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        let terminateObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers = [launchObserver, terminateObserver]
    }

    /// Recompute `isSeratoRunning` from the current running app list.
    /// Exposed for tests; in production this is called automatically
    /// when NSWorkspace notifications fire.
    public func refresh() {
        let runningIdentifiers = runningBundleIdentifiersProvider()
        isSeratoRunning = runningIdentifiers.contains { identifier in
            identifier.hasPrefix(Self.seratoBundleIdentifierPrefix)
        }
    }

}
