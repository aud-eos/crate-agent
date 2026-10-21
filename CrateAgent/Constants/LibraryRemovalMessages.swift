import Foundation

/// Copy for removing several selected Library files at once.
enum LibraryRemovalMessages {
    /// Selection-wide commands share one ceiling so a review stays readable.
    static let selectionLimit = LibraryFamilyMessages.selectionLimit
    static let help = "Move the selected files to the Trash and remove them from Serato's library and crates, as one batch you can undo from History."
    static let runningHelp = SeratoGateMessages.quitBefore("moving tracks to the Trash")
    static let reviewing = "Checking the selected files…"
    static let confirm = "Move to Trash"
    static let cancel = "Cancel"
    static let missingFile = "a file that is no longer in the library"
    static let shownNames = 8

    static func button(_ count: Int) -> String {
        "Move \(count.formatted()) to Trash…"
    }

    static func reviewTitle(_ count: Int, frees bytes: Int64) -> String {
        "Move \(count.formatted()) \(count == 1 ? "file" : "files") to the Trash, freeing \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))?"
    }

    static let reviewBody = "Each file leaves Serato's library and every crate, and its row is retired. "
        + RemovalUndoMessages.undoableWhileInTrash + " While Serato is running the Serato writes wait until it closes."

    static func andMore(_ count: Int) -> String {
        "and \(count.formatted()) more"
    }

    static func outcome(_ outcome: LibraryBatchRemoval.Outcome) -> String {
        let moved = "Moved \(outcome.completed.formatted()) \(outcome.completed == 1 ? "file" : "files") to the Trash"
        var parts = [moved]
        if outcome.pending > 0 {
            parts.append("\(outcome.pending.formatted()) waiting for Serato to close")
        }
        if !outcome.failures.isEmpty {
            parts.append("\(outcome.failures.count.formatted()) not removed")
        }
        return parts.joined(separator: " · ") + ". " + RemovalUndoMessages.undoableWhileInTrash
    }

    static func failures(_ failures: [(path: String, message: String)]) -> String {
        failures.map { failure in "\((failure.path as NSString).lastPathComponent): \(failure.message)" }.joined(separator: "\n")
    }
}
