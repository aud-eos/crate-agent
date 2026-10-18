import Foundation

/// User-facing copy for undoing a removal: the file restored from the Trash and its Serato records.
enum RemovalUndoMessages {
    static func restoreBlocked(path: String, reason: RestoreBlockReason) -> String {
        let name = (path as NSString).lastPathComponent
        let cause = switch reason {
        case .trashItemMissing: "it is no longer in the Trash"
        case .trashItemChanged: "its item in the Trash changed after it was removed"
        case .trashItemNotInTrash: "it was moved out of the Trash"
        case .originalPathOccupied: "another file is now at \(path)"
        case .trashItemNotRecorded: "where it went in the Trash was not recorded"
        case let .recordsNotRecorded(store): "the records removed from \((store as NSString).lastPathComponent) were not recorded"
        case .fileNotRestored: "it is no longer in the library at \(path)"
        }
        return "Can't undo removing \(name): \(cause)."
    }

    static let redoNotSupported = "A removal that was undone can't be redone from History yet. Remove the file again instead."

    /// `unrecorded` stores no longer exist either, and may never have had records removed.
    static func storesMissing(_ storePaths: [String], unrecorded: [String]) -> String {
        var sentences: [String] = []
        if !storePaths.isEmpty {
            sentences.append("Not restored into \(names(storePaths)): \(storePaths.count == 1 ? "it no longer exists" : "they no longer exist").")
        }
        if !unrecorded.isEmpty {
            sentences.append("\(names(unrecorded)) no longer \(unrecorded.count == 1 ? "exists" : "exist"), and whether the removal took records from \(unrecorded.count == 1 ? "it" : "them") was not recorded.")
        }
        return sentences.joined(separator: " ")
    }

    private static func names(_ storePaths: [String]) -> String {
        storePaths.map { storePath in (storePath as NSString).lastPathComponent }.joined(separator: ", ")
    }

    static func storeMissingSummary(count: Int) -> String {
        "\(count) Serato record \(count == 1 ? "restore" : "restores") not applied because the crate no longer exists"
    }

    static func restoredFromTrashPhrase(count: Int) -> String {
        "Restored \(count) \(count == 1 ? "file" : "files") from the Trash"
    }

    static func recordsRestoredPhrase(count: Int) -> String {
        "Restored Serato records for \(count) \(count == 1 ? "removal" : "removals")"
    }
}
