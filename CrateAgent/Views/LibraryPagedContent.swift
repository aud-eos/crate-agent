import AppKit
import SwiftUI

enum LibraryBrowserAction: Equatable {
    case rename
    case history
    /// Opens the file in the given application, or its default one when nil.
    case open(OpenApplication?)
    case reveal
}

struct LibraryPagedContent: View {
    @ObservedObject var model: LibraryBrowserModel
    let density: AppDensity
    let showsFilenames: Bool
    var readiness: LibrarySyncReadiness?
    var player: TrackPlayer?
    var opener: FileOpener?
    let onAction: (Int64, LibraryBrowserAction) -> Void

    private var enabled: Bool {
        !model.isRefreshing && !model.selection.isBusy && model.results.snapshot != nil
    }

    private var coverage: BatchSelection.Coverage {
        guard let summary = model.selection.summary, summary.inScope > 0 else { return .none }
        return summary.inScope == summary.scopeCount ? .all : .partial
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
                BatchSelectionToggle(title: "Select all \(model.results.totalCount.formatted()) matches", coverage: coverage,
                                     enabled: enabled && model.results.totalCount > 0)
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
        PagedTable(controller: model.results, columns: LibraryBrowserColumns.make(showsFilenames: showsFilenames, density: density, readiness: readiness, player: player),
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
                   }, contextMenu: menu(for:), selectionVersion: { model.selection.interactionVersion }, enabled: enabled, contentRevision: readiness?.scopeRevision ?? 0, onFocus: { identifier, index in model.focus(id: identifier, index: index) },
                   onSpace: player.map { player in { row in player.toggle(PlayerTrack(row)) } },
                   onOpen: opener.map { _ in { row in onAction(row.id, .open(nil)) } })
    }

    private func menu(for identifier: Int64) -> NSMenu? {
        guard !model.isRefreshing else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let row = model.results.cachedRows.first { row in row.id == identifier }
        let rename = LibraryActionMenuItem(title: "Rename…") { onAction(identifier, .rename) }
        rename.isEnabled = row?.applyingConflictScope(readiness).canProcess == true
        rename.toolTip = row?.applyingConflictScope(readiness).processingBlockReason
        menu.addItem(rename)
        menu.addItem(LibraryActionMenuItem(title: "Show History") { onAction(identifier, .history) })
        if let opener, let path = row?.path {
            menu.addItem(.separator())
            let defaultApplication = opener.defaultApplication(for: path)
            let open = LibraryActionMenuItem(title: FileOpenerMessages.open(in: defaultApplication?.name ?? FileOpenerMessages.defaultApplication)) {
                onAction(identifier, .open(nil))
            }
            open.keyEquivalent = "o"
            open.keyEquivalentModifierMask = .command
            open.isEnabled = defaultApplication != nil
            menu.addItem(open)
            let others = opener.otherApplications(for: path)
            if !others.isEmpty {
                menu.addItem(.sectionHeader(title: FileOpenerMessages.openWith))
                for application in others {
                    menu.addItem(LibraryActionMenuItem(title: application.name) { onAction(identifier, .open(application)) })
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(LibraryActionMenuItem(title: FileOpenerMessages.reveal) { onAction(identifier, .reveal) })
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
