import Foundation
import os

final class LibrarySyncMetrics: Sendable {
    struct Counts: Sendable {
        var snapshotParses = 0
        var stats = 0
        var audioTagReads = 0
        var bitrateReads = 0
        var lightweightHashReads = 0
        var rowWrites = 0
    }

    enum Counter { case parse, stat, audioTag, bitrate, hash, rowWrite }
    @TaskLocal static var current: LibrarySyncMetrics?
    private struct PhaseTiming {
        var name: String?
        var started = ContinuousClock.now
        var durations: [String: Duration] = [:]
    }

    private let timing = OSAllocatedUnfairLock(initialState: PhaseTiming())

    func transition(to name: String?) {
        timing.withLock { timing in
            let now = ContinuousClock.now
            if let previous = timing.name {
                timing.durations[previous, default: .zero] += timing.started.duration(to: now)
            }
            timing.name = name
            timing.started = now
        }
    }

    func phaseDurations() -> [String: Duration] {
        timing.withLock { timing in
            var result = timing.durations
            if let name = timing.name {
                result[name, default: .zero] += timing.started.duration(to: .now)
            }
            return result
        }
    }

    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    func record(_ counter: Counter, count: Int = 1) {
        counts.withLock { value in
            switch counter {
            case .parse: value.snapshotParses += count
            case .stat: value.stats += count
            case .audioTag: value.audioTagReads += count
            case .bitrate: value.bitrateReads += count
            case .hash: value.lightweightHashReads += count
            case .rowWrite: value.rowWrites += count
            }
        }
    }

    func snapshot() -> Counts {
        counts.withLock { value in value }
    }
}
