import Foundation

/// Abstraction over "wait N seconds" so retry backoff is deterministically
/// testable — production sleeps for real via `Task.sleep`; tests inject a
/// sleeper that records the requested delay and returns immediately.
///
/// `sleep` is throwing so that a cancelled task's `CancellationError`
/// PROPAGATES to the caller instead of being swallowed. When the user starts a
/// New Scan or leaves Auto-Tag while an old lookup is mid-backoff, the retry
/// loop must abort, not silently continue its remaining attempts against the
/// rate-limited service (finding #4001501076).
public protocol BackoffSleeping: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemBackoffSleeper: BackoffSleeping {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        // No `try?`: a cancellation during the wait must surface as
        // CancellationError so the retry loop stops.
        try await Task.sleep(for: .seconds(seconds))
    }
}
