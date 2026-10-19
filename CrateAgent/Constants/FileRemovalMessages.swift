import Foundation

/// User-facing copy for removing a file, by duplicate cleanup or by the owner's choice.
enum FileRemovalMessages {
    static func targetIsKept(path: String) -> String {
        "Can't remove \(name(path)): a duplicate cleanup that hasn't finished keeps it as the copy that stays."
    }

    static let lostCompletionState = "File removal lost its completion state."

    static func stateUnreadable(fileID: Int64, error: String) -> String {
        "File removal state for file \(fileID) is unreadable: \(error)"
    }

    static func pending(path: String) -> String {
        "File removal for \(name(path)) is pending; its file row is retained until all external steps finish."
    }

    static func stopped(fileID: Int64, message: String) -> String {
        "File removal stopped for file \(fileID): \(message)"
    }

    static func completed(fileID: Int64) -> String {
        "File removal completed for file \(fileID)."
    }

    static func finishedAfterInterruptedTrash(fileID: Int64) -> String {
        "File removal for file \(fileID) finished after an interrupted move to Trash."
    }

    static func stoppedAtStep(_ step: Int, path: String, error: String) -> String {
        "File removal stopped at step \(step) for \(name(path)): \(error). Fix the cause, then choose Retry Sync."
    }

    static let supersededByChange = "File removal was superseded by a changed file or kept copy."
    static let supersededBySeratoReadd = "File removal was superseded because Serato re-added the file after removal."
    static let supersededRemainingSteps = "File removal was superseded; its remaining steps were cancelled."

    static func summary(completed: Int, pending: Int, failed: Int, superseded: Int) -> String {
        "File removal: \(completed) completed · \(pending) pending · \(failed) failed · \(superseded) superseded (see activity log)"
    }

    private static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
