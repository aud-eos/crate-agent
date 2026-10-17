import Foundation

/// A Library family row's member selection, derived from the explicit selection.
struct LibraryFamilyState: Equatable, Sendable {
    let mainID: Int64?
    /// Selected members, including those a search hides.
    let selectedCount: Int
    /// Every member file, including those a search hides.
    let memberCount: Int
    let hiddenCount: Int
    let selectedHiddenCount: Int
    /// Processable members a search hides: the ones "Also select N hidden" selects.
    let hiddenEligible: [PagedIdentity<Int64>]
    /// Files shown beneath the main row when expanded (while searching, the matching ones).
    let alternateCount: Int
    /// Processable alternates: the ones Include alternates selects.
    let eligibleAlternates: [PagedIdentity<Int64>]
    let selectedEligibleAlternates: Int
    let isExpanded: Bool
    /// A search shows matching alternates whatever the saved disclosure, so the control is informational.
    let isRevealedBySearch: Bool

    init(members: [LibraryFamilyPlacement], selected: Set<Int64>, isExpanded: Bool, isSearching: Bool) {
        let hidden = members.filter(\.isHiddenBySearch)
        let alternates = members.filter { member in member.role == .alternate && !member.isHiddenBySearch }
        mainID = members.first { member in member.role == .main }?.identity.id
        selectedCount = members.filter { member in selected.contains(member.identity.id) }.count
        memberCount = members.count
        hiddenCount = hidden.count
        selectedHiddenCount = hidden.filter { member in selected.contains(member.identity.id) }.count
        hiddenEligible = hidden.filter(\.isEligible).map(\.identity)
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

    /// What the versions cell says, stating a search's hidden members when there are any.
    func summary(versions: Int) -> String {
        LibraryFamilyMessages.versions(versions, selected: selectedCount, of: memberCount, hidden: hiddenCount, selectedHidden: selectedHiddenCount)
    }

    /// The control that extends a family's selection to the members a search
    /// hides, offered once the family has a selection: true selects them.
    var hiddenSelection: (label: String, selects: Bool)? {
        guard selectedCount > 0, !hiddenEligible.isEmpty else { return nil }
        let selects = selectedHiddenCount < hiddenEligible.count
        return (LibraryFamilyMessages.hiddenSelection(selects: selects, count: hiddenEligible.count), selects)
    }

    var alternatesCoverage: BatchSelection.Coverage {
        if selectedEligibleAlternates == 0 {
            return .none
        }
        return selectedEligibleAlternates == eligibleAlternates.count ? .all : .partial
    }
}
