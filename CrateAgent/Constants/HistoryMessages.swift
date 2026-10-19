import Foundation

/// User-facing copy for the History view.
enum HistoryMessages {
    static let undoUnsupported = "This batch contains operations that can't be undone yet (Serato-side imports/commits)."

    static func keeperMarkedPhrase(count: Int) -> String {
        count == 1 ? "Marked as keeper" : "Marked \(count) files as keepers"
    }

    static func keeperClearedPhrase(count: Int) -> String {
        count == 1 ? "Keeper cleared" : "Keeper cleared on \(count) files"
    }
}
