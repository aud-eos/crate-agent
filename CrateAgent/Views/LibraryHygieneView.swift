import GRDB
import SwiftUI

/// SP-1.5's library cleanup surface. Today: trim leading/trailing
/// whitespace from any text metadata field across the library.
/// Future tabs (case normalization, find-and-replace, missing
/// fields) will hang off this same scan → preview → apply skeleton.
///
/// The view scans on appear, lists every detected issue (path + field
/// + diff between old and new), and gives the user one "Fix All"
/// action that batches every fix under a single `batch_id`. A
/// single Undo on the History view reverts the entire cleanup.
struct LibraryHygieneView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var files: [FileRecord] = []
    @State private var issues: [LibraryHygiene.WhitespaceIssue] = []
    @State private var isScanning: Bool = false
    @State private var isFixing: Bool = false
    @State private var actionError: String?
    @State private var lastResult: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library Cleanup")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await rescan() }
                        } label: {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                        .disabled(isScanning || isFixing)
                    }
                }
        }
        .frame(minWidth: 640, minHeight: 420)
        .task { await rescan() }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            issueListSection
            Divider()
            footer
        }
    }

    @ViewBuilder
    private var issueListSection: some View {
        if isScanning && issues.isEmpty {
            ProgressView("Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if issues.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("No whitespace issues found")
                    .font(.headline)
                Text("Every text field on every track is already trimmed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(issues) { issue in
                issueRow(issue)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func issueRow(_ issue: LibraryHygiene.WhitespaceIssue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(issue.field.displayName)
                    .font(.caption.smallCaps())
                    .foregroundStyle(.tint)
                Text((issue.path as NSString).lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(alignment: .top, spacing: 8) {
                diffLine(label: "From", value: issue.oldValue, color: .secondary)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                diffLine(label: "To", value: issue.newValue, color: .primary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func diffLine(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2.smallCaps())
                .foregroundStyle(.tertiary)
            // Surround with explicit guillemets so the user can see
            // the leading/trailing whitespace difference at a glance.
            Text("«\(value)»")
                .font(.caption.monospaced())
                .foregroundStyle(color)
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

        let runner = LibraryHygieneRunner(operationEngine: services.operationEngine)
        let initialIssueCount = issues.count
        do {
            _ = try await runner.applyWhitespaceFixes(issues, files: files)
            lastResult = "Trimmed whitespace on \(initialIssueCount) field\(initialIssueCount == 1 ? "" : "s")"
            await rescan()
        } catch {
            actionError = "Fix failed: \(error.localizedDescription)"
        }
    }
}
