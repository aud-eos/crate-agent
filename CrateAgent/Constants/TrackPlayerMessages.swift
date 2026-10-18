enum TrackPlayerMessages {
    static let play = "Play"
    static let pause = "Pause"
    static let resume = "Resume"
    static let stop = "Stop playback"
    static let skipBack = "Skip back 10 seconds"
    static let skipForward = "Skip forward 10 seconds"
    static let position = "Playback position"
    static let nowPlaying = "Now playing"
    static let unavailable = "The file is unavailable, so it can't be played."
    static let unknownFailure = "The audio could not be played."
    static let stalled = "no audio data arrived for several seconds. Check that its drive is still connected."
    static let dismissFailure = "Dismiss playback error"

    static func cannotPlay(_ filename: String, detail: String) -> String {
        "Can't play \(filename): \(detail)"
    }

    static func nowPlayingLabel(title: String, artist: String?) -> String {
        "\(nowPlaying): \([title, artist].compactMap { part in part.flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: ", "))"
    }

    static func failed(_ filename: String, reason: String) -> String {
        "Playback of \(filename) stopped: \(reason)"
    }

    static func action(isCurrent: Bool, isPlaying: Bool) -> String {
        guard isCurrent else { return play }
        return isPlaying ? pause : resume
    }

    static func accessibilityLabel(isCurrent: Bool, isPlaying: Bool, track: String) -> String {
        "\(action(isCurrent: isCurrent, isPlaying: isPlaying)): \(track)"
    }

    static func positionValue(elapsed: String, duration: String) -> String {
        "\(elapsed) of \(duration)"
    }
}
