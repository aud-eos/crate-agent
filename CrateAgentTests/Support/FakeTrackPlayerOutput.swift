@testable import CrateAgent
import Foundation

/// Records what the preview player asks of the audio device; plays nothing.
@MainActor
final class FakeTrackPlayerOutput: TrackPlayerOutput {
    struct Play {
        let url: URL
        let startFraction: Double
        let onProgress: @MainActor (TimeInterval, TimeInterval) -> Void
        let onEnd: @MainActor (String?) -> Void
    }

    private(set) var plays: [Play] = []
    private(set) var commands: [String] = []
    private var stoppedThrough = 0

    var activePlays: [URL] {
        plays[stoppedThrough...].map(\.url)
    }

    func play(_ url: URL, from startFraction: Double,
              onProgress: @escaping @MainActor (TimeInterval, TimeInterval) -> Void,
              onEnd: @escaping @MainActor (String?) -> Void)
    {
        plays.append(Play(url: url, startFraction: startFraction, onProgress: onProgress, onEnd: onEnd))
    }

    func pause() {
        commands.append("pause")
    }

    func resume() {
        commands.append("resume")
    }

    func seek(toSeconds seconds: TimeInterval) {
        commands.append("seek \(seconds)")
    }

    func stop() {
        stoppedThrough = plays.count
    }

    func report(elapsed: TimeInterval, duration: TimeInterval) {
        plays.last?.onProgress(elapsed, duration)
    }

    func endPlayback(at index: Int, reason: String?) {
        plays[index].onEnd(reason)
    }
}
