import Foundation

/// A Library family row's member selection, derived from the explicit selection.
struct LibraryFamilyState: Equatable, Sendable {
    let mainID: Int64?
    let selectedCount: Int
    /// Files shown beneath the main row when expanded (while searching, the matching ones).
    let alternateCount: Int
    /// Processable alternates: the ones Include alternates selects.
    let eligibleAlternates: [PagedIdentity<Int64>]
    let selectedEligibleAlternates: Int
    let isExpanded: Bool
    /// A search shows matching alternates whatever the saved disclosure, so the control is informational.
    let isRevealedBySearch: Bool

    init(members: [LibraryFamilyPlacement], selected: Set<Int64>, isExpanded: Bool, isSearching: Bool) {
        let alternates = members.filter { member in member.role == .alternate }
        mainID = members.first { member in member.role == .main }?.identity.id
        selectedCount = members.filter { member in selected.contains(member.identity.id) }.count
        alternateCount = alternates.count
        eligibleAlternates = alternates.filter(\.isEligible).map(\.identity)
        selectedEligibleAlternates = eligibleAlternates.filter { identity in selected.contains(identity.id) }.count
        self.isExpanded = isExpanded
        isRevealedBySearch = isSearching
    }

    /// Whether the alternates are on screen now.
    var isShowingAlternates: Bool {
        isRevealedBySearch || isExpanded
    }

    var disclosureLabel: String {
        isRevealedBySearch ? LibraryFamilyMessages.searchReveal(files: alternateCount)
            : LibraryFamilyMessages.disclosure(expanded: isExpanded, files: alternateCount)
    }

    var alternatesCoverage: BatchSelection.Coverage {
        if selectedEligibleAlternates == 0 {
            return .none
        }
        return selectedEligibleAlternates == eligibleAlternates.count ? .all : .partial
    }
}
