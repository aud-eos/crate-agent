import GRDB
import SwiftUI

struct WhitespacePanel: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    @State private var trackIdentities: [String: TrackDisplayIdentity] = [:]
    @State private var files: [HygieneFileRow] = []
    @State private var results = ListResultSelection<LibraryHygiene.WhitespaceIssue>()
    private var issues: [LibraryHygiene.WhitespaceIssue] {
        get { results.rows }
        nonmutating set {
            results.replaceHygiene(newValue, files: files, context: "whitespace", fileID: { $0.fileId })
            refreshConflictSelection()
        }
    }

    @State private var isScanning: Bool = false
    @State private var isFixing: Bool = false
    @State private var actionError: String?
    @State private var lastResult: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("Whitespace", subtitle: "Review visible whitespace changes before applying fixes to library fields.")
                .padding(density.pagePadding)
            if seratoWatchdog.isSeratoRunning {
                SeratoRunningBanner(message: "Serato is running — quit it before fixing whitespace.")
                Divider()
            }
            Text(WhitespacePreview.legend)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, density.pagePadding)
                .padding(.bottom, density.spacing)
            ResultListHeader(results: $results, enabled: !isScanning && !isFixing)
            issueListSection.disabled(isScanning || isFixing)
            Divider()
            footer
        }
        .task { await rescan() }
        .onChange(of: services.syncState) { _, _ in refreshConflictSelection() }
    }

    @ViewBuilder
    private var issueListSection: some View {
        if isScanning, issues.isEmpty {
            ProgressView("Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let actionError, issues.isEmpty {
            ActionErrorMessage(message: actionError)
        } else if issues.isEmpty {
            hygienePlaceholder(
                icon: "checkmark.seal",
                color: .green,
                headline: "No whitespace issues found",
                detail: "Every text field on every track is already trimmed."
            )
        } else {
            HygieneSelectionTable(results: $results, identities: trackIdentities, enabled: !isScanning && !isFixing,
                                  blockReason: { row in conflictReason(row) }, path: { $0.path }, field: { $0.field.displayName },
                                  oldValue: { WhitespacePreview(current: $0.oldValue, proposed: $0.newValue).visibleCurrent }, newValue: { WhitespacePreview(current: $0.oldValue, proposed: $0.newValue).visibleProposed })
        }
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
                Text("\(issues.count) field fixes across \(Set(issues.map(\.fileId)).count) tracks")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button {
                Task { await rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning || isFixing)
            ResultListControls(results: $results, enabled: !isScanning && !isFixing)
            Button("Apply \(results.selectedIDs.count) whitespace fixes") {
                Task { await fixAll() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(results.selectedIDs.isEmpty || isScanning || isFixing || seratoWatchdog.isSeratoRunning)
            .help(seratoWatchdog.isSeratoRunning
                ? "Quit Serato before applying — fixes write to Serato library files and would be clobbered on Serato's next save."
                : "Trim whitespace from every flagged field in one undoable batch.")
        }
    }

    private func rescan() async {
        isScanning = true
        defer { isScanning = false }
        actionError = nil
        do {
            files = try await services.database.writer.read { db in
                try HygieneFileRow.fetchAll(db, sql: HygieneFileRow.hygieneFetchSQL)
            }
            trackIdentities = TrackDisplayIdentity.index(files)
            issues = LibraryHygiene.findWhitespaceIssues(in: files)
        } catch {
            actionError = "Couldn't scan library: \(error.localizedDescription)"
        }
    }

    private func fixAll() async {
        isFixing = true
        defer { isFixing = false }
        actionError = nil
        lastResult = nil
        let selected = results.selectedRows
        let initialCount = selected.count
        let runner = LibraryHygieneRunner(operationEngine: services.operationEngine, activityLog: services.activityLog)
        do {
            _ = try await runner.applyWhitespaceFixes(selected, files: files)
            lastResult = "Trimmed whitespace on \(initialCount) field\(initialCount == 1 ? "" : "s")"
            await rescan()
        } catch {
            actionError = "Fix failed: \(error.localizedDescription)"
        }
    }

    private func conflictReason(_ row: some HygienePreviewEntry) -> String? {
        services.readiness.conflictPath(for: SeratoConflictTarget(fileIDs: [row.fileId], paths: [row.path])).map(SeratoConflictMessages.blocked)
    }

    private func refreshConflictSelection() {
        results.setBlockedIDs(Set(results.rows.filter { row in conflictReason(row) != nil }.map(\.id)))
    }
}
