import Foundation

enum FindVersionsMessages {
    static let command = "Find Versions…"
    static let commandHelp = "Suggest song families across the library: files with the same artist and title, apart from version labels."
    static let title = "Find Versions"
    static let subtitle = "Each row is a suggested song family: files with the same artist and title once version labels such as Clean, "
        + "Instrumental or Remix are set aside. Strong matches are checked. Uncheck a family or a single version, then group the rest in one step."
    static let scanning = "Looking for versions…"
    static let noSuggestions = "No new versions found. Every match is already grouped, or no two files share an artist and title."
    static let high = "Strong match"
    static let highHelp = "Same artist and title, and every version names different labels."
    static let medium = "Near match"
    static let mediumHelp = "Same artist and title, but some versions name the same labels, or grouping them merges song families. Check it to group it."
    static let newFamily = "New song family"
    static let alreadyGrouped = "Already in the song family"
    static let needsTwoVersions = "Check at least two versions to group them."
    static let sameAudioHelp = "Files that hold the same audio are duplicates, not versions, so they are left out. Review them in Library Cleanup, Duplicates."
    static let openDuplicates = "Open Library Cleanup"
    static let unknownLength = "Unknown length"
    static let rescan = "Scan Again"
    static let cancel = "Close"

    static func addsToFamily(_ title: String) -> String {
        "Adds to the song family of “\(title)”"
    }

    static func mergesFamilies(_ count: Int) -> String {
        "Merges \(count) song families"
    }

    static func mergeItem(_ count: Int) -> String {
        "Merge the \(count) song families these files belong to"
    }

    static func summary(suggestions: Int, checked: Int) -> String {
        let noun = suggestions == 1 ? "1 suggested song family" : "\(suggestions) suggested song families"
        return "\(noun) · \(checked) checked"
    }

    static func awaitingFingerprint(_ count: Int) -> String {
        let noun = count == 1 ? "1 matching file has" : "\(count) matching files have"
        return "\(noun) no fingerprint yet, so \(count == 1 ? "it is" : "they are") left out until fingerprinting finishes."
    }

    static func sameAudio(_ count: Int) -> String {
        count == 1 ? "1 group of same-audio files" : "\(count) groups of same-audio files"
    }

    static func showSameAudio(_ count: Int) -> String {
        "Show \(sameAudio(count))"
    }

    static func hideSameAudio(_ count: Int) -> String {
        "Hide \(sameAudio(count))"
    }

    static func apply(_ count: Int) -> String {
        count == 1 ? "Group 1 Song Family" : "Group \(count) Song Families"
    }

    static func applied(_ count: Int) -> String {
        "Grouped \(count == 1 ? "1 song family" : "\(count) song families"). Undo it in History as one step."
    }

    static func batchLimit(_ limit: Int) -> String {
        "Groups up to \(limit) song families at a time, so the library stays responsive. Group again for the rest."
    }

    static func fileLine(title: String, label: String, length: String?) -> String {
        "\(title) · \(label) · \(length ?? unknownLength)"
    }
}
