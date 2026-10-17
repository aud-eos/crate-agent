enum AudioPreviewMessages {
    static let play = "Play preview"
    static let stop = "Stop preview"
    static let unavailable = "The file is unavailable, so it can't be previewed."
    static let unknownFailure = "The audio could not be played."

    static func unreadable(_ filename: String) -> String {
        "Can't preview \(filename): the file is missing or unreadable."
    }

    static func failed(_ filename: String, reason: String) -> String {
        "Preview of \(filename) stopped: \(reason)"
    }

    static func accessibilityLabel(isPlaying: Bool, track: String) -> String {
        "\(isPlaying ? stop : play): \(track)"
    }
}
