import AppKit
@testable import CrateAgent
import GRDB
import os
import XCTest

@MainActor
final class SeratoLaunchGateTests: XCTestCase {
    private static let bundleIdentifierKey = "testBundleIdentifier"
    private static let processIdentifierKey = "testProcessIdentifier"

    private func watchdog(center: NotificationCenter, provider: @escaping () -> [String]) -> SeratoWatchdog {
        let watchdog = SeratoWatchdog(
            workspaceNotificationCenter: center,
            notificationApplicationProvider: { notification in
                guard let bundleIdentifier = notification.userInfo?[Self.bundleIdentifierKey] as? String,
                      let processIdentifier = notification.userInfo?[Self.processIdentifierKey] as? pid_t else { return nil }
                return SeratoWatchdog.ApplicationIdentity(bundleIdentifier: bundleIdentifier, processIdentifier: processIdentifier)
            },
            runningBundleIdentifiersProvider: provider
        )
        watchdog.startObservingWorkspace()
        return watchdog
    }

    private func post(_ name: Notification.Name, bundle: String, processID: pid_t = 1, to center: NotificationCenter) {
        center.post(name: name, object: nil, userInfo: [Self.bundleIdentifierKey: bundle, Self.processIdentifierKey: processID])
    }

    func testLaunchEvidenceSurvivesStaleRefreshUntilTermination() {
        let center = NotificationCenter()
        var runningIdentifiers: [String] = []
        let watchdog = watchdog(center: center) { runningIdentifiers }
        let observation = watchdog.$isSeratoRunning.sink { running in
            XCTAssertEqual(watchdog.isRunningForExternalWrite, running)
            XCTAssertEqual(watchdog.isClosed(atRevision: watchdog.stateRevision), !running)
        }
        defer { observation.cancel() }

        post(NSWorkspace.didLaunchApplicationNotification, bundle: "com.serato.dj", to: center)
        let launchRevision = watchdog.stateRevision
        XCTAssertTrue(watchdog.isSeratoRunning)
        watchdog.refresh()
        XCTAssertTrue(watchdog.isRunningForExternalWrite, "An empty stale process list cannot revoke a launch")
        XCTAssertEqual(watchdog.stateRevision, launchRevision)

        post(NSWorkspace.didLaunchApplicationNotification, bundle: "com.serato.dj", processID: 2, to: center)
        post(NSWorkspace.didTerminateApplicationNotification, bundle: "com.serato.dj", to: center)
        XCTAssertTrue(watchdog.isRunningForExternalWrite, "Another process with the same bundle ID still blocks writes")

        runningIdentifiers = ["com.serato.serato-studio"]
        post(NSWorkspace.didTerminateApplicationNotification, bundle: "com.serato.dj", processID: 2, to: center)
        XCTAssertTrue(watchdog.isRunningForExternalWrite, "Termination cannot override another running Serato app")
        runningIdentifiers = []
        post(NSWorkspace.didTerminateApplicationNotification, bundle: "com.serato.serato-studio", to: center)
        XCTAssertFalse(watchdog.isSeratoRunning)
        XCTAssertTrue(watchdog.isClosed(atRevision: watchdog.stateRevision))
        XCTAssertFalse(watchdog.isClosed(atRevision: launchRevision))
    }

    func testLaunchAtFinalWriteGateRetainsQueuedWriteWithoutTouchingSerato() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("queued.mp3")
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let original = try Data(contentsOf: fixture.locator.databaseV2Url)
        let center = NotificationCenter()
        var runningIdentifiers = ["com.serato.dj"]
        let watchdog = watchdog(center: center) { runningIdentifiers }
        let engine = OperationEngine(database: fixture.database, seratoWatchdog: watchdog, seratoLocator: fixture.locator)
        try await engine.apply(.removeTrackFromSerato(.init(fileId: XCTUnwrap(file.id))), batchId: "launch-gate")
        runningIdentifiers = []
        watchdog.refresh()

        let intercepted = OSAllocatedUnfairLock(initialState: false)
        try await fixture.database.writer.write { database in
            database.trace { event in
                guard event.expandedDescription.contains("SELECT"), event.expandedDescription.contains("file_identity_observed") else { return }
                let shouldIntercept = intercepted.withLock { intercepted in
                    guard !intercepted else { return false }
                    intercepted = true
                    return true
                }
                guard shouldIntercept else { return }
                DispatchQueue.main.sync {
                    self.post(NSWorkspace.didLaunchApplicationNotification, bundle: "com.serato.dj", to: center)
                    watchdog.refresh()
                }
            }
        }
        let interrupted = try await engine.drainPendingSeratoUpdates()
        try await fixture.database.writer.write { database in database.trace(nil) }
        XCTAssertTrue(intercepted.withLock { intercepted in intercepted }, "The write must reach physical validation before the final gate")
        XCTAssertEqual(interrupted.appliedCount, 0)
        XCTAssertEqual(interrupted.queuedCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), original)

        post(NSWorkspace.didTerminateApplicationNotification, bundle: "com.serato.dj", to: center)
        let resumed = try await engine.drainPendingSeratoUpdates()
        XCTAssertEqual(resumed.appliedCount, 1)
        XCTAssertEqual(resumed.queuedCount, 0)
        XCTAssertTrue(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).isEmpty)
    }
}
