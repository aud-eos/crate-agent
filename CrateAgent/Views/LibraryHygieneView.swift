import GRDB
import SwiftUI

/// SP-1.5's library cleanup surface. TabView containing per-feature
/// panels — Whitespace (trim leading/trailing), Find & Replace
/// (substring rewrite), Case (collapse inconsistent capitalizations
/// onto a canonical spelling). All panels share the scan → preview
/// → apply skeleton: an analyzer in `LibraryHygiene` derives a
/// structured issue list, the sheet renders a preview, and
/// `LibraryHygieneRunner` batches every fix under a single `batch_id`
/// so a single Undo on History reverts the entire cleanup.
struct LibraryHygieneView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        TabView {
            WhitespacePanel()
                .tabItem { Label("Whitespace", systemImage: "scissors") }

            FindReplacePanel()
                .tabItem { Label("Find & Replace", systemImage: "text.magnifyingglass") }

            CaseConsistencyPanel()
                .tabItem { Label("Case", systemImage: "textformat") }

            MissingFieldsPanel()
                .tabItem { Label("Missing", systemImage: "exclamationmark.bubble") }

            DuplicatesPanel()
                .tabItem { Label("Duplicates", systemImage: "square.on.square") }
        }
        .navigationTitle("Library Cleanup")
        .appPresentation()
        .frame(minWidth: 680, minHeight: 480)
    }
}

// MARK: - Whitespace panel

private struct WhitespacePanel: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    @State private var trackIdentities: [String: TrackDisplayIdentity] = [:]
    @State private var files: [HygieneFileRow] = []
    @State private var issues: [LibraryHygiene.WhitespaceIssue] = []
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
            issueListSection
            Divider()
            footer
        }
        .task { await rescan() }
    }

    @ViewBuilder
    private var issueListSection: some View {
        if isScanning, issues.isEmpty {
            ProgressView("Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if issues.isEmpty {
            placeholderView(
                icon: "checkmark.seal",
                color: .green,
                headline: "No whitespace issues found",
                detail: "Every text field on every track is already trimmed."
            )
        } else {
            List(issues) { issue in
                HygieneDiffRow(
                    fieldName: issue.field.displayName,
                    path: issue.path,
                    oldValue: issue.oldValue,
                    newValue: issue.newValue,
                    identity: trackIdentities[issue.path],
                    showsWhitespace: true
                )
            }
            .listStyle(.inset)
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
            Button("Apply \(issues.count) whitespace fixes") {
                Task { await fixAll() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(issues.isEmpty || isFixing || seratoWatchdog.isSeratoRunning)
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
        let initialCount = issues.count
        let runner = LibraryHygieneRunner(operationEngine: services.operationEngine, activityLog: services.activityLog)
        do {
            _ = try await runner.applyWhitespaceFixes(issues, files: files)
            lastResult = "Trimmed whitespace on \(initialCount) field\(initialCount == 1 ? "" : "s")"
            await rescan()
        } catch {
            actionError = "Fix failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Find & Replace panel

private struct FindReplacePanel: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var caseSensitive: Bool = false
    @State private var selectedFields: Set<SeratoMetadataField> = [.artist, .title, .album]
    @State private var trackIdentities: [String: TrackDisplayIdentity] = [:]
    @State private var files: [HygieneFileRow] = []
    @State private var matches: [LibraryHygiene.FindAndReplaceMatch] = []
    @State private var selectedMatchIds: Set<String> = []
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
            queryForm
            Divider()
            matchesSection
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
        if findText.isEmpty {
            placeholderView(
                icon: "text.magnifyingglass",
                color: .secondary,
                headline: "Enter a search string above",
                detail: "Replace text is substituted across every selected field. Toggle a row off to skip it."
            )
        } else if matches.isEmpty {
            placeholderView(
                icon: "checkmark.circle",
                color: .green,
                headline: "No matches",
                detail: "Nothing in the selected fields contains the search string."
            )
        } else {
            List(matches) { match in
                HStack(alignment: .top, spacing: density.spacing) {
                    Toggle(isOn: Binding(
                        get: { selectedMatchIds.contains(match.id) },
                        set: { include in
                            if include {
                                selectedMatchIds.insert(match.id)
                            } else {
                                selectedMatchIds.remove(match.id)
                            }
                        }
                    )) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("Select \(match.field.displayName) replacement for \((match.path as NSString).lastPathComponent)")

                    HygieneDiffRow(
                        fieldName: match.field.displayName,
                        path: match.path,
                        oldValue: match.oldValue,
                        newValue: match.newValue,
                        identity: trackIdentities[match.path]
                    )
                }
                .padding(.vertical, density.rowPadding)
            }
            .listStyle(.inset)
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
            Button("Select All") {
                selectedMatchIds = Set(matches.map(\.id))
            }
            .controlSize(density.controlSize)
            .disabled(matches.isEmpty)
            Button("Apply \(selectedMatchIds.count) replacements") {
                Task { await applySelected() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedMatchIds.isEmpty || isApplying || seratoWatchdog.isSeratoRunning)
            .help(seratoWatchdog.isSeratoRunning
                ? "Quit Serato before applying — fixes write to Serato library files and would be clobbered on Serato's next save."
                : "Apply the selected replacements in one undoable batch.")
        }
    }

    private func loadFiles() async {
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
        // Default every match to selected when the query changes —
        // the user can deselect rows before clicking Apply. Trying
        // to "preserve" previous selections across query changes
        // produced too many surprises (e.g., changing the find
        // string and seeing some unrelated row stay deselected).
        selectedMatchIds = Set(matches.map(\.id))
    }

    private func applySelected() async {
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

// MARK: - Case consistency panel

private struct CaseConsistencyPanel: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    @State private var files: [HygieneFileRow] = []
    @State private var groups: [LibraryHygiene.CaseInconsistencyGroup] = []
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
            if seratoWatchdog.isSeratoRunning {
                SeratoRunningBanner(message: "Serato is running — quit it before normalizing case.")
                Divider()
            }
            groupListSection
            Divider()
            footer
        }
        .task { await rescan() }
    }

    @ViewBuilder
    private var groupListSection: some View {
        if isScanning, groups.isEmpty {
            ProgressView("Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            placeholderView(
                icon: "checkmark.seal",
                color: .green,
                headline: "Case is consistent",
                detail: "No field has the same value spelled with multiple capitalizations."
            )
        } else {
            List(groups) { group in
                groupRow(group)
            }
            .listStyle(.inset)
        }
    }

    private func groupRow(_ group: LibraryHygiene.CaseInconsistencyGroup) -> some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            HStack(spacing: density.spacing) {
                Text(group.field.displayName)
                    .font(.callout)
                    .foregroundStyle(.tint)
                Text("\(group.totalFiles) file\(group.totalFiles == 1 ? "" : "s")")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
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
                    resolutions[group.id] = .some("")
                }
                .controlSize(density.controlSize)
                .disabled(resolvedCanonical(for: group) == nil)
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
            Button("Apply \(activeGroupCount) case groups") {
                Task { await applySelections() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(activeGroupCount == 0 || isApplying || seratoWatchdog.isSeratoRunning)
            .help(seratoWatchdog.isSeratoRunning
                ? "Quit Serato before applying — fixes write to Serato library files and would be clobbered on Serato's next save."
                : "Apply the selected canonicals in one undoable batch.")
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
        groups.filter { resolvedCanonical(for: $0) != nil }.count
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
            forGroups: groups,
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

// MARK: - Missing fields panel

private struct MissingFieldsPanel: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    @State private var trackIdentities: [String: TrackDisplayIdentity] = [:]
    @State private var files: [HygieneFileRow] = []
    @State private var summaries: [LibraryHygiene.MissingFieldSummary] = []
    @State private var selectedField: SeratoMetadataField = .artist
    @State private var fillValue: String = ""
    @State private var entries: [LibraryHygiene.MissingFieldEntry] = []
    @State private var selectedEntryIds: Set<String> = []
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
            summaryBar
            Divider()
            fillForm
            Divider()
            entryListSection
            Divider()
            footer
        }
        .task { await rescan() }
    }

    @ViewBuilder
    private var summaryBar: some View {
        if summaries.isEmpty {
            placeholderView(
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
        } else if entries.isEmpty {
            placeholderView(
                icon: "checkmark.circle",
                color: .green,
                headline: "Nothing missing for \(selectedField.displayName)",
                detail: "Pick a different field above, or your library is clean for this one."
            )
        } else {
            List(entries) { entry in
                HStack(spacing: density.spacing) {
                    Toggle(isOn: Binding(
                        get: { selectedEntryIds.contains(entry.id) },
                        set: { include in
                            if include {
                                selectedEntryIds.insert(entry.id)
                            } else {
                                selectedEntryIds.remove(entry.id)
                            }
                        }
                    )) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("Select missing \(entry.field.displayName) for \((entry.path as NSString).lastPathComponent)")
                    VStack(alignment: .leading, spacing: density.spacing) {
                        let identity = trackIdentities[entry.path]
                        TrackHeading(artist: identity?.artist, title: identity?.title, filename: (entry.path as NSString).lastPathComponent)
                        MissingFieldFillComparison(field: entry.field, value: fillValue)
                    }
                }
                .padding(.vertical, density.rowPadding)
            }
            .listStyle(.inset)
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
            Button("Select All") {
                selectedEntryIds = Set(entries.map(\.id))
            }
            .controlSize(density.controlSize)
            .disabled(entries.isEmpty)
            Button("Fill \(selectedEntryIds.count) fields") {
                Task { await applyFill() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(canApply == false || isApplying || seratoWatchdog.isSeratoRunning)
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
            // If the previously-selected field has no gaps anymore,
            // jump to whichever field does. Avoids the user staring
            // at "Nothing missing" indefinitely.
            if !summaries.contains(where: { $0.field == selectedField }),
               let first = summaries.first?.field
            {
                selectedField = first
            }
            recomputeEntries()
        } catch {
            actionError = "Couldn't scan library: \(error.localizedDescription)"
        }
    }

    private func recomputeEntries() {
        entries = LibraryHygiene.missingFieldEntries(forField: selectedField, in: files)
        selectedEntryIds = Set(entries.map(\.id))
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
}

// MARK: - Duplicates panel

private struct DuplicatesPanel: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    @State private var mode: DuplicateFinder.Mode = .byteLevel
    @State private var files: [FileRecord] = []
    @State private var groups: [DuplicateFinder.DuplicateGroup] = []
    /// Per-group user-chosen keeper id. When a group's id is absent
    /// from this map, we use the analyzer's default
    /// (DuplicateKeeperPicker.chooseDefaultKeeper). Per-group radio
    /// taps write into this dictionary.
    @State private var keeperOverrides: [String: Int64] = [:]
    @State private var isScanning: Bool = false
    @State private var isResolving: Bool = false
    @State private var actionError: String?
    @State private var lastResolution: String?
    @State private var pendingResolveGroup: DuplicateFinder.DuplicateGroup?
    @State private var pendingResolveAll: Bool = false
    /// Cached fingerprint coverage so the modeBar's "X of Y
    /// fingerprinted" label doesn't recompute over 32k rows on
    /// every render. Refreshed in `rescan()` alongside `groups`.
    @State private var fingerprintCoverage: (done: Int, total: Int) = (done: 0, total: 0)
    /// While a batch resolve-all is in flight, how many files of the
    /// planned total have made it to Trash so far. Drives the
    /// progress text in the action bar. Resets to (0,0) when idle.
    @State private var batchProgress: BatchProgress = .idle
    /// Memoized result of `DuplicateKeeperPicker.chooseDefaultKeeper`
    /// per group, layered with `keeperOverrides`. Rebuilt only when
    /// `groups` or `keeperOverrides` change. Previously the row
    /// body called the picker on every redraw — and every keeper-
    /// radio toggle invalidated all visible rows, fanning out to
    /// hundreds of redundant picker invocations per click.
    @State private var keeperIdByGroup: [String: Int64] = [:]

    private struct BatchProgress: Equatable {
        var trashed: Int
        var total: Int

        static let idle = BatchProgress(trashed: 0, total: 0)

        var isActive: Bool {
            total > 0
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("Duplicate tracks", subtitle: "Choose one keeper per group. Review the other copies before moving them to Trash.")
                .padding(density.pagePadding)
            if seratoWatchdog.isSeratoRunning {
                SeratoRunningBanner(message: "Serato is running — quit it before resolving duplicates.")
                Divider()
            }
            modeBar
            Divider()
            groupListSection
            Divider()
            footer
            if !groups.isEmpty {
                Divider()
                batchActionBar
            }
        }
        .task { await rescan() }
        // Cache invalidation: when the group set changes (after a
        // rescan, or after a resolve removed files) or the user
        // taps a different keeper radio, rebuild every group's
        // cached keeper id. The picker is non-trivial — running it
        // hundreds of times from a row body on every redraw was
        // the dominant cost of clicking through groups.
        .onChange(of: groups) { _, _ in rebuildKeeperCache() }
        .onChange(of: keeperOverrides) { _, _ in rebuildKeeperCache() }
        .alert(
            "Resolve duplicates?",
            isPresented: Binding(
                get: { pendingResolveGroup != nil },
                set: {
                    isPresented in if !isPresented {
                        pendingResolveGroup = nil
                    }
                }
            ),
            presenting: pendingResolveGroup
        ) { group in
            Button("Move \(group.size - 1) file\(group.size - 1 == 1 ? "" : "s") to Trash", role: .destructive) {
                Task { await resolve(group: group) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text("This moves \(group.size - 1) file\(group.size - 1 == 1 ? "" : "s") to your Trash, removes their entries from Serato's database, and strips them from any Serato crate that referenced them. The file in Trash stays restorable from Finder until you empty Trash. This action can't be undone from History.")
        }
        .alert(
            "Resolve all duplicate groups?",
            isPresented: $pendingResolveAll
        ) {
            Button("Move \(totalNonKeeperCount) file\(totalNonKeeperCount == 1 ? "" : "s") to Trash", role: .destructive) {
                Task { await resolveAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves \(totalNonKeeperCount) file\(totalNonKeeperCount == 1 ? "" : "s") across \(groups.count) group\(groups.count == 1 ? "" : "s") to your Trash, removes their entries from Serato's database, and strips them from any Serato crate that referenced them. Files in Trash stay restorable from Finder until you empty Trash. This action can't be undone from History. The keeper for each group is the one currently selected — change keepers before resolving if needed.")
        }
    }

    /// Global action affordance for the panel. Sits between the
    /// mode picker and the grouped List so the user sees an
    /// unambiguous "Resolve All" before any sticky per-group
    /// section header. Hidden when there are no groups (the
    /// list section renders its own empty state).
    private var batchActionBar: some View {
        ActionBar {
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                Text("\(groups.count) duplicate group\(groups.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.medium))
                if batchProgress.isActive {
                    Text("Resolving… \(batchProgress.trashed) of \(batchProgress.total) files trashed")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(totalNonKeeperCount) file\(totalNonKeeperCount == 1 ? "" : "s") will move to Trash")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } actions: {
            Button(role: .destructive) {
                pendingResolveAll = true
            } label: {
                Label("Move \(totalNonKeeperCount) duplicate files to Trash", systemImage: "trash")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(isResolving || seratoWatchdog.isSeratoRunning || totalNonKeeperCount == 0)
            .help(seratoWatchdog.isSeratoRunning
                ? "Quit Serato before resolving — Serato can clobber the database V2 changes from its in-memory cache."
                : "Trash every non-keeper across all groups in one undoable-as-an-audit-log batch.")
        }
        .background(Color.secondary.opacity(0.06))
    }

    private var modeBar: some View {
        HStack(spacing: density.spacing) {
            Picker("Mode", selection: $mode) {
                ForEach(DuplicateFinder.Mode.allCases, id: \.rawValue) { entry in
                    Text(entry.displayName).tag(entry)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .onChange(of: mode) { _, _ in
                groups = DuplicateFinder.findDuplicates(in: files, mode: mode)
            }
            Spacer()
            if mode == .perceptual {
                Text("\(fingerprintCoverage.done) of \(fingerprintCoverage.total) fingerprinted")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Perceptual matching needs Chromaprint fingerprints. Files still being fingerprinted in the background can't be matched yet — results improve as the fingerprint worker progresses.")
            }
        }
        .padding(.horizontal, density.pagePadding)
        .padding(.vertical, density.spacing)
    }

    @ViewBuilder
    private var groupListSection: some View {
        if isScanning, groups.isEmpty {
            ProgressView("Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            placeholderView(
                icon: "checkmark.seal",
                color: .green,
                headline: "No duplicates found",
                detail: modeEmptyDetail
            )
        } else {
            // ScrollView + LazyVStack rather than a sectioned List
            // because sectioned Lists on macOS get sticky section
            // headers — when the first section's header scrolls to
            // the top it reads as a global "apply all" affordance.
            // Per-group cards avoid the stickiness entirely and
            // make the per-group scope visually obvious.
            ScrollView {
                LazyVStack(spacing: density.spacing) {
                    ForEach(groups) { group in
                        groupCard(group)
                    }
                }
                .padding(.horizontal, density.pagePadding)
                .padding(.vertical, density.spacing)
            }
        }
    }

    private func groupCard(_ group: DuplicateFinder.DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            HStack(spacing: density.spacing) {
                Text("\(group.size) copies · \(modeHeader(for: group))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    pendingResolveGroup = group
                } label: {
                    Label("Trash \(group.size - 1) copies", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(density.controlSize)
                .disabled(isResolving || seratoWatchdog.isSeratoRunning)
                .help(seratoWatchdog.isSeratoRunning
                    ? "Quit Serato before resolving — Serato can clobber the database V2 changes from its in-memory cache."
                    : "Move non-keepers in this group to Trash and remove their Serato references in one batch.")
            }
            VStack(spacing: density.detailSpacing) {
                ForEach(group.files, id: \.id) { file in
                    duplicateRow(file: file, group: group)
                }
            }
        }
        .padding(.horizontal, density.pagePadding)
        .padding(.vertical, density.spacing)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private var modeEmptyDetail: String {
        switch mode {
        case .byteLevel:
            "No two files share the same content hash. (Byte-level duplicates would be the same file copied to two locations.)"
        case .perceptual:
            "No two fingerprinted files match each other. (Perceptual duplicates would be the same recording at different bitrates or in different formats.)"
        }
    }

    private func modeHeader(for group: DuplicateFinder.DuplicateGroup) -> String {
        switch group.mode {
        case .byteLevel:
            let first = group.files.first
            let size = first.map { Self.byteCountFormatter.string(fromByteCount: $0.fileSize) } ?? ""
            return "byte-level, \(size) each"
        case .perceptual:
            return "perceptual match"
        }
    }

    @ViewBuilder
    private func duplicateRow(
        file: FileRecord,
        group: DuplicateFinder.DuplicateGroup
    ) -> some View {
        let keeperId = effectiveKeeperId(for: group)
        let isKeeper = file.id == keeperId
        HStack(alignment: .top, spacing: density.spacing) {
            Button {
                if let identifier = file.id {
                    keeperOverrides[group.id] = identifier
                }
            } label: {
                Image(systemName: isKeeper ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isKeeper ? Color.accentColor : Color.secondary)
            .accessibilityLabel("Keep \((file.path as NSString).lastPathComponent)")
            .accessibilityValue(isKeeper ? "Selected keeper" : "Not selected")
            .help("Set as the keeper for this group.")
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                TrackHeading(artist: file.artist, title: file.title, filename: (file.path as NSString).lastPathComponent)
                Text(file.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(density == .comfortable ? 2 : 1)
                    .truncationMode(.middle)
                    .help(file.path)
                if isKeeper {
                    StatusBadge(title: "Keeper", systemImage: "checkmark.circle", tint: .accentColor)
                }
                HStack(spacing: density.spacing) {
                    Text(Self.byteCountFormatter.string(fromByteCount: file.fileSize))
                        .foregroundStyle(.secondary)
                    Text((file.path as NSString).pathExtension.uppercased())
                        .foregroundStyle(.secondary)
                    if let bitrate = file.bitrateKbps {
                        Text("\(bitrate) kbps")
                            .foregroundStyle(.secondary)
                    }
                    if group.mode == .perceptual {
                        statusBadge(file.fingerprintStatus)
                    }
                }
                .font(.callout.monospacedDigit())
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: file.path)]
                )
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Show this file in Finder so you can review or delete it manually.")
        }
        .padding(.vertical, density.rowPadding)
    }

    @ViewBuilder
    private func statusBadge(_ status: FingerprintStatus) -> some View {
        switch status {
        case .done:
            EmptyView()
        case .pending:
            Text("pending fingerprint")
                .foregroundStyle(.orange)
        case .failed:
            Text("fingerprint failed")
                .foregroundStyle(.red)
        }
    }

    private var footer: some View {
        ActionBar {
            if let actionError {
                ActionErrorMessage(message: actionError)
            } else if let lastResolution {
                Label(lastResolution, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Text("\(groups.count) duplicate group\(groups.count == 1 ? "" : "s") · \(totalDuplicateFiles) file\(totalDuplicateFiles == 1 ? "" : "s")")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button {
                Task { await rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning || isResolving)
        }
    }

    private var totalDuplicateFiles: Int {
        groups.reduce(0) { total, group in total + group.size }
    }

    /// Files that would be trashed if the user resolved every group
    /// with the current keeper selections. (One keeper survives per
    /// group; everything else goes to Trash.) Counts only groups
    /// that have a determinable keeper — groups with no keeper are
    /// skipped here and also skipped at apply time, so the count and
    /// the actual outcome stay aligned.
    private var totalNonKeeperCount: Int {
        groups.reduce(0) { accumulator, group in
            guard effectiveKeeperId(for: group) != nil else { return accumulator }
            return accumulator + (group.size - 1)
        }
    }

    private func rescan() async {
        isScanning = true
        defer { isScanning = false }
        actionError = nil
        do {
            files = try await services.database.writer.read { db in
                try FileRecord.all().processableInLibrary().fetchAll(db)
            }
            groups = DuplicateFinder.findDuplicates(in: files, mode: mode)
            // Refresh the cached perceptual-coverage tuple here so
            // the modeBar can read it without iterating `files`
            // on every SwiftUI redraw.
            fingerprintCoverage = DuplicateFinder.fingerprintCoverage(in: files)
            // Drop overrides for groups that no longer exist after
            // the rescan — preserves the user's per-group picks for
            // surviving groups while pruning stale ones.
            let currentIds = Set(groups.map(\.id))
            keeperOverrides = keeperOverrides.filter { entry in currentIds.contains(entry.key) }
        } catch {
            actionError = "Couldn't scan library: \(error.localizedDescription)"
        }
    }

    /// The id of the file we'd keep for this group — user's override
    /// if set, otherwise the keeper picker's default. Returns nil
    /// only for impossibly empty groups, which DuplicateFinder
    /// already excludes. Reads from the precomputed cache; callers
    /// must have called `rebuildKeeperCache()` after any mutation
    /// to `groups` or `keeperOverrides`.
    private func effectiveKeeperId(for group: DuplicateFinder.DuplicateGroup) -> Int64? {
        keeperIdByGroup[group.id]
    }

    /// Refresh the keeper cache for every current group. Runs the
    /// picker once per group, on demand — not in `body`.
    private func rebuildKeeperCache() {
        var refreshed: [String: Int64] = [:]
        refreshed.reserveCapacity(groups.count)
        let musicFolder = services.watchedMusicFolder
        for group in groups {
            if let override = keeperOverrides[group.id] {
                refreshed[group.id] = override
                continue
            }
            if let keeperId = DuplicateKeeperPicker.chooseDefaultKeeper(
                for: group,
                musicFolder: musicFolder
            ) {
                refreshed[group.id] = keeperId
            }
        }
        keeperIdByGroup = refreshed
    }

    private func resolve(group: DuplicateFinder.DuplicateGroup) async {
        guard let keeperId = effectiveKeeperId(for: group) else {
            actionError = "No keeper could be determined for this group."
            return
        }
        isResolving = true
        defer { isResolving = false }
        actionError = nil
        lastResolution = nil

        let resolver = DuplicateResolver(operationEngine: services.operationEngine, activityLog: services.activityLog)
        do {
            let outcome = try await resolver.resolve(group: group, keeperId: keeperId)
            if outcome.failureCount == 0 {
                lastResolution = "Moved \(outcome.trashedCount) duplicate\(outcome.trashedCount == 1 ? "" : "s") to Trash; \(outcome.pendingCount) pending until Serato closes"
            } else {
                actionError = "Moved \(outcome.trashedCount); \(outcome.pendingCount) pending; \(outcome.failureCount) stopped (see activity log)"
            }
            await rescan()
            await reportCleanupFailure()
        } catch {
            actionError = "Resolve failed: \(error.localizedDescription)"
        }
    }

    /// Resolve every group with its current keeper selection. Shares
    /// one `batch_id` across all groups so History shows a single
    /// audit entry. If a group fails mid-stream, the failure stops
    /// the loop and we report partial progress — groups already
    /// resolved stay resolved (Finder's Trash is the recovery path
    /// per group), and the user can rescan to see what's left.
    private func resolveAll() async {
        let resolvable: [(group: DuplicateFinder.DuplicateGroup, keeperId: Int64)] =
            groups.compactMap { group in
                guard let keeperId = effectiveKeeperId(for: group) else { return nil }
                return (group, keeperId)
            }
        guard !resolvable.isEmpty else {
            actionError = "No groups have a determinable keeper to resolve."
            return
        }

        isResolving = true
        defer {
            isResolving = false
            batchProgress = .idle
        }
        actionError = nil
        lastResolution = nil

        let plannedTotal = resolvable.reduce(0) { total, entry in total + (entry.group.size - 1) }
        batchProgress = BatchProgress(trashed: 0, total: plannedTotal)

        let sharedBatchId = "duplicate-resolve-all-\(UUID().uuidString)"
        let resolver = DuplicateResolver(operationEngine: services.operationEngine, activityLog: services.activityLog)

        var trashedSoFar = 0
        var pendingSoFar = 0
        var skippedSoFar = 0
        var groupsResolved = 0
        for entry in resolvable {
            do {
                let outcome = try await resolver.resolve(
                    group: entry.group,
                    keeperId: entry.keeperId,
                    batchId: sharedBatchId
                )
                trashedSoFar += outcome.trashedCount
                pendingSoFar += outcome.pendingCount
                skippedSoFar += outcome.failureCount
                groupsResolved += 1
                // Throttle: every progress mutation fires a full
                // redraw of the visible group cards, which is the
                // expensive bit (each card runs an Equatable diff
                // against its data). One update per 5 groups gives
                // the user a meaningful "still moving" signal
                // without paying N redraws for N resolutions.
                if groupsResolved.isMultiple(of: 5) || groupsResolved == resolvable.count {
                    batchProgress = BatchProgress(trashed: trashedSoFar, total: plannedTotal)
                }
            } catch {
                // Group-level failure (rare — `resolve` now
                // tolerates per-file errors internally; this
                // catches structural problems like
                // `keeperNotInGroup`).
                actionError = "Stopped after \(groupsResolved) group\(groupsResolved == 1 ? "" : "s"): \(error.localizedDescription)"
                break
            }
        }

        if actionError == nil {
            if skippedSoFar == 0 {
                lastResolution = "Moved \(trashedSoFar) file\(trashedSoFar == 1 ? "" : "s") across \(groupsResolved) group\(groupsResolved == 1 ? "" : "s") to Trash; \(pendingSoFar) pending until Serato closes"
            } else {
                lastResolution = "Moved \(trashedSoFar) file\(trashedSoFar == 1 ? "" : "s"); \(pendingSoFar) pending; \(skippedSoFar) stopped (see activity log)"
            }
        }
        await rescan()
        await reportCleanupFailure()
    }

    private func reportCleanupFailure() async {
        if let message = await services.operationEngine.failedDuplicateCleanupMessage {
            services.syncSession.reportFailure(message)
        }
    }
}

// MARK: - Shared

struct MissingFieldFillComparison: View {
    let field: SeratoMetadataField
    let value: String

    var comparison: MetadataComparison {
        MetadataComparison(current: nil, proposed: LibraryHygiene.normalizedMissingFieldValue(value), field: field.displayName)
    }

    var body: some View {
        comparison
    }
}

private struct HygieneDiffRow: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let fieldName: String
    let path: String
    let oldValue: String
    let newValue: String
    var identity: TrackDisplayIdentity?
    var showsWhitespace = false

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            TrackHeading(artist: identity?.artist, title: identity?.title, filename: (path as NSString).lastPathComponent)
            if showsWhitespace {
                let preview = WhitespacePreview(current: oldValue, proposed: newValue)
                MetadataComparison(current: preview.visibleCurrent, proposed: preview.visibleProposed, field: fieldName, emptyLabel: "Empty")
                Text(preview.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                MetadataComparison(current: oldValue, proposed: newValue, field: fieldName, emptyLabel: "Empty")
            }
        }
        .padding(.vertical, density.rowPadding)
        .help(path)
    }
}

private func placeholderView(
    icon: String,
    color: Color,
    headline: String,
    detail: String
) -> some View {
    AppEmptyState(title: headline, detail: detail, systemImage: icon, tint: color)
}
