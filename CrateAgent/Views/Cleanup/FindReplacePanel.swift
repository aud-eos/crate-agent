import GRDB
import SwiftUI

struct FindReplacePanel: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var caseSensitive: Bool = false
    @State private var selectedFields: Set<SeratoMetadataField> = [.artist, .title, .album]
    @State private var trackIdentities: [String: TrackDisplayIdentity] = [:]
    @State private var files: [HygieneFileRow] = []
    @State private var results = ListResultSelection<LibraryHygiene.FindAndReplaceMatch>()
    @State private var isLoading = false
    @State private var previewTrigger: FindReplaceTrigger?
    private var currentTrigger: FindReplaceTrigger {
        FindReplaceTrigger(find: findText, replace: replaceText, caseSensitive: caseSensitive, fields: selectedFields)
    }

    private var previewIsCurrent: Bool {
        previewTrigger == currentTrigger
    }

    private var matches: [LibraryHygiene.FindAndReplaceMatch] {
        get { results.rows }
        nonmutating set {
            results.replaceHygiene(newValue, files: files, context: "replace:\(caseSensitive):\(selectedFields.map(\.rawValue).sorted().joined(separator: ","))", fileID: { $0.fileId })
        }
    }

    private var selectedMatchIds: Set<String> {
        results.selectedIDs
    }

    @State private var isApplying: Bool = false
    @State private var actionError: String?
    @State private var lastResult: String?

    /// Combined trigger for the debounced recompute. Any change to
    /// these inputs invalidates pending matches; nothing else does.
    private struct FindReplaceTrigger: Hashable {
        let find: String
        let replace: String
        let caseSensitive: Bool
        let fields: Set<SeratoMetadataField>
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("Find and replace", subtitle: "Preview each field replacement and select only the changes you want.")
                .padding(density.pagePadding)
            if seratoWatchdog.isSeratoRunning {
                SeratoRunningBanner(message: "Serato is running — quit it before applying find/replace.")
                Divider()
            }
            queryForm.disabled(isApplying || isLoading)
            Divider()
            ResultListHeader(results: $results, enabled: !isApplying && !isLoading)
            matchesSection.disabled(isApplying || isLoading || !previewIsCurrent)
            Divider()
            footer
        }
        .task { await loadFiles() }
        // Debounce: every keystroke / field-toggle restarts this
        // task; the 150 ms sleep + cancellation check coalesces a
        // burst of typing into one recompute. Without this, every
        // character typed re-scanned the full file list on the
        // main thread (a 50k-track library = thousands of
        // string comparisons per keystroke).
        .task(id: FindReplaceTrigger(
            find: findText,
            replace: replaceText,
            caseSensitive: caseSensitive,
            fields: selectedFields
        )) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            recomputeMatches()
        }
    }

    private var queryForm: some View {
        Form {
            Section {
                TextField("Find", text: $findText)
                    .font(.body)
                TextField("Replace with", text: $replaceText)
                    .font(.body)
                Toggle("Match case", isOn: $caseSensitive)
            }
            Section("Fields") {
                fieldsRow
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var fieldsRow: some View {
        let columns = [
            GridItem(.adaptive(minimum: 110, maximum: 160), alignment: .leading),
        ]
        LazyVGrid(columns: columns, alignment: .leading, spacing: density.detailSpacing) {
            ForEach(SeratoMetadataField.allCases, id: \.rawValue) { field in
                Toggle(field.displayName, isOn: Binding(
                    get: { selectedFields.contains(field) },
                    set: { include in
                        if include {
                            selectedFields.insert(field)
                        } else {
                            selectedFields.remove(field)
                        }
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
        .padding(.vertical, density.rowPadding)
    }

    @ViewBuilder
    private var matchesSection: some View {
        if isLoading {
            ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let actionError, files.isEmpty {
            ActionErrorMessage(message: actionError)
        } else if findText.isEmpty {
            hygienePlaceholder(
                icon: "text.magnifyingglass",
                color: .secondary,
                headline: "Enter a search string above",
                detail: "Replace text is substituted across every selected field. Toggle a row off to skip it."
            )
        } else if matches.isEmpty {
            hygienePlaceholder(
                icon: "checkmark.circle",
                color: .green,
                headline: "No matches",
                detail: "Nothing in the selected fields contains the search string."
            )
        } else {
            HygieneSelectionTable(results: $results, identities: trackIdentities, enabled: !isApplying && !isLoading && previewIsCurrent,
                                  path: { $0.path }, field: { $0.field.displayName }, oldValue: { $0.oldValue }, newValue: { $0.newValue })
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
            } else if !matches.isEmpty {
                Text("\(selectedMatchIds.count) of \(matches.count) selected")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("Rescan") { Task { await loadFiles() } }.disabled(isApplying || isLoading)
            ResultListControls(results: $results, enabled: !isApplying && !isLoading && previewIsCurrent)
            Button("Apply \(selectedMatchIds.count) replacements") {
                Task { await applySelected() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedMatchIds.isEmpty || !previewIsCurrent || isLoading || isApplying || seratoWatchdog.isSeratoRunning)
            .help(seratoWatchdog.isSeratoRunning
                ? "Quit Serato before applying — fixes write to Serato library files and would be clobbered on Serato's next save."
                : "Apply the selected replacements in one undoable batch.")
        }
    }

    private func loadFiles() async {
        isLoading = true
        defer { isLoading = false }
        do {
            files = try await services.database.writer.read { db in
                try HygieneFileRow.fetchAll(db, sql: HygieneFileRow.hygieneFetchSQL)
            }
            trackIdentities = TrackDisplayIdentity.index(files)
            recomputeMatches()
        } catch {
            actionError = "Couldn't load library: \(error.localizedDescription)"
        }
    }

    private func recomputeMatches() {
        let query = LibraryHygiene.FindAndReplaceQuery(
            find: findText,
            replace: replaceText,
            fields: selectedFields,
            caseSensitive: caseSensitive
        )
        matches = LibraryHygiene.findAndReplaceMatches(in: files, query: query)
        previewTrigger = currentTrigger
    }

    private func applySelected() async {
        guard previewIsCurrent, !isLoading, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        actionError = nil
        lastResult = nil

        let selectedMatches = matches.filter { selectedMatchIds.contains($0.id) }
        let initialCount = selectedMatches.count
        let runner = LibraryHygieneRunner(operationEngine: services.operationEngine, activityLog: services.activityLog)
        do {
            _ = try await runner.applyFindAndReplaceFixes(selectedMatches, files: files)
            lastResult = "Replaced text in \(initialCount) field\(initialCount == 1 ? "" : "s")"
            await loadFiles()
        } catch {
            actionError = "Apply failed: \(error.localizedDescription)"
        }
    }
}
