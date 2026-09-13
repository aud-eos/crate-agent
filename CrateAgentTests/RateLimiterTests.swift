@testable import CrateAgent
import XCTest

/// A fake `RateLimiterClock` that never sleeps in real time. `sleep(until:)`
/// suspends via a continuation that `advance(by:)` resumes once the fake
/// clock reaches the requested deadline, so tests control time explicitly
/// instead of racing the wall clock.
///
/// A plain class (not an actor) with a lock: `RateLimiter` is an actor and
/// calls into the clock from its isolated context, while tests call
/// `advance(by:)` concurrently from the test's own task — both sides need
/// synchronous, thread-safe access to `now` and the pending-waiter list.
final class TestClock: RateLimiterClock, @unchecked Sendable {
    private struct Waiter {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var currentTime: TimeInterval = 0
    private var waiters: [Waiter] = []

    var now: TimeInterval {
        lock.withLock { currentTime }
    }

    func sleep(until deadline: TimeInterval) async {
        // NSLock's lock()/unlock() are flagged when called directly from an
        // async context (Swift 6 concurrency mode) — `withLock` is the
        // suggested async-safe scoped-locking replacement, and also reads
        // better than a manual lock/defer pair at every call site.
        let alreadyPastDeadline = lock.withLock { currentTime >= deadline }
        guard !alreadyPastDeadline else { return }

        await withCheckedContinuation { continuation in
            lock.withLock {
                waiters.append(Waiter(deadline: deadline, continuation: continuation))
            }
        }
    }

    /// Advances the fake clock and resumes any waiter whose deadline has
    /// now been reached, in the order they were scheduled.
    func advance(by increment: TimeInterval) {
        let readyWaiters: [Waiter] = lock.withLock {
            currentTime += increment
            let ready = waiters.filter { $0.deadline <= currentTime }
            waiters.removeAll { $0.deadline <= currentTime }
            return ready
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }

    /// Deterministically waits until a concurrently-running task has
    /// reached `sleep(until:)` and parked. Used instead of a raw
    /// `Task.yield()` guess so tests don't race the other task's
    /// scheduling — this polls via yields (no real time elapses) until
    /// the waiter is actually registered.
    func waitUntilWaiting() async {
        while true {
            let hasWaiter = lock.withLock { !waiters.isEmpty }
            if hasWaiter {
                return
            }
            await Task.yield()
        }
    }
}

final class RateLimiterTests: XCTestCase {
    func testEnforcesMinimumSpacing() async {
        let clock = TestClock()
        let limiter = RateLimiter(minInterval: 1.0, clock: clock)

        await limiter.acquire() // immediate — nothing to wait behind.

        let secondAcquireCompleted = ManagedAtomicBool()
        async let second: Void = {
            await limiter.acquire()
            secondAcquireCompleted.set(true)
        }()

        await clock.waitUntilWaiting()
        clock.advance(by: 0.9)
        XCTAssertFalse(secondAcquireCompleted.get(), "should still be waiting before minInterval elapses")

        clock.advance(by: 0.2)
        await second

        XCTAssertTrue(secondAcquireCompleted.get())
        XCTAssertGreaterThanOrEqual(clock.now, 1.0)
    }

    func testUnrelatedCallsWithoutContentionProceedImmediately() async {
        let clock = TestClock()
        let limiter = RateLimiter(minInterval: 1.0, clock: clock)

        await limiter.acquire()
        clock.advance(by: 1.0)
        await limiter.acquire() // spacing already satisfied — no wait needed.

        XCTAssertEqual(clock.now, 1.0)
    }

    func testNoopLimiterNeverDelays() async {
        // `.noop` uses a real SystemClock but minInterval 0, so this must
        // return without the test needing to wait on real time at all.
        await RateLimiter.noop.acquire()
        await RateLimiter.noop.acquire()
        await RateLimiter.noop.acquire()
    }
}

/// Minimal thread-safe flag — avoids reaching for a heavier dependency
/// just to observe "has the second acquire() call returned yet" from the
/// test's main task while it runs concurrently on its own.
final class ManagedAtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.withLock { value = newValue }
    }

    func get() -> Bool {
        lock.withLock { value }
    }
}
