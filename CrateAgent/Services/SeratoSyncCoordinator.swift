import Combine
import Foundation
import os.log

/// Bridges `SeratoWatchdog` to crate-agent's two Serato-bound flows:
///
///   1. **Drain pending writes** — the `OperationEngine` queues
///      Serato library rewrites while Serato is running (anything
///      written during a session would be clobbered by Serato's
///      next save). On running → not-running, we drain the queue
///      so those changes finally land in `.crate` / `database V2`.
///
///   2. **Reload Serato library** — Serato may have edited its own
///      metadata during the session (BPM analysis, manual tag
///      changes, etc.). Once Serato has quit and its files are
///      stable on disk, we trigger a `LibraryScanner.scan()` to
///      diff Serato's records against crate-agent's DB and fire
///      `setMetadata` mutations for any changed entries.
///
/// Both run on the same edge — Serato's exit — but as separate
/// awaited steps so a drain failure doesn't prevent the reload
/// from happening.
///
/// `dropFirst()` on the subscription skips Combine's publish-on-
/// subscribe so the initial state isn't treated as a transition;
/// only genuine running → not-running edges trigger the workflow.
@MainActor
public final class SeratoSyncCoordinator {

    private static let logger = Logger(
        subsystem: "com.crateagent.app",
        category: "SeratoSyncCoordinator"
    )

    private let operationEngine: OperationEngine
    private let libraryScanner: LibraryScanner
    private var subscription: AnyCancellable?
    private var lastObservedRunningState: Bool

    public init(
        operationEngine: OperationEngine,
        libraryScanner: LibraryScanner,
        seratoWatchdog: SeratoWatchdog
    ) {
        self.operationEngine = operationEngine
        self.libraryScanner = libraryScanner
        self.lastObservedRunningState = seratoWatchdog.isSeratoRunning

        self.subscription = seratoWatchdog.$isSeratoRunning
            .dropFirst()
            .sink { [weak self] isRunning in
                self?.handleRunningStateChange(isRunning)
            }
    }

    private func handleRunningStateChange(_ isRunning: Bool) {
        let transitionedToNotRunning = lastObservedRunningState && !isRunning
        lastObservedRunningState = isRunning
        guard transitionedToNotRunning else { return }

        Task { [operationEngine, libraryScanner] in
            do {
                try await operationEngine.drainPendingSeratoUpdates()
            } catch {
                // Loud-but-not-fatal: drain failure leaves the queue
                // intact (engine stops at first error); next exit
                // event will retry. Reload still proceeds — they're
                // independent flows.
                Self.logger.error(
                    "Serato drain failed: \(error.localizedDescription, privacy: .public)"
                )
            }

            do {
                let result = try await libraryScanner.scan()
                Self.logger.info(
                    "Serato-exit reload: \(result.filesIndexed) new tracks, \(result.filesMetadataUpdated) metadata updates"
                )
            } catch {
                Self.logger.error(
                    "Serato-exit reload failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
