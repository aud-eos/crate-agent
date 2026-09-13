import Foundation

/// A clock abstraction `RateLimiter` waits against. `SystemClock` is the
/// production implementation; tests inject a fake so `acquire()` tests run
/// instantly instead of waiting on real wall-clock time.
///
/// `now` is only meaningful relative to other calls on the same instance —
/// it is not a calendar timestamp.
public protocol RateLimiterClock: Sendable {
    var now: TimeInterval { get }

    /// Suspends the caller until this clock's `now` reaches `deadline`.
    /// Returns immediately if `now` has already reached it.
    func sleep(until deadline: TimeInterval) async
}

/// Production clock backed by `ContinuousClock`, which is monotonic and
/// unaffected by wall-clock adjustments — the right choice for measuring
/// elapsed spacing between requests.
public struct SystemClock: RateLimiterClock {
    private let origin = ContinuousClock.now

    public init() {}

    public var now: TimeInterval {
        (ContinuousClock.now - origin).timeInterval
    }

    public func sleep(until deadline: TimeInterval) async {
        let secondsRemaining = deadline - now
        guard secondsRemaining > 0 else { return }
        try? await Task.sleep(for: .seconds(secondsRemaining))
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// Serializes `acquire()` calls so no two callers proceed less than
/// `minInterval` apart — MusicBrainz requires ≤1 request/second, and
/// AcoustID is routed through the same limiter conservatively.
///
/// Being an `actor` is what makes this correct under concurrent callers:
/// each `acquire()` reserves the next available slot (`nextAvailableTime`)
/// before awaiting the clock, so a second caller queued behind a sleeping
/// first caller reserves a *later* slot rather than racing it for the same
/// one.
public actor RateLimiter {
    private let minInterval: TimeInterval
    private let clock: RateLimiterClock
    private var nextAvailableTime: TimeInterval?

    public init(minInterval: TimeInterval, clock: RateLimiterClock) {
        self.minInterval = minInterval
        self.clock = clock
    }

    /// Suspends until it is this caller's turn, spaced `minInterval`
    /// seconds after the previous caller's reserved slot.
    public func acquire() async {
        // minInterval <= 0 means "unconstrained" — used by `.noop` so
        // client tests aren't coupled to real elapsed time at all.
        guard minInterval > 0 else { return }

        let reservedTime = nextAvailableTime ?? clock.now
        if clock.now < reservedTime {
            await clock.sleep(until: reservedTime)
        }
        nextAvailableTime = max(clock.now, reservedTime) + minInterval
    }
}

public extension RateLimiter {
    /// A limiter that never delays. For tests exercising client code
    /// (`AcoustIDClient`, `MusicBrainzClient`) that don't want real
    /// rate-limiting spacing between calls.
    static var noop: RateLimiter {
        RateLimiter(minInterval: 0, clock: SystemClock())
    }
}
