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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView {
                WhitespacePanel()
                    .tabItem { Label("Whitespace", systemImage: "scissors") }

                FindReplacePanel()
                    .tabItem { Label("Find & Replace", systemImage: "text.magnifyingglass") }

                CaseConsistencyPanel()
                    .tabItem { Label("Case", systemImage: "textformat") }

                MissingFieldsPanel()
                    .tabItem { Label("Missing", systemImage: "exclamationmark.bubble") }
            }
            .navigationTitle("Library Cleanup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 480)
    }
}

// MARK: - Whitespace panel

private struct WhitespacePanel: View {
    @EnvironmentObject private var services: AppServices

    @State private var files: [FileRecord] = []
    @State private var issues: [LibraryHygiene.WhitespaceIssue] = []
    @State private var isScanning: Bool = false
    @State private var isFixing: Bool = false
    @State private var actionError: String?
    @State private var lastResult: String?

    var body: some View {
        VStack(spacing: 0) {
            issueListSection
            Divider()
            footer
        }
        .task { await rescan() }
    }

    @ViewBuilder
    private var issueListSection: some View {
        if isScanning && issues.isEmpty {
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
                diffRow(
                    fieldName: issue.field.displayName,
                    path: issue.path,
                    oldValue: issue.oldValue,
                    newValue: issue.newValue
                )
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let lastResult {
                Label(lastResult, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("\(issues.count) issue\(issues.count == 1 ? "" : "s") found")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning || isFixing)
            Button("Fix All Whitespace") {
                Task { await fixAll() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(issues.isEmpty || isFixing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func rescan() async {
        isScanning = true
        defer { isScanning = false }
        actionError = nil
        do {
            files = try await services.database.writer.read { db in
                try FileRecord.fetchAll(db)
            }
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
        let runner = LibraryHygieneRunner(operationEngine: services.operationEngine)
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
    @EnvironmentObject private var services: AppServices

    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var caseSensitive: Bool = false
    @State private var selectedFields: Set<SeratoMetadataField> = [.artist, .title, .album]
    @State private var files: [FileRecord] = []
    @State private var matches: [LibraryHygiene.FindAndReplaceMatch] = []
    @State private var selectedMatchIds: Set<String> = []
    @State private var isApplying: Bool = false
    @State private var actionError: String?
    @State private var lastResult: String?

    var body: some View {
        VStack(spacing: 0) {
            queryForm
            Divider()
            matchesSection
            Divider()
            footer
        }
        .task { await loadFiles() }
    }

    @ViewBuilder
    private var queryForm: some View {
        Form {
            Section {
                TextField("Find", text: $findText)
                    .font(.body.monospaced())
                    .onChange(of: findText) { _, _ in recomputeMatches() }
                TextField("Replace with", text: $replaceText)
                    .font(.body.monospaced())
                    .onChange(of: replaceText) { _, _ in recomputeMatches() }
                Toggle("Match case", isOn: $caseSensitive)
                    .onChange(of: caseSensitive) { _, _ in recomputeMatches() }
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
            GridItem(.adaptive(minimum: 110, maximum: 160), alignment: .leading)
        ]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(SeratoMetadataField.allCases, id: \.rawValue) { field in
                Toggle(field.displayName, isOn: Binding(
                    get: { selectedFields.contains(field) },
                    set: { include in
                        if include { selectedFields.insert(field) } else { selectedFields.remove(field) }
                        recomputeMatches()
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
        .padding(.vertical, 4)
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
                HStack(alignment: .top, spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { selectedMatchIds.contains(match.id) },
                        set: { include in
                            if include { selectedMatchIds.insert(match.id) }
                            else { selectedMatchIds.remove(match.id) }
                        }
                    )) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    diffRow(
                        fieldName: match.field.displayName,
                        path: match.path,
                        oldValue: match.oldValue,
                        newValue: match.newValue
                    )
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let lastResult {
                Label(lastResult, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if !matches.isEmpty {
                Text("\(selectedMatchIds.count) of \(matches.count) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Select All") {
                selectedMatchIds = Set(matches.map(\.id))
            }
            .controlSize(.small)
            .disabled(matches.isEmpty)
            Button("Apply Selected") {
                Task { await applySelected() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedMatchIds.isEmpty || isApplying)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func loadFiles() async {
        do {
            files = try await services.database.writer.read { db in
                try FileRecord.fetchAll(db)
            }
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
        let runner = LibraryHygieneRunner(operationEngine: services.operationEngine)
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
    @EnvironmentObject private var services: AppServices

    @State private var files: [FileRecord] = []
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
            groupListSection
            Divider()
            footer
        }
        .task { await rescan() }
    }

    @ViewBuilder
    private var groupListSection: some View {
        if isScanning && groups.isEmpty {
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

    @ViewBuilder
    private func groupRow(_ group: LibraryHygiene.CaseInconsistencyGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(group.field.displayName)
                    .font(.caption.smallCaps())
                    .foregroundStyle(.tint)
                Text("\(group.totalFiles) file\(group.totalFiles == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(group.variants, id: \.value) { variant in
                let isChosen = resolvedCanonical(for: group) == variant.value
                HStack(spacing: 8) {
                    Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                        .onTapGesture {
                            resolutions[group.id] = .some(variant.value)
                        }
                    Text("«\(variant.value)»")
                        .font(.caption.monospaced())
                        .foregroundStyle(isChosen ? Color.primary : Color.secondary)
                    Spacer()
                    Text("\(variant.count) file\(variant.count == 1 ? "" : "s")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.secondary)
                }
            }
            HStack(spacing: 8) {
                Button("Skip this group") {
                    resolutions[group.id] = .some("")
                }
                .controlSize(.small)
                .disabled(resolvedCanonical(for: group) == nil)
                Button("Reset") {
                    resolutions[group.id] = nil
                }
                .controlSize(.small)
                .disabled(resolutions[group.id] == nil)
                Spacer()
                if resolvedCanonical(for: group) == nil {
                    Text("Skipped")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let lastResult {
                Label(lastResult, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("\(activeGroupCount) of \(groups.count) group\(groups.count == 1 ? "" : "s") will apply")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning || isApplying)
            Button("Apply Selections") {
                Task { await applySelections() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(activeGroupCount == 0 || isApplying)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            return nil  // skip
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
                try FileRecord.fetchAll(db)
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
        let runner = LibraryHygieneRunner(operationEngine: services.operationEngine)
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
    @EnvironmentObject private var services: AppServices

    @State private var files: [FileRecord] = []
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
                HStack(spacing: 8) {
                    ForEach(summaries) { summary in
                        Button {
                            selectedField = summary.field
                            recomputeEntries()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.field.displayName)
                                    .font(.caption.smallCaps())
                                Text("\(summary.count) missing")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color.secondary.opacity(0.05))
        }
    }

    @ViewBuilder
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
                    .font(.body.monospaced())
            } header: {
                Text("Bulk Fill")
            } footer: {
                Text("Sets the chosen field on every selected file to the supplied value. Rows already populated since the last scan are skipped at apply time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var entryListSection: some View {
        if isScanning && entries.isEmpty {
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
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { selectedEntryIds.contains(entry.id) },
                        set: { include in
                            if include { selectedEntryIds.insert(entry.id) }
                            else { selectedEntryIds.remove(entry.id) }
                        }
                    )) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    Text((entry.path as NSString).lastPathComponent)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(entry.field.displayName)
                        .font(.caption2.smallCaps())
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let lastResult {
                Label(lastResult, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if !entries.isEmpty {
                Text("\(selectedEntryIds.count) of \(entries.count) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning || isApplying)
            Button("Select All") {
                selectedEntryIds = Set(entries.map(\.id))
            }
            .controlSize(.small)
            .disabled(entries.isEmpty)
            Button("Apply Fill") {
                Task { await applyFill() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(canApply == false || isApplying)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var canApply: Bool {
        !selectedEntryIds.isEmpty
            && !fillValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func rescan() async {
        isScanning = true
        defer { isScanning = false }
        actionError = nil
        do {
            files = try await services.database.writer.read { db in
                try FileRecord.fetchAll(db)
            }
            summaries = LibraryHygiene.missingFieldSummaries(in: files)
            // If the previously-selected field has no gaps anymore,
            // jump to whichever field does. Avoids the user staring
            // at "Nothing missing" indefinitely.
            if !summaries.contains(where: { $0.field == selectedField }),
               let first = summaries.first?.field {
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
        let runner = LibraryHygieneRunner(operationEngine: services.operationEngine)
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

// MARK: - Shared

@ViewBuilder
private func diffRow(
    fieldName: String,
    path: String,
    oldValue: String,
    newValue: String
) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            Text(fieldName)
                .font(.caption.smallCaps())
                .foregroundStyle(.tint)
            Text((path as NSString).lastPathComponent)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("From")
                    .font(.caption2.smallCaps())
                    .foregroundStyle(.tertiary)
                Text("«\(oldValue)»")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("To")
                    .font(.caption2.smallCaps())
                    .foregroundStyle(.tertiary)
                Text("«\(newValue)»")
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
            }
        }
    }
}

@ViewBuilder
private func placeholderView(
    icon: String,
    color: Color,
    headline: String,
    detail: String
) -> some View {
    VStack(spacing: 8) {
        Image(systemName: icon)
            .font(.largeTitle)
            .foregroundStyle(color)
        Text(headline)
            .font(.headline)
        Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
