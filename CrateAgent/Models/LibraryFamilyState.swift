import Foundation

/// A Library family row's member selection, derived from the explicit selection.
struct LibraryFamilyState: Equatable, Sendable {
    let selectedCount: Int
    let alternateCount: Int
    /// Processable alternates: the ones Include alternates selects.
    let eligibleAlternates: [PagedIdentity<Int64>]
    let selectedEligibleAlternates: Int
    var isExpanded: Bool

    init(members: [LibraryFamilyPlacement], selected: Set<Int64>, isExpanded: Bool) {
        let alternates = members.filter { member in member.role == .alternate }
        selectedCount = members.filter { member in selected.contains(member.identity.id) }.count
        alternateCount = alternates.count
        eligibleAlternates = alternates.filter(\.isEligible).map(\.identity)
        selectedEligibleAlternates = eligibleAlternates.filter { identity in selected.contains(identity.id) }.count
        self.isExpanded = isExpanded
    }

    var alternatesCoverage: BatchSelection.Coverage {
        if selectedEligibleAlternates == 0 {
            return .none
        }
        return selectedEligibleAlternates == eligibleAlternates.count ? .all : .partial
    }
}
