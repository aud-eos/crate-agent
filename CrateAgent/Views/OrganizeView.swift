import SwiftUI

struct OrganizeView: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog
    @StateObject private var preview = OrganizePreviewModel()
    @State private var actionError: String?
    @State private var lastResult: String?
    @State private var pendingConfirm = false
    @State private var isVisible = false

    var body: some View {
        VStack(spacing: 0) {
            if seratoWatchdog.isSeratoRunning {
                SeratoRunningBanner(message: "Serato is running — quit it before organizing.")
                Divider()
            }
            PageHeading("Organize", subtitle: "Review track locations, then move selected files into your artist letter folders.")
                .padding(density.pagePadding)
            header
            ListSearchField(text: Binding(get: { preview.query }, set: preview.setQuery))
                .padding(.horizontal, density.pagePadding).padding(.bottom, density.spacing).disabled(preview.isBusy)
            Divider()
            content
            Divider()
            footer
        }
        .navigationTitle("Organize")
        .frame(minWidth: 720, minHeight: 480)
        .task {
            isVisible = true
            await rescan()
        }
        .onDisappear {
            isVisible = false
            preview.cancelScan()
        }
        .alert("Organize \(preview.selection.count) files?", isPresented: $pendingConfirm) {
            Button("Move \(preview.selection.count) files") { Task { await applySelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Moves all \(preview.selection.count) selected files, including \(preview.hiddenSelectionCount) outside the current filter, into \(services.watchedMusicFolder.path). Serato references update in one undoable batch.")
        }
    }

    private var header: some View {
        HStack(spacing: density.spacing) {
            Picker("Filter", selection: Binding(get: { preview.filter }, set: preview.setFilter)) {
                ForEach(OrganizePreviewModel.Filter.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .disabled(preview.isBusy)
            Spacer()
            Text("Template: \(UserPreferences.filenameTemplate)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Change the filename template in Settings → General, then rescan.")
        }
        .padding(.horizontal, density.pagePadding)
        .padding(.vertical, density.spacing)
    }

    @ViewBuilder
    private var content: some View {
        if preview.isScanning, preview.snapshot.rows.isEmpty {
            ProgressView("Planning file moves…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if preview.visibleCount == 0 {
            ContentUnavailableView(
                preview.error != nil ? "Couldn't load preview" : !preview.query.isEmpty ? ListControlLabels.noMatches : preview.filter == .outsideOnly ? "No files outside the music folder" : "Every file is at its canonical path",
                systemImage: preview.error != nil ? "exclamationmark.triangle" : "checkmark.seal",
                description: Text(preview.error != nil ? "Resolve the error below, then rescan." : "Use All to review other proposed moves, or rescan after importing tracks.")
            )
        } else {
            OrganizePreviewTable(preview: preview, density: density)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            ListResultSummary(results: preview.visibleCount, selected: preview.selection.count, hidden: preview.hiddenSelectionCount)
                .padding(.horizontal, density.pagePadding)
            if preview.snapshot.blockedCount > 0 {
                Text("\(preview.snapshot.blockedCount) files blocked · \(preview.visibleBlockedCount) in this filter. Resolve each row’s missing tags or path conflict, then rescan.")
                    .font(.callout)
                    .padding(.horizontal, density.pagePadding)
            }
            ActionBar {
                if let error = actionError ?? preview.error {
                    ActionErrorMessage(message: error)
                } else if let notice = preview.notice {
                    Text(notice).font(.callout)
                } else if let lastResult {
                    Text(lastResult).font(.callout)
                }
                if preview.isScanning {
                    ProgressView("Planning…").controlSize(.small)
                }
                if preview.isApplying {
                    ProgressView("Organizing…").controlSize(.small)
                }
            } actions: {
                if preview.isScanning {
                    Button("Cancel scan") { preview.cancelScan() }
                } else {
                    Button("Rescan") { Task { await rescan() } }
                        .disabled(preview.isApplying)
                }
                BatchSelectionControls(count: preview.selection.count, scopeCount: preview.scope.count, coverage: preview.selection.coverage(in: preview.scope),
                                       enabled: !preview.isBusy, setSelected: preview.selectScope, clear: preview.clearSelection)
                Button("Move \(preview.selection.count) selected files") { pendingConfirm = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.selection.count == 0 || preview.isBusy || seratoWatchdog.isSeratoRunning)
            }
        }
        .padding(.top, density.spacing)
    }

    private func rescan() async {
        actionError = nil
        await preview.rescan(database: services.database, musicFolder: services.watchedMusicFolder, template: UserPreferences.filenameTemplate, readiness: services.readiness)
    }

    private func applySelected() async {
        guard !seratoWatchdog.isSeratoRunning else { return }
        let plans = await preview.beginApply()
        guard !plans.isEmpty else { return }
        actionError = nil
        lastResult = nil
        let organizer = LibraryOrganizer(operationEngine: services.operationEngine, activityLog: services.activityLog)
        do {
            let outcome = try await organizer.organize(plans)
            lastResult = outcome.failureCount == 0
                ? "Organized \(outcome.movedCount) files"
                : "Organized \(outcome.movedCount); \(outcome.failureCount) skipped (see activity log)"
            preview.finishApply()
            if isVisible {
                await rescan()
            }
        } catch {
            preview.finishApply()
            actionError = "Organize failed: \(error.localizedDescription)"
        }
    }
}

struct OrganizePreviewTable: View {
    @ObservedObject var preview: OrganizePreviewModel
    let density: AppDensity

    var body: some View {
        let snapshot = preview.snapshot
        let indexes = preview.visibleIndexes
        VirtualizedPreviewTable(
            dataID: preview.displayGeneration.uuidString, accessibilityLabel: "Organize move preview",
            rowCount: indexes.count,
            row: { index in snapshot.rows[indexes[index]] },
            columns: [
                PreviewTableColumn(identifier: "artist", title: "Artist", width: 130, text: { row in row.artist }),
                PreviewTableColumn(identifier: "title", title: "Title", width: 180, text: { row in row.title }),
                PreviewTableColumn(identifier: "status", title: "Status", width: 190, text: { row in row.status }),
                PreviewTableColumn(identifier: "source", title: "Current path", width: 300, text: { row in row.sourcePath }),
                PreviewTableColumn(identifier: "destination", title: "Proposed path", width: 300, text: { row in row.plan?.destinationPath ?? OrganizeMessages.noValue }),
                PreviewTableColumn(identifier: "location", title: "Location", width: 160, text: { row in row.isOutsideMusicFolder ? "Outside music folder" : "Inside music folder" }),
            ],
            accessibilityName: { row in "\(row.artist) \(row.title)" },
            isSelected: preview.isSelected,
            setSelected: { identifier, selected in
                guard preview.snapshot.generation == snapshot.generation else { return }
                preview.setSelected(selected, identifier: identifier)
            },
            selectAll: {
                guard preview.snapshot.generation == snapshot.generation else { return }
                preview.selectScope(true)
            }, enabled: !preview.isBusy, density: density, sort: preview.sort, isSelectable: { row in row.plan != nil }
        )
    }
}
