import Foundation

/// User-facing copy for discarding a queued Serato change that cannot apply (#163).
enum QueuedChangeDiscardMessages {
    static let discardAction = "Discard this change…"
    static let discardedBatchBadge = "Discarded and reverted"
    static let confirmTitle = "Discard this change?"
    static let confirmAction = "Discard and Revert"
    static let emptyValue = "(empty)"
    static let dispositionDetail = "Discarded and reverted from History."
    static let waitingBehindFailure = "Waiting behind a failed change to the same file or path."
    static let confirmHelp = "Drop this change's queued Serato and audio-tag writes and revert it in crate-agent, in one batch you can undo from History."
    static let runningHelp = SeratoGateMessages.quitBefore("discarding a queued change")
    static let writesBack = "Part of this change may already have reached Serato or the audio file, so reverting it queues a write of the old values instead of only dropping it."
    static let laterChangesHeading = "Later queued changes depend on this one. Discard them first:"
    static let revertsHeading = "Discarding reverts:"

    static func historySummary(count: Int) -> String {
        "\(count) queued \(count == 1 ? "change" : "changes") cannot apply"
    }

    static func discarded(fileName: String) -> String {
        "Discarded and reverted the queued change to \(fileName). Undo it from History to queue it again."
    }

    static func batchPhrase(count: Int) -> String {
        "Discarded and reverted \(count) queued Serato \(count == 1 ? "change" : "changes")"
    }

    static func disposition(count: Int) -> String {
        "\(count) queued \(count == 1 ? "change" : "changes") discarded and reverted"
    }

    static func fieldChange(_ change: DiscardedFieldChange) -> String {
        "\(change.field): “\(change.discarded)” goes back to “\(change.restored)”"
    }

    static func fieldLabel(_ name: String) -> String {
        switch name {
        case "bpm": "BPM"
        default: name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}
