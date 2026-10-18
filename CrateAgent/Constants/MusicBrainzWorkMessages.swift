enum MusicBrainzWorkMessages {
    static let title = "MusicBrainz works"
    static let start = "Record Works"
    static let resume = "Resume"
    static let cancel = "Stop"
    static let notStarted = "Not run yet."
    static let explanation = """
    Looks up the MusicBrainz work of each matched recording that has none, so Find Versions can group versions whose titles differ. \
    It shares Auto-Tag's limit of one request a second, and recordings already looked up answer from the cache. \
    Works are recorded in History batches you can undo.
    """

    static func changedSinceLookup(trackID: Int64) -> String {
        "The MusicBrainz match or work of recording \(trackID) changed since its work was looked up. Run Record Works again."
    }

    static func recordedPhrase(count: Int) -> String {
        "Recorded the MusicBrainz work of \(recordings(count))"
    }

    static func clearedPhrase(count: Int) -> String {
        "Cleared the MusicBrainz work of \(recordings(count))"
    }

    static func coverage(withWork: Int, matched: Int) -> String {
        "MusicBrainz works: \(withWork) of \(matched) matched recordings have one"
    }

    static func running(_ progress: MusicBrainzWorkBackfill.Progress) -> String {
        "Looking up works: \(summary(progress))."
    }

    static func finished(_ progress: MusicBrainzWorkBackfill.Progress) -> String {
        "Finished: \(summary(progress)). The others have no work in MusicBrainz."
    }

    static func cancelled(_ progress: MusicBrainzWorkBackfill.Progress) -> String {
        "Stopped: \(summary(progress)). Resume continues with the rest."
    }

    static func failed(_ progress: MusicBrainzWorkBackfill.Progress, reason: String) -> String {
        "Stopped on an error after \(summary(progress)): \(reason)"
    }

    private static func summary(_ progress: MusicBrainzWorkBackfill.Progress) -> String {
        "\(progress.checked) of \(progress.total) MusicBrainz recordings looked up, \(recordings(progress.recorded)) given a work"
    }

    private static func recordings(_ count: Int) -> String {
        count == 1 ? "1 recording" : "\(count) recordings"
    }
}
