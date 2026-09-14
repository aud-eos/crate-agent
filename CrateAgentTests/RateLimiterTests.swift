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

    func sleep(until deadline: TimeInterval) async throws {
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

    /// Deterministically waits until at least `count` concurrently-running
    /// tasks have reached `sleep(until:)` and parked. Used instead of a raw
    /// `Task.yield()` guess so tests don't race the other tasks'
    /// scheduling — this polls via yields (no real time elapses) until the
    /// expected number of waiters is actually registered.
    func waitUntilWaiters(atLeast count: Int) async {
        while true {
            let waiterCount = lock.withLock { waiters.count }
            if waiterCount >= count {
                return
            }
            await Task.yield()
        }
    }
}

final class RateLimiterTests: XCTestCase {
    func testEnforcesMinimumSpacing() async throws {
        let clock = TestClock()
        let limiter = RateLimiter(minInterval: 1.0, clock: clock)

        try await limiter.acquire() // immediate — nothing to wait behind.

        let secondAcquireCompleted = ManagedAtomicBool()
        async let second: Void = {
            try await limiter.acquire()
            secondAcquireCompleted.set(true)
        }()

        await clock.waitUntilWaiters(atLeast: 1)
        clock.advance(by: 0.9)
        XCTAssertFalse(secondAcquireCompleted.get(), "should still be waiting before minInterval elapses")

        clock.advance(by: 0.2)
        try await second

        XCTAssertTrue(secondAcquireCompleted.get())
        XCTAssertGreaterThanOrEqual(clock.now, 1.0)
    }

    func testUnrelatedCallsWithoutContentionProceedImmediately() async throws {
        let clock = TestClock()
        let limiter = RateLimiter(minInterval: 1.0, clock: clock)

        try await limiter.acquire()
        clock.advance(by: 1.0)
        try await limiter.acquire() // spacing already satisfied — no wait needed.

        XCTAssertEqual(clock.now, 1.0)
    }

    /// Regression test for an actor-reentrancy race: with the naive
    /// "await the clock, then write the reservation" ordering, two
    /// callers parked behind the same busy slot both read the same
    /// stale `nextAvailableTime` and wake at the same instant — because
    /// actors are reentrant at suspension points, a queued caller can
    /// run its own body (including reading shared state) *while* an
    /// earlier caller is suspended in `await clock.sleep`. Each caller
    /// must reserve its own deadline before it suspends, so three
    /// concurrent callers behind one busy slot come out staggered by
    /// `minInterval`, not clumped.
    func testStaggersThreeConcurrentCallersByMinInterval() async throws {
        let clock = TestClock()
        let limiter = RateLimiter(minInterval: 1.0, clock: clock)

        try await limiter.acquire() // A: immediate, reserves the next slot at t=1.0.

        let completionTimes = RecordedTimes()
        async let second: Void = {
            try await limiter.acquire()
            completionTimes.record(clock.now)
        }()
        async let third: Void = {
            try await limiter.acquire()
            completionTimes.record(clock.now)
        }()

        await clock.waitUntilWaiters(atLeast: 2)

        // Advance and synchronize one step at a time: resuming a
        // continuation only schedules the waiting task, it doesn't run it
        // to completion inline, so we poll for each recording before
        // advancing again — otherwise both callers could end up reading
        // `clock.now` after the second advance and recording the same
        // (wrong) time.
        clock.advance(by: 1.0) // t=1.0 — only the caller reserved for 1.0 wakes.
        await completionTimes.waitUntilCount(atLeast: 1)

        clock.advance(by: 1.0) // t=2.0 — the other caller wakes.
        await completionTimes.waitUntilCount(atLeast: 2)

        _ = try await second
        _ = try await third

        XCTAssertEqual(
            completionTimes.all().sorted(),
            [1.0, 2.0],
            "the two queued callers must be staggered by minInterval, not clumped at the same instant"
        )
    }

    func testNoopLimiterNeverDelays() async throws {
        // `.noop` uses a real SystemClock but minInterval 0, so this must
        // return without the test needing to wait on real time at all.
        try await RateLimiter.noop.acquire()
        try await RateLimiter.noop.acquire()
        try await RateLimiter.noop.acquire()
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

/// Thread-safe recorder for completion timestamps from concurrently-running
/// tasks, with a poll-based wait (no real time elapses) so a test can
/// synchronize with "has task N recorded yet" the same way `TestClock`
/// synchronizes with "has task N parked yet."
final class RecordedTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [TimeInterval] = []

    func record(_ time: TimeInterval) {
        lock.withLock { times.append(time) }
    }

    func all() -> [TimeInterval] {
        lock.withLock { times }
    }

    func waitUntilCount(atLeast expected: Int) async {
        while true {
            let count = lock.withLock { times.count }
            if count >= expected {
                return
            }
            await Task.yield()
        }
    }
}
