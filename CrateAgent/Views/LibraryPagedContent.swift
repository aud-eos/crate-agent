import AppKit
import SwiftUI

enum LibraryBrowserAction: String, CaseIterable {
    case rename = "Rename…"
    case history = "Show History"
    case finder = "Show in Finder"
}

/// Song-family changes offered from a Library row's context menu.
enum LibraryFamilyAction: CaseIterable {
    case groupSelected, addSelected, mergeSelected, splitSelected, setMain, automaticMain, remove

    var title: String {
        switch self {
        case .groupSelected: LibraryFamilyMessages.groupSelected
        case .addSelected: LibraryFamilyMessages.addSelected
        case .mergeSelected: LibraryFamilyMessages.mergeSelected
        case .splitSelected: LibraryFamilyMessages.splitSelected
        case .setMain: LibraryFamilyMessages.setMain
        case .automaticMain: LibraryFamilyMessages.automaticMain
        case .remove: LibraryFamilyMessages.remove
        }
    }

    /// Whether the action applies to `row`, given how many files are selected.
    func applies(to row: BrowserRow, selectedCount: Int) -> Bool {
        let inFamily = row.familyId != nil && row.recordingId != nil
        return switch self {
        case .groupSelected: selectedCount >= 2
        case .addSelected, .mergeSelected, .splitSelected: inFamily && selectedCount >= 1
        case .setMain: inFamily && row.savedMain != true
        case .automaticMain: inFamily && row.savedMain == true
        case .remove: inFamily
        }
    }
}

struct LibraryPagedContent: View {
    @ObservedObject var model: LibraryBrowserModel
    let density: AppDensity
    let showsFilenames: Bool
    var readiness: LibrarySyncReadiness?
    var preview: AudioPreviewPlayer?
    let onAction: (Int64, LibraryBrowserAction) -> Void
    var onFamilyAction: (BrowserRow, LibraryFamilyAction) -> Void = { _, _ in }

    private var enabled: Bool {
        !model.isRefreshing && !model.selection.isBusy && model.results.snapshot != nil
    }

    private var coverage: BatchSelection.Coverage {
        guard let summary = model.selection.summary, summary.scopeSelected > 0 else { return .none }
        return summary.scopeSelected == summary.scopeCount ? .all : .partial
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            if let message = model.error {
                failure(message) { model.retry() }
            }
            if let message = model.results.error {
                failure(message) { model.results.retry() }
            }
            if let message = model.selection.error {
                failure(message) { model.selection.retry() }
            }
            HStack(spacing: density.spacing) {
                let summary = model.selection.summary
                ListResultSummary(results: model.results.totalCount, selected: summary?.total ?? 0, hidden: summary?.hidden ?? 0)
                Spacer()
                Toggle(LibraryFamilyMessages.includeAlternates, isOn: Binding(get: { model.query.includeAlternates },
                                                                              set: { include in model.setIncludeAlternates(include) }))
                    .toggleStyle(.checkbox).help(LibraryFamilyMessages.includeAlternatesHelp).disabled(!enabled)
                let scopeCount = model.selection.summary?.scopeCount ?? model.results.totalCount
                BatchSelectionToggle(title: "Select all \(scopeCount.formatted()) matches", coverage: coverage,
                                     enabled: enabled && scopeCount > 0)
                { selected in
                    if let snapshot = model.results.snapshot {
                        model.selection.setScope(snapshot, selected: selected)
                    }
                }
                Button(ListControlLabels.clearSelection) { model.selection.clear() }
                    .disabled(model.selection.summary?.total == 0 && !model.selection.isBusy)
            }
            if model.selection.isBusy {
                HStack { ProgressView().controlSize(.small); Text(PagingLabels.selectionBusy).font(.callout) }
            }
            if let removed = model.selection.summary?.removed, removed > 0 {
                Text("\(removed) selected files changed membership or disappeared and were deselected.").font(.callout)
            }
        }.padding(.horizontal, density.pagePadding).padding(.bottom, density.spacing)
        if model.results.totalCount > 0 {
            table
        } else if model.isRefreshing || model.results.isLoading {
            ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.error == nil, model.results.error == nil {
            AppEmptyState(title: model.query.search.isEmpty ? "No tracks in this view" : ListControlLabels.noMatches,
                          detail: model.query.search.isEmpty ? "Import tracks or choose another library status." : ListControlLabels.resetSearch,
                          systemImage: "music.note.list")
        } else {
            Spacer()
        }
    }

    private var table: some View {
        PagedTable(controller: model.results, columns: LibraryBrowserColumns.make(showsFilenames: showsFilenames, density: density, readiness: readiness, preview: preview,
                                                                                  families: familyControls),
                   accessibilityLabel: "Library files", rowHeight: density.minimumRowHeight + (showsFilenames ? 12 : 0),
                   isSelected: { identifier in model.selection.visibleSelectedIDs.contains(identifier) },
                   onSelect: { rows, selected in
                       guard let snapshot = model.results.snapshot else { return }
                       model.selection.set(rows.map { row in snapshot.identity(for: row) }, selected: selected)
                   }, onSelectRange: { range, selected in
                       if let snapshot = model.results.snapshot {
                           model.selection.setRange(range, in: snapshot, selected: selected)
                       }
                   }, onSelectAll: {
                       if let snapshot = model.results.snapshot {
                           model.selection.setScope(snapshot, selected: true)
                       }
                   }, onClear: { model.selection.clear() }, onSort: { identifier, ascending in
                       guard let column = LibraryBrowseSort.Column(rawValue: identifier) else { preconditionFailure("Unknown Library sort column") }
                       var query = model.query
                       query.sort = .init(column: column, ascending: ascending)
                       model.setQuery(query)
                   }, contextMenu: menu(for:), selectionVersion: { model.selection.interactionVersion }, enabled: enabled,
                   contentRevision: (readiness?.scopeRevision ?? 0) &+ model.familyRevision,
                   onFocus: { identifier, index in model.focus(id: identifier, index: index) },
                   onDisclose: { identifier, expanded in
                       guard let row = model.results.cachedRows.first(where: { row in row.id == identifier }),
                             row.familyRole == .main, let familyID = row.familyId,
                             model.familyStates[familyID].map({ state in state.alternateCount > 0 }) == true else { return false }
                       model.setExpanded(expanded, family: familyID)
                       return true
                   })
    }

    private var familyControls: LibraryFamilyControls {
        LibraryFamilyControls(state: { familyID in model.familyStates[familyID] },
                              setExpanded: { expanded, familyID in model.setExpanded(expanded, family: familyID) },
                              setAlternatesSelected: { selected, familyID in model.setAlternatesSelected(selected, family: familyID) })
    }

    private func menu(for identifier: Int64) -> NSMenu? {
        guard !model.isRefreshing else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in LibraryBrowserAction.allCases {
            let item = LibraryActionMenuItem(title: action.rawValue) { onAction(identifier, action) }
            if action == .rename {
                item.isEnabled = model.results.cachedRows.first { row in row.id == identifier }?.applyingConflictScope(readiness).canProcess == true
                item.toolTip = model.results.cachedRows.first { row in row.id == identifier }?.applyingConflictScope(readiness).processingBlockReason
            }
            menu.addItem(item)
        }
        guard let row = model.results.cachedRows.first(where: { row in row.id == identifier }) else { return menu }
        let selectedCount = model.selection.summary?.total ?? 0
        let familyActions = LibraryFamilyAction.allCases.filter { action in action.applies(to: row, selectedCount: selectedCount) }
        if !familyActions.isEmpty {
            menu.addItem(.separator())
        }
        for action in familyActions {
            let item = LibraryActionMenuItem(title: action.title) { onFamilyAction(row, action) }
            item.isEnabled = !model.selection.isBusy
            menu.addItem(item)
        }
        if row.familyRole == .main, let familyID = row.familyId, let state = model.familyStates[familyID], state.alternateCount > 0 {
            let expanded = state.isExpanded
            menu.addItem(LibraryActionMenuItem(title: LibraryFamilyMessages.disclosure(expanded: expanded, alternates: state.alternateCount)) {
                model.setExpanded(!expanded, family: familyID)
            })
        }
        return menu
    }

    private func failure(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack { ActionErrorMessage(message: message); Button(PagingLabels.retry, action: retry) }
    }
}

private final class LibraryActionMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("Menu items are created programmatically")
    }

    @objc private func invoke() {
        handler()
    }
}
