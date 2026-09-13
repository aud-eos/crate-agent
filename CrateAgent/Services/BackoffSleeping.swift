import Foundation

/// Abstraction over "wait N seconds" so retry backoff is deterministically
/// testable — production sleeps for real via `Task.sleep`; tests inject a
/// sleeper that records the requested delay and returns immediately.
public protocol BackoffSleeping: Sendable {
    func sleep(seconds: TimeInterval) async
}

public struct SystemBackoffSleeper: BackoffSleeping {
    public init() {}

    public func sleep(seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
}
