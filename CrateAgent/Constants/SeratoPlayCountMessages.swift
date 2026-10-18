enum SeratoPlayCountMessages {
    static let title = "Serato play counts"
    static let notRefreshed = "Not read yet; reads Serato History after the library sync."
    static let refreshing = "Reading Serato History…"
    static let skippedWhileSeratoRunning = "Waiting for Serato to close; showing the last counts."
    static let explanation = "Plays from Serato History break ties between duplicate copies. History is only read, never written."

    static func failed(_ reason: String) -> String {
        "Could not read Serato History; keeping the last counts. \(reason)"
    }

    static func refreshed(_ summary: SeratoPlayCountSummary) -> String {
        "\(summary.attributedCount) of \(summary.playCount) plays matched to library files across \(summary.sessionCount) sessions."
    }

    static func skipped(_ summary: SeratoPlayCountSummary) -> String {
        "Not matched: \(summary.unattributedCount) plays at paths no single library file held at the time · "
            + "skipped: \(summary.unplayedCount) loaded but not played, \(summary.nonFileCount) streaming or non-file"
    }

    static func plays(_ count: Int) -> String {
        count == 1 ? "1 play" : "\(count) plays"
    }
}
