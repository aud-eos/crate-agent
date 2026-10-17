import Foundation

enum LibraryFamilyMessages {
    static let includeAlternates = "Include alternates"
    static let includeAlternatesHelp = "Select all also selects each family's processable alternate files."
    static let familyIncludeAlternatesHelp = "Select or deselect this family's processable alternate files without expanding it."
    static let alternate = "Alternate"
    static let versionsColumn = "Versions"
    static let versionsHelp = "Versions counts the family's different recordings. The files beneath the main row also include other encodings of the main version."
    static let searchRevealHelp = "While searching, every matching file is shown beneath its main row. Clear the search to show or hide files."
    static let groupSelected = "Group Selected as Song Family"
    static let addSelected = "Add Selected to This Song Family"
    static let mergeSelected = "Merge Selected Song Families"
    static let splitSelected = "Split Selected into New Song Family"
    static let setMain = "Set as Main Version"
    static let automaticMain = "Use Automatic Main Version"
    static let remove = "Remove from Song Family"
    static let selectAlternates = "Select Alternate Files"
    static let deselectAlternates = "Deselect Alternate Files"
    static let selectionLimit = 500
    static let nothingToChange = "The selection has no other versions for this song family."
    static let notInFamily = "This row is not in a song family."

    static func versions(_ count: Int, selected: Int) -> String {
        let versions = count == 1 ? "1 version" : "\(count) versions"
        return selected > 0 ? "\(versions) · \(selected) selected" : versions
    }

    static func disclosure(expanded: Bool, files: Int) -> String {
        let noun = files == 1 ? "1 file" : "\(files) files"
        return expanded ? "Hide \(noun)" : "Show \(noun)"
    }

    static func searchReveal(files: Int) -> String {
        switch files {
        case 0: "No matching files"
        case 1: "1 matching file shown"
        default: "\(files) matching files shown"
        }
    }

    static func disclosureAccessibility(_ label: String, title: String) -> String {
        "\(label) beneath \(title)"
    }
}
