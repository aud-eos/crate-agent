import Combine
import Foundation
import os.log

/// Bridges `SeratoWatchdog` to `OperationEngine`'s deferred-write
/// queue: when Serato transitions from running to not-running, the
/// coordinator asks the engine to drain queued Serato library
/// rewrites. This is the half of the Serato-running invariant that
/// makes the queue actually flow — without it, rewrites would pile up
/// forever and the user would never see Serato updates.
///
/// Subscribes to `SeratoWatchdog.$isSeratoRunning` and edge-detects the
/// running → not-running transition. The initial value emitted on
/// subscribe is treated as the starting state, not a transition; only
/// genuine changes from `true` to `false` trigger drain.
@MainActor
public final class SeratoSyncCoordinator {

    private static let logger = Logger(
        subsystem: "com.crateagent.app",
        category: "SeratoSyncCoordinator"
    )

    private let operationEngine: OperationEngine
    private var subscription: AnyCancellable?
    private var lastObservedRunningState: Bool

    public init(operationEngine: OperationEngine, seratoWatchdog: SeratoWatchdog) {
        self.operationEngine = operationEngine
        self.lastObservedRunningState = seratoWatchdog.isSeratoRunning

        self.subscription = seratoWatchdog.$isSeratoRunning
            .dropFirst()  // dropFirst skips the immediate publish-on-subscribe
            .sink { [weak self] isRunning in
                self?.handleRunningStateChange(isRunning)
            }
    }

    private func handleRunningStateChange(_ isRunning: Bool) {
        let transitionedToNotRunning = lastObservedRunningState && !isRunning
        lastObservedRunningState = isRunning
        guard transitionedToNotRunning else { return }

        Task { [operationEngine] in
            do {
                try await operationEngine.drainPendingSeratoUpdates()
            } catch {
                // Loud-but-not-fatal: drain failure leaves the queue
                // intact (engine stops at first error), so the next
                // transition will retry. We log here rather than
                // throw because there is no upstream caller to throw
                // to. UI surfacing of drain errors lands with the
                // menu bar status detail view.
                Self.logger.error(
                    "Serato drain failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
