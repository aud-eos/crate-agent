import Foundation

enum PrepareMessages {
    static let sectionTitle = "Prepare"
    static let subtitle = "Work through the tracks that still need something, most promising first: popularity, Hot and your own plays."
    static let previous = "Previous"
    static let next = "Next"
    static let emptyTitle = "Nothing left to prepare"
    static let emptyDetail = "Every track in this view is Finished. Clear the search or filters to see more."
    static let stillNeedsHeading = "Still needs"
    static let signalsHeading = "Signals"
    static let fixTags = "Fix tags"
    static let fixTagsHelp = "Select this track in Auto-Tag to fill its artist, title and other tags from MusicBrainz."
    static let autoTagBusy = "Auto-Tag is busy with a scan. Finish or reset it first."
    static let openInSerato = "Open in Serato"
    static let openInSeratoHelp = "Open the file in Serato DJ to set cue points and check its beatgrid."
    static let seratoNotInstalled = "Serato DJ isn't installed, or can't open this file."
    static let showVersions = "Show other versions"
    static let showVersionsHelp = "Open the Library on this track's song family."
    static let moveToTrash = "Move to Trash"
    static let moveToTrashHelp = "Move the file to the Trash and remove it from Serato's library and crates. "
        + RemovalUndoMessages.undoableWhileInTrash
    static let trashWhileSeratoRunning = SeratoGateMessages.quitBefore("moving tracks to the Trash")
    static let trashBannerAction = "moving tracks to the Trash"
    static let cancel = "Cancel"
    static let seratoApplicationPrefix = "Serato DJ"

    static func position(_ index: Int, of total: Int) -> String {
        "Track \(index + 1) of \(total.formatted())"
    }

    static func confirmTrashTitle(_ name: String) -> String {
        "Move \"\(name)\" to the Trash?"
    }

    static func confirmTrashMessage(frees size: Int64) -> String {
        let freed = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return "It leaves Serato's library and every crate, and frees \(freed). " + RemovalUndoMessages.undoableWhileInTrash
    }

    static func movedToTrash(_ name: String) -> String {
        "Moved \"\(name)\" to the Trash. " + RemovalUndoMessages.undoableWhileInTrash
    }

    static func removalQueued(_ name: String) -> String {
        "\"\(name)\" will leave Serato's library when Serato closes."
    }

    static func signal(_ title: String, _ value: String) -> String {
        "\(title) \(value)"
    }
}
