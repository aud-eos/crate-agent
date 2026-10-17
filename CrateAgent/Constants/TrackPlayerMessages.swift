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

    static func unreadable(_ filename: String) -> String {
        "Can't play \(filename): the file is missing or unreadable."
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
