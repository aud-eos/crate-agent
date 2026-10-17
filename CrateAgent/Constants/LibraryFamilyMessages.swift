import Foundation

enum LibraryFamilyMessages {
    static let includeAlternates = "Include alternates"
    static let includeAlternatesHelp = "Select all also selects each family's processable alternate versions."
    static let familyIncludeAlternatesHelp = "Select or deselect this family's processable alternate versions without expanding it."
    static let alternate = "Alternate"
    static let versionsColumn = "Versions"
    static let groupSelected = "Group Selected as Song Family"
    static let addSelected = "Add Selected to This Song Family"
    static let mergeSelected = "Merge Selected Song Families"
    static let splitSelected = "Split Selected into New Song Family"
    static let setMain = "Set as Main Version"
    static let automaticMain = "Use Automatic Main Version"
    static let remove = "Remove from Song Family"
    static let selectionLimit = 500
    static let nothingToChange = "The selection has no other versions for this song family."

    static func versions(_ count: Int, selected: Int) -> String {
        let versions = count == 1 ? "1 version" : "\(count) versions"
        return selected > 0 ? "\(versions) · \(selected) selected" : versions
    }

    static func disclosure(expanded: Bool, alternates: Int) -> String {
        expanded ? "Hide alternates" : (alternates == 1 ? "Show 1 alternate" : "Show \(alternates) alternates")
    }

    static func disclosureAccessibility(expanded: Bool, alternates: Int, title: String) -> String {
        "\(disclosure(expanded: expanded, alternates: alternates)) of \(title)"
    }
}
