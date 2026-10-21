import AppKit
import SwiftUI

enum LibraryBrowserAction: Equatable {
    case rename
    case history
    case open(OpenTarget)
    case reveal
    /// Marks the file's recording as a keeper, or clears its keeper, if the file is still at the revision the row showed.
    case keeper(Bool, revision: Int64)
}

/// Song-family changes offered from a Library row's context menu.
struct LibraryPagedContent: View {
    @ObservedObject var model: LibraryBrowserModel
    let density: AppDensity
    let showsFilenames: Bool
    var readiness: LibrarySyncReadiness?
    var player: TrackPlayer?
    var opener: FileOpener?
    var popularity: PopularityService?
    var removal: LibraryBatchRemoval?
    let onAction: (Int64, LibraryBrowserAction) -> Void
    var onFamilyAction: (BrowserRow, LibraryFamilyAction) -> Void = { _, _ in }
    @State private var offersPopularitySources = false
    @State private var removalPlan: LibraryBatchRemoval.Plan?
    @State private var isPlanningRemoval = false
    @State private var isRemoving = false
    @State private var removalNotice: String?
    @State private var removalFailures: String?

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
            if let removalFailures {
                HStack { ActionErrorMessage(message: removalFailures); Button(CommonLabels.dismiss) { self.removalFailures = nil } }
            }
            if let removalNotice {
                HStack { ActionNoticeMessage(message: removalNotice); Button(CommonLabels.dismiss) { self.removalNotice = nil } }
            }
            if let offer = model.differentRecordingsOffer, let title = offer.action.differentRecordingsTitle {
                HStack {
                    ActionErrorMessage(message: offer.message)
                    Button(title) { Task { await model.acceptDifferentRecordingsOffer() } }
                        .help(LibraryFamilyMessages.differentRecordingsHelp)
                    Button(CommonLabels.dismiss) { model.differentRecordingsOffer = nil }
                }
            }
            HStack(spacing: density.spacing) {
                let summary = model.selection.summary
                ListResultSummary(results: model.results.totalCount, selected: summary?.total ?? 0, hidden: summary?.hidden ?? 0)
                Spacer()
                if model.showsFamilies {
                    Toggle(LibraryFamilyMessages.includeAlternates, isOn: Binding(get: { model.query.includeAlternates },
                                                                                  set: { include in model.setIncludeAlternates(include) }))
                        .toggleStyle(.checkbox).help(LibraryFamilyMessages.includeAlternatesHelp).disabled(!enabled)
                }
                let scopeCount = model.selection.summary?.scopeCount ?? model.results.totalCount
                BatchSelectionToggle(title: "Select all \(scopeCount.formatted()) matches", coverage: coverage,
                                     enabled: enabled && scopeCount > 0)
                { selected in
                    if let snapshot = model.results.snapshot {
                        model.selection.setScope(snapshot, selected: selected)
                    }
                }
                Button(ListControlLabels.clearSelection) { model.selection.clear() }
                    .disabled((model.selection.summary?.total == 0 && !model.selection.isBusy) || isRemoving)
                if removal != nil {
                    let selected = summary?.inScope ?? 0
                    Button(LibraryRemovalMessages.button(selected), role: .destructive) { Task { await planRemoval() } }
                        .disabled(!enabled || selected == 0 || isPlanningRemoval || isRemoving)
                        .seratoWriteGated(help: LibraryRemovalMessages.help, runningHelp: LibraryRemovalMessages.runningHelp)
                }
            }
            if isPlanningRemoval || isRemoving {
                HStack { ProgressView().controlSize(.small); Text(isRemoving ? LibraryRemovalMessages.removing : LibraryRemovalMessages.reviewing).font(.callout) }
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
            AppEmptyState(title: model.query.isFiltering ? LibraryChecklistMessages.noMatches : "No tracks in this view",
                          detail: model.query.isFiltering ? LibraryChecklistMessages.clearToSeeMore : "Import tracks or choose another library status.",
                          systemImage: "music.note.list")
        } else {
            Spacer()
        }
    }

    private var table: some View {
        PagedTable(controller: model.results, columns: LibraryBrowserColumns.make(showsFilenames: showsFilenames, density: density, readiness: readiness, player: player,
                                                                                  families: model.showsFamilies ? familyControls : nil,
                                                                                  popularityEnabled: { [popularity] in popularity?.enabledSources.isEmpty == false }),
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
                       // The first sort by a popularity column while every source is off offers the sources once.
                       if [.popularity, .hot].contains(column), let popularity, popularity.enabledSources.isEmpty, !popularity.preferences.popularityPromptShown {
                           offersPopularitySources = true
                       }
                   }, contextMenu: menu(for:), selectionVersion: { model.selection.interactionVersion }, enabled: enabled,
                   contentRevision: (readiness?.scopeRevision ?? 0) &+ model.familyRevision,
                   onFocus: { identifier, index in model.focus(id: identifier, index: index) },
                   onDisclose: { identifier, expanded in model.disclose(expanded, row: identifier) },
                   onSpace: player.map { player in { row in Task { await player.toggle(PlayerTrack(row)) } } },
                   onOpen: opener.map { _ in { row in onAction(row.id, .open(.defaultApplication)) } })
            .sheet(isPresented: $offersPopularitySources) {
                if let popularity {
                    PopularitySourcesSheet(preferences: popularity.preferences, service: popularity) { offersPopularitySources = false }
                }
            }
            .sheet(isPresented: Binding(get: { removalPlan != nil }, set: {
                shown in if !shown {
                    removalPlan = nil
                }
            })) {
                if let removalPlan {
                    LibraryRemovalReviewSheet(plan: removalPlan, confirm: { Task { await remove(removalPlan) } }, cancel: { self.removalPlan = nil })
                }
            }
    }

    private func planRemoval() async {
        guard let removal else { return }
        isPlanningRemoval = true
        defer { isPlanningRemoval = false }
        removalFailures = nil
        removalNotice = nil
        do {
            removalPlan = try await removal.plan(model.selectedIdentities())
        } catch { removalFailures = error.localizedDescription }
    }

    /// Removed rows leave the selection through the refresh's reconcile; files
    /// that failed stay selected so they can be retried or inspected.
    private func remove(_ plan: LibraryBatchRemoval.Plan) async {
        guard let removal, !isRemoving else { return }
        removalPlan = nil
        isRemoving = true
        defer { isRemoving = false }
        let outcome = await removal.remove(plan)
        removalNotice = LibraryRemovalMessages.outcome(outcome)
        removalFailures = outcome.failures.isEmpty ? nil : LibraryRemovalMessages.failures(outcome.failures)
    }

    private var familyControls: LibraryFamilyControls {
        LibraryFamilyControls(state: { familyID in model.familyStates[familyID] },
                              setExpanded: { expanded, familyID in model.setExpanded(expanded, family: familyID) },
                              setAlternatesSelected: { selected, familyID in model.setAlternatesSelected(selected, family: familyID) },
                              setHiddenSelected: { selected, familyID in model.setHiddenMembersSelected(selected, family: familyID) })
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
                onAction(identifier, .open(.defaultApplication))
            }
            open.keyEquivalent = "o"
            open.keyEquivalentModifierMask = .command
            open.isEnabled = defaultApplication != nil
            menu.addItem(open)
            menu.addItem(.sectionHeader(title: FileOpenerMessages.openWith))
            for application in opener.otherApplications(for: path) {
                menu.addItem(LibraryActionMenuItem(title: application.name) { onAction(identifier, .open(.application(application))) })
            }
            menu.addItem(LibraryActionMenuItem(title: FileOpenerMessages.otherApplication) { onAction(identifier, .open(.chooseApplication)) })
        }
        menu.addItem(.separator())
        menu.addItem(LibraryActionMenuItem(title: FileOpenerMessages.reveal) { onAction(identifier, .reveal) })
        guard let row else { return menu }
        if row.hasChecklist, let isProtected = row.isProtected {
            menu.addItem(.separator())
            let keeper = LibraryActionMenuItem(title: isProtected ? LibraryChecklistMessages.clearKeeper : LibraryChecklistMessages.markKeeper) {
                onAction(identifier, .keeper(!isProtected, revision: row.membershipRevision))
            }
            keeper.toolTip = LibraryChecklistMessages.keeperMenuHelp
            menu.addItem(keeper)
        }
        let targetCount = model.familyTargetCount(for: row)
        let familyActions = LibraryFamilyAction.allCases.filter { action in action.applies(to: row, targetCount: targetCount) }
        if !familyActions.isEmpty {
            menu.addItem(.separator())
        }
        for action in familyActions {
            let item = LibraryActionMenuItem(title: action.title) { onFamilyAction(row, action) }
            item.isEnabled = !model.selection.isBusy
            menu.addItem(item)
        }
        if row.familyRole == .main, let familyID = row.familyId, let state = model.familyStates[familyID] {
            if state.alternateCount > 0, !state.isRevealedByFilter {
                menu.addItem(LibraryActionMenuItem(title: state.disclosureLabel) { model.setExpanded(!state.isExpanded, family: familyID) })
            }
            if !state.eligibleAlternates.isEmpty {
                let selectsAll = state.alternatesCoverage != .all
                let item = LibraryActionMenuItem(title: selectsAll ? LibraryFamilyMessages.selectAlternates : LibraryFamilyMessages.deselectAlternates) {
                    model.setAlternatesSelected(selectsAll, family: familyID)
                }
                item.isEnabled = !model.selection.isBusy
                menu.addItem(item)
            }
            if let hidden = state.hiddenSelection {
                let item = LibraryActionMenuItem(title: hidden.label) { model.setHiddenMembersSelected(hidden.selects, family: familyID) }
                item.isEnabled = !model.selection.isBusy
                menu.addItem(item)
            }
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
