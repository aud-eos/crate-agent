import Foundation

/// User-facing copy for queued Serato changes that will not be applied.
enum SeratoWriteDispositionMessages {
    static func summary(_ disposition: SeratoWriteDisposition, count: Int) -> String {
        switch disposition {
        case .superseded: "\(changes(count, "queued")) superseded by newer Serato edits or file changes"
        case .uncertain: "\(changes(count, "queued")) not applied because their saved Serato values could not be verified"
        case .interrupted: "\(changes(count, "interrupted audio")) not retried"
        case .malformed: "\(changes(count, "unreadable queued")) skipped"
        case .legacyUnrecoverable: "\(changes(count, "pre-upgrade")) could not be resumed"
        case .noSeratoRecord: "\(changes(count, nil)) not applied because Serato's database has no entry at their path"
        }
    }

    static func unmovedOccupant(at path: String) -> String {
        "Not applied: the rename that would have moved the track already at \((path as NSString).lastPathComponent) was not applied."
    }

    static func unrecognizedSummary(count: Int) -> String {
        "\(changes(count, "queued")) not applied for a reason this version does not recognize"
    }

    static func historyBadge(count: Int) -> String {
        "\(changes(count, nil)) not applied"
    }

    static let historyHelp = "Some Serato or audio-tag changes in this batch were not applied, for example because Serato or the file changed while they were queued. See the activity log for details."

    private static func changes(_ count: Int, _ qualifier: String?) -> String {
        [String(count), qualifier, count == 1 ? "change" : "changes"].compactMap { part in part }.joined(separator: " ")
    }
}
