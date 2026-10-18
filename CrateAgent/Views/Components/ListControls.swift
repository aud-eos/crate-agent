import SwiftUI

enum ListControlLabels {
    static let clearSelection = "Clear selection"
    static let noMatches = "No search matches"
    static let resetSearch = "Clear search or change the filter to see more results."
    static let spaceActionHelp = "Space plays or pauses the focused track. Shift-Space selects or deselects it; Command-O opens it."
}

struct ListSearchField: View {
    @Binding var text: String
    var prompt = ListSearch.prompt

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text).textFieldStyle(.roundedBorder).accessibilityLabel(prompt)
            Button(ListSearch.clearLabel) { text = "" }.disabled(text.isEmpty)
        }
    }
}

struct ListResultSummary: View {
    let results: Int
    let selected: Int
    let hidden: Int
    var hiddenScope = "outside current filter"

    var body: some View {
        Text("\(results) results · \(selected) selected · \(hidden) \(hiddenScope)")
            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
    }
}

struct BatchSelectionControls: View {
    let count: Int
    let scopeCount: Int
    let coverage: BatchSelection.Coverage
    let enabled: Bool
    var scopeLabel: String?
    let setSelected: (Bool) -> Void
    let clear: () -> Void

    var body: some View {
        BatchSelectionToggle(title: scopeLabel ?? "Select all \(scopeCount) eligible matches", coverage: coverage,
                             enabled: enabled && scopeCount > 0, setSelected: setSelected).fixedSize()
        Button(ListControlLabels.clearSelection, action: clear).disabled(!enabled || count == 0)
    }
}

struct ResultListControls<Row: Identifiable & Equatable>: View {
    @Binding var results: ListResultSelection<Row>
    var enabled = true

    var body: some View {
        BatchSelectionControls(count: results.selectedIDs.count, scopeCount: results.selectableVisibleCount,
                               coverage: results.coverage, enabled: enabled,
                               setSelected: { selected in results.selectVisible(selected) }, clear: { results.clearSelection() })
    }
}

struct ResultListHeader<Row: Identifiable & Equatable>: View {
    @Binding var results: ListResultSelection<Row>
    var enabled = true
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable

    var body: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            ListSearchField(text: Binding(get: { results.query }, set: { query in results.setQuery(query) })).disabled(!enabled)
            ListResultSummary(results: results.visibleRows.count, selected: results.selectedIDs.count, hidden: results.hiddenSelectionCount)
            if results.droppedSelectionCount > 0 {
                Text("\(results.droppedSelectionCount) selected proposals changed or disappeared and were deselected. Review the updated results.").font(.callout)
            }
            if !results.rows.isEmpty, results.visibleRows.isEmpty {
                Text(ListControlLabels.noMatches).font(.callout)
            }
        }.padding(.horizontal, density.pagePadding).padding(.vertical, density.spacing)
    }
}
