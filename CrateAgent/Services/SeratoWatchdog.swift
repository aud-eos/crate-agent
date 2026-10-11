import AppKit
import Combine
import Foundation
import os

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
    public private(set) var stateRevision: UInt64 = 0
    private nonisolated let externalWriteState = OSAllocatedUnfairLock(initialState: (running: false, revision: UInt64(0)))

    nonisolated func isClosed(atRevision revision: UInt64) -> Bool {
        externalWriteState.withLock { state in !state.running && state.revision == revision }
    }

    nonisolated var isRunningForExternalWrite: Bool {
        externalWriteState.withLock { state in state.running }
    }

    private let runningBundleIdentifiersProvider: () -> [String]
    private let workspaceNotificationCenter: NotificationCenter
    struct ApplicationIdentity: Hashable {
        let bundleIdentifier: String
        let processIdentifier: pid_t
    }

    private let notificationApplicationProvider: (Notification) -> ApplicationIdentity?
    private var observers: [NSObjectProtocol] = []
    private var notifiedRunningApplications = Set<ApplicationIdentity>()

    /// Pass `nil` (or rely on the default) for production behavior —
    /// reads NSWorkspace.shared.runningApplications. Tests pass a
    /// closure that returns the set they want to simulate.
    ///
    /// The provider is resolved inside init rather than via a default
    /// argument that references `defaultRunningBundleIdentifiersProvider`
    /// because the latter was a MainActor-isolated static property,
    /// which Swift 6 strict-concurrency rejects when referenced from
    /// a default-argument expression.
    public convenience init(
        runningBundleIdentifiersProvider customProvider: (() -> [String])? = nil
    ) {
        self.init(
            workspaceNotificationCenter: NSWorkspace.shared.notificationCenter,
            notificationApplicationProvider: { notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleIdentifier = application.bundleIdentifier else { return nil }
                return ApplicationIdentity(bundleIdentifier: bundleIdentifier, processIdentifier: application.processIdentifier)
            },
            runningBundleIdentifiersProvider: customProvider
        )
    }

    init(
        workspaceNotificationCenter: NotificationCenter,
        notificationApplicationProvider: @escaping (Notification) -> ApplicationIdentity?,
        runningBundleIdentifiersProvider customProvider: (() -> [String])? = nil
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.notificationApplicationProvider = notificationApplicationProvider
        runningBundleIdentifiersProvider = customProvider ?? {
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
            workspaceNotificationCenter.removeObserver(observer)
        }
    }

    /// Subscribe to NSWorkspace launch/terminate notifications. Call
    /// once during app startup. Idempotent — repeated calls do not
    /// register duplicate observers.
    public func startObservingWorkspace() {
        guard observers.isEmpty else { return }
        observers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { notificationName in
            workspaceNotificationCenter.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleWorkspaceNotification(notification)
                }
            }
        }
    }

    private func handleWorkspaceNotification(_ notification: Notification) {
        guard let application = notificationApplicationProvider(notification),
              application.bundleIdentifier.hasPrefix(Self.seratoBundleIdentifierPrefix)
        else { return }
        if notification.name == NSWorkspace.didLaunchApplicationNotification {
            notifiedRunningApplications.insert(application)
            updateRunningState(true, invalidateSnapshot: true)
        } else if notification.name == NSWorkspace.didTerminateApplicationNotification {
            notifiedRunningApplications.remove(application)
            refresh(invalidateSnapshot: true)
        }
    }

    /// Recompute `isSeratoRunning` from the current running app list.
    /// Exposed for tests; in production this is called automatically
    /// when NSWorkspace notifications fire.
    public func refresh() {
        refresh(invalidateSnapshot: false)
    }

    private func refresh(invalidateSnapshot: Bool) {
        let runningIdentifiers = runningBundleIdentifiersProvider()
        // Process-list refreshes can lag launch notifications; only termination revokes that evidence.
        let running = !notifiedRunningApplications.isEmpty || runningIdentifiers.contains { identifier in
            identifier.hasPrefix(Self.seratoBundleIdentifierPrefix)
        }
        updateRunningState(running, invalidateSnapshot: invalidateSnapshot)
    }

    private func updateRunningState(_ running: Bool, invalidateSnapshot: Bool) {
        guard running != isSeratoRunning || invalidateSnapshot else { return }
        stateRevision += 1
        let revision = stateRevision
        externalWriteState.withLock { state in state = (running, revision) }
        if running != isSeratoRunning {
            isSeratoRunning = running
        }
    }
}
