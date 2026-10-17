import GRDB
import SwiftUI

struct MissingFieldsPanel: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    @State private var trackIdentities: [String: TrackDisplayIdentity] = [:]
    @State private var files: [HygieneFileRow] = []
    @State private var summaries: [LibraryHygiene.MissingFieldSummary] = []
    @State private var selectedField: SeratoMetadataField = .artist
    @State private var fillValue: String = ""
    @State private var results = ListResultSelection<LibraryHygiene.MissingFieldEntry>()
    private var entries: [LibraryHygiene.MissingFieldEntry] {
        get { results.rows }
        nonmutating set {
            results.replaceHygiene(newValue, files: files, context: selectedField.rawValue, proposalRevision: LibraryHygiene.normalizedMissingFieldValue(fillValue), fileID: { $0.fileId })
            refreshConflictSelection()
        }
    }

    private var selectedEntryIds: Set<String> {
        results.selectedIDs
    }

    @State private var isScanning: Bool = false
    @State private var isApplying: Bool = false
    @State private var actionError: String?
    @State private var lastResult: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("Missing library fields", subtitle: "Choose a missing field and review the value to fill on selected tracks.")
                .padding(density.pagePadding)
            if seratoWatchdog.isSeratoRunning {
                SeratoRunningBanner(message: "Serato is running — quit it before filling missing fields.")
                Divider()
            }
            summaryBar.disabled(isScanning || isApplying)
            Divider()
            fillForm.disabled(isScanning || isApplying)
            Divider()
            ResultListHeader(results: $results, enabled: !isScanning && !isApplying)
            entryListSection.disabled(isScanning || isApplying)
            Divider()
            footer
        }
        .task { await rescan() }
        .onChange(of: services.syncState) { _, _ in refreshConflictSelection() }
    }

    @ViewBuilder
    private var summaryBar: some View {
        if isScanning {
            ProgressView("Scanning library…")
        } else if actionError != nil, files.isEmpty {
            EmptyView()
        } else if summaries.isEmpty {
            hygienePlaceholder(
                icon: "checkmark.seal",
                color: .green,
                headline: "No gaps detected",
                detail: "Every text field on every track has a value."
            )
            .frame(maxHeight: 140)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: density.spacing) {
                    ForEach(summaries) { summary in
                        Button {
                            selectedField = summary.field
                            recomputeEntries()
                        } label: {
                            VStack(alignment: .leading, spacing: density.detailSpacing) {
                                Text(summary.field.displayName)
                                    .font(.callout)
                                Text("\(summary.count) missing")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, density.rowPadding)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        summary.field == selectedField
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.3),
                                        lineWidth: summary.field == selectedField ? 2 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, density.pagePadding)
                .padding(.vertical, density.rowPadding)
            }
            .background(Color.secondary.opacity(0.05))
        }
    }

    private var fillForm: some View {
        Form {
            Section {
                Picker("Field", selection: $selectedField) {
                    ForEach(SeratoMetadataField.allCases, id: \.rawValue) { field in
                        Text(field.displayName).tag(field)
                    }
                }
                .onChange(of: selectedField) { _, _ in recomputeEntries() }
                TextField("Value to fill in", text: $fillValue)
                    .onChange(of: fillValue) { _, _ in recomputeEntries() }
                    .font(.body)
            } header: {
                Text("Bulk Fill")
            } footer: {
                Text("Sets the chosen field on every selected file to the supplied value. Rows already populated since the last scan are skipped at apply time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var entryListSection: some View {
        if isScanning, entries.isEmpty {
            ProgressView("Scanning…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let actionError, entries.isEmpty {
            ActionErrorMessage(message: actionError)
        } else if entries.isEmpty {
            hygienePlaceholder(
                icon: "checkmark.circle",
                color: .green,
                headline: "Nothing missing for \(selectedField.displayName)",
                detail: "Pick a different field above, or your library is clean for this one."
            )
        } else {
            HygieneSelectionTable(results: $results, identities: trackIdentities, enabled: !isScanning && !isApplying,
                                  contentRevision: fillValue, blockReason: { row in conflictReason(row) }, path: { $0.path }, field: { $0.field.displayName },
                                  oldValue: { _ in "Not set" }, newValue: { _ in LibraryHygiene.normalizedMissingFieldValue(fillValue) })
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
            } else if !entries.isEmpty {
                Text("\(selectedEntryIds.count) of \(entries.count) selected")
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
            Button("Fill \(selectedEntryIds.count) fields") {
                Task { await applyFill() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(canApply == false || isScanning || isApplying || seratoWatchdog.isSeratoRunning)
            .help(seratoWatchdog.isSeratoRunning
                ? "Quit Serato before applying — fixes write to Serato library files and would be clobbered on Serato's next save."
                : "Fill the chosen field on every selected track.")
        }
    }

    private var canApply: Bool {
        !selectedEntryIds.isEmpty
            && !LibraryHygiene.normalizedMissingFieldValue(fillValue).isEmpty
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
            summaries = LibraryHygiene.missingFieldSummaries(in: files)
            recomputeEntries()
        } catch {
            actionError = "Couldn't scan library: \(error.localizedDescription)"
        }
    }

    private func recomputeEntries() {
        entries = LibraryHygiene.missingFieldEntries(forField: selectedField, in: files)
    }

    private func applyFill() async {
        isApplying = true
        defer { isApplying = false }
        actionError = nil
        lastResult = nil
        let fileIds = entries.filter { selectedEntryIds.contains($0.id) }.map(\.fileId)
        let runner = LibraryHygieneRunner(operationEngine: services.operationEngine, activityLog: services.activityLog)
        do {
            _ = try await runner.applyMissingFieldFill(
                field: selectedField,
                value: fillValue,
                fileIds: fileIds,
                files: files
            )
            lastResult = "Filled \(selectedField.displayName) on \(fileIds.count) track\(fileIds.count == 1 ? "" : "s")"
            await rescan()
        } catch {
            actionError = "Apply failed: \(error.localizedDescription)"
        }
    }

    private func conflictReason(_ row: some HygienePreviewEntry) -> String? {
        services.readiness.conflictPath(for: SeratoConflictTarget(fileIDs: [row.fileId], paths: [row.path])).map(SeratoConflictMessages.blocked)
    }

    private func refreshConflictSelection() {
        results.setBlockedIDs(Set(results.rows.filter { row in conflictReason(row) != nil }.map(\.id)))
    }
}
