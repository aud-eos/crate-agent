@testable import CrateAgent
import Foundation

/// Issues an empty write every 5 ms and records the longest wait, with the
/// sync phase it ended in: how long any other writer would have been held
/// off (#189, #238).
final class WriterHoldProbe: @unchecked Sendable {
    struct Wait: Sendable {
        let duration: Duration
        let phase: String?
    }

    static let interval: Duration = .milliseconds(5)
    private let lock = NSLock()
    private var waits: [Wait] = []
    private var task: Task<Void, Never>?

    @MainActor
    func start(_ database: LibraryDatabase, phase: @escaping @MainActor () -> String?) {
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                let start = ContinuousClock.now
                do { try await database.writer.write { _ in } } catch { return }
                let waited = start.duration(to: .now)
                let current = await phase()
                self?.record(Wait(duration: waited, phase: current))
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Stops probing and returns every wait, longest first.
    func stop() async -> [Wait] {
        task?.cancel()
        await task?.value
        return lock.withLock { waits.sorted { first, second in first.duration > second.duration } }
    }

    private func record(_ wait: Wait) {
        lock.withLock { waits.append(wait) }
    }
}
