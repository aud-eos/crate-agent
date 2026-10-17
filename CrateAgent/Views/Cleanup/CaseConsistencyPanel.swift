import GRDB
import SwiftUI

struct CaseConsistencyPanel: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices

    @State private var files: [HygieneFileRow] = []
    @State private var results = ListResultSelection<LibraryHygiene.CaseInconsistencyGroup>()
    private var groups: [LibraryHygiene.CaseInconsistencyGroup] {
        get { results.rows }
        nonmutating set {
            let index = Dictionary(uniqueKeysWithValues: files.compactMap { file in file.id.map { ($0, ListSearch.text(artist: file.artist, title: file.title, album: file.album, path: file.path)) } })
            let revisions = Dictionary(uniqueKeysWithValues: files.compactMap { file in file.id.map { ($0, String(file.membershipRevision)) } })
            results.replace(newValue, context: "case", revision: { group in group.variants.flatMap(\.fileIds).map { revisions[$0] ?? "" }.joined(separator: ",") }, searchText: { group in
                group.variants.flatMap(\.fileIds).compactMap { index[$0] }.joined(separator: "\n")
            })
            refreshConflictSelection()
        }
    }

    /// Per-group resolution: nil = leave alone, non-nil = user
    /// picked this variant as canonical. Keyed by group id so
    /// switching tabs / rescanning doesn't lose the user's picks
    /// for groups still present.
    @State private var resolutions: [String: String?] = [:]
    @State private var isScanning: Bool = false
    @State private var isApplying: Bool = false
    @State private var actionError: String?
    @State private var lastResult: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("Consistent capitalization", subtitle: "Choose the spelling to keep for each group, or skip that group.")
                .padding(density.pagePadding)
            SeratoRunningBanner(message: SeratoGateMessages.quitBefore("normalizing case"))
            ResultListHeader(results: $results, enabled: !isScanning && !isApplying)
            groupListSection.disabled(isScanning || isApplying)
            Divider()
            footer
        }
        .task { await rescan() }
        .onChange(of: services.syncState) { _, _ in refreshConflictSelection() }
    }

    @ViewBuilder
    private var groupListSection: some View {
        if isScanning, groups.isEmpty {
            ProgressView("Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let actionError, groups.isEmpty {
            ActionErrorMessage(message: actionError)
        } else if groups.isEmpty {
            hygienePlaceholder(
                icon: "checkmark.seal",
                color: .green,
                headline: "Case is consistent",
                detail: "No field has the same value spelled with multiple capitalizations."
            )
        } else {
            List(results.visibleRows) { group in
                groupRow(group)
            }
            .listStyle(.inset)
        }
    }

    private func conflictReason(_ group: LibraryHygiene.CaseInconsistencyGroup) -> String? {
        services.readiness.conflictPath(for: SeratoConflictTarget(fileIDs: Set(group.variants.flatMap(\.fileIds)))).map(SeratoConflictMessages.blocked)
    }

    private func refreshConflictSelection() {
        results.setBlockedIDs(Set(groups.filter { group in conflictReason(group) != nil }.map(\.id)))
    }

    private func groupRow(_ group: LibraryHygiene.CaseInconsistencyGroup) -> some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            HStack(spacing: density.spacing) {
                Toggle("Select group", isOn: Binding(get: { results.selectedIDs.contains(group.id) }, set: { results.setSelected($0, id: group.id) }))
                    .toggleStyle(.checkbox)
                    .disabled(conflictReason(group) != nil)
                Text(group.field.displayName)
                    .font(.callout)
                    .foregroundStyle(.tint)
                Text("\(group.totalFiles) file\(group.totalFiles == 1 ? "" : "s")")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let reason = conflictReason(group) {
                Text(reason).font(.callout).foregroundStyle(.orange)
            }
            ForEach(group.variants, id: \.value) { variant in
                let isChosen = resolvedCanonical(for: group) == variant.value
                HStack(spacing: density.spacing) {
                    Button {
                        resolutions[group.id] = .some(variant.value)
                    } label: {
                        Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                    .accessibilityLabel("Use \(variant.value) for \(group.field.displayName)")
                    .accessibilityValue(isChosen ? "Selected" : "Not selected")
                    Text(variant.value)
                        .font(.callout)
                        .foregroundStyle(isChosen ? Color.primary : Color.secondary)
                    Spacer()
                    Text("\(variant.count) file\(variant.count == 1 ? "" : "s")")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
            }
            HStack(spacing: density.spacing) {
                Button("Skip this group") {
                    results.setSelected(false, id: group.id)
                }
                .controlSize(density.controlSize)
                .disabled(!results.selectedIDs.contains(group.id))
                Button("Reset") {
                    resolutions[group.id] = nil
                }
                .controlSize(density.controlSize)
                .disabled(resolutions[group.id] == nil)
                Spacer()
                if resolvedCanonical(for: group) == nil {
                    Text("Skipped")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, density.rowPadding)
    }

    private var footer: some View {
        ActionBar {
            if let actionError {
                ActionErrorMessage(message: actionError)
            } else if let lastResult {
                Label(lastResult, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Text("\(activeGroupCount) of \(groups.count) group\(groups.count == 1 ? "" : "s") will apply")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button {
                Task { await rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning || isApplying)
            ResultListControls(results: $results, enabled: !isScanning && !isApplying)
            Button("Apply \(activeGroupCount) case groups") {
                Task { await applySelections() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(activeGroupCount == 0 || isScanning || isApplying)
            .seratoWriteGated(help: "Apply the selected canonicals in one undoable batch.", runningHelp: SeratoGateMessages.cleanupApplyBlocked)
        }
    }

    /// The canonical the user has chosen (or the analyzer suggested)
    /// for a group. Nil means "leave alone" (skipped).
    private func resolvedCanonical(for group: LibraryHygiene.CaseInconsistencyGroup) -> String? {
        // Three states layered:
        //   1. resolutions[id] absent → analyzer's suggested
        //      canonical (default)
        //   2. resolutions[id] = .some("") → skipped (we encode
        //      "skip" as empty string in the Optional<String>)
        //   3. resolutions[id] = .some(value) → user picked value
        if let entry = resolutions[group.id] {
            if let value = entry, !value.isEmpty {
                return value
            }
            return nil // skip
        }
        return group.suggestedCanonical
    }

    private var activeGroupCount: Int {
        results.selectedRows.filter { resolvedCanonical(for: $0) != nil }.count
    }

    private func rescan() async {
        isScanning = true
        defer { isScanning = false }
        actionError = nil
        do {
            files = try await services.database.writer.read { db in
                try HygieneFileRow.fetchAll(db, sql: HygieneFileRow.hygieneFetchSQL)
            }
            groups = LibraryHygiene.findCaseInconsistencies(in: files)
            // Drop resolutions for groups that no longer exist.
            let currentIds = Set(groups.map(\.id))
            resolutions = resolutions.filter { currentIds.contains($0.key) }
        } catch {
            actionError = "Couldn't scan library: \(error.localizedDescription)"
        }
    }

    private func applySelections() async {
        isApplying = true
        defer { isApplying = false }
        actionError = nil
        lastResult = nil
        let fixes = LibraryHygiene.caseFixes(
            forGroups: results.selectedRows,
            canonicalFor: { group in resolvedCanonical(for: group) },
            in: files
        )
        guard !fixes.isEmpty else {
            lastResult = "Nothing to do — every active group is already on its canonical."
            return
        }
        let runner = LibraryHygieneRunner(operationEngine: services.operationEngine, activityLog: services.activityLog)
        do {
            _ = try await runner.applyCaseFixes(fixes, files: files)
            lastResult = "Normalized case for \(fixes.count) field\(fixes.count == 1 ? "" : "s")"
            await rescan()
        } catch {
            actionError = "Apply failed: \(error.localizedDescription)"
        }
    }
}
