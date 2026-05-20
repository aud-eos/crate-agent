import GRDB
import SwiftUI

/// Settings sheet for issue #59: move the entire watched library
/// into a different root folder. Default destination is
/// `~/Music/_DJ_Library_/` (per `UserPreferences.defaultLibraryRoot`).
///
/// Flow:
///   1. Render the current root and the proposed new root.
///   2. Scan tracked files; compute the move plan via
///      `LibraryMigrator.findMoves`.
///   3. Show the user a summary and a confirmation button.
///   4. On confirm: run `LibraryMigrator.migrate`, then update
///      `UserPreferences.watchedMusicFolder` and prompt for restart.
///
/// Same-volume only for SP-1. Gated on `!seratoWatchdog.isSeratoRunning`
/// like Resolve All — the per-file `renameFile` mutations write to
/// Serato library files and shouldn't compete with Serato.
struct MigrateLibrarySheet: View {

    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog
    @Environment(\.dismiss) private var dismiss

    @State private var newRoot: URL = (try? UserPreferences.defaultLibraryRoot())
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/_DJ_Library_")
    @State private var plans: [LibraryMigrator.Plan] = []
    @State private var isScanning: Bool = false
    @State private var isApplying: Bool = false
    @State private var actionError: String?
    @State private var lastResult: String?
    @State private var pendingConfirm: Bool = false
    @State private var showRestartAlert: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 480)
        .task { await rescan() }
        .alert(
            "Move \(plans.count) file\(plans.count == 1 ? "" : "s") to the new library?",
            isPresented: $pendingConfirm
        ) {
            Button("Move \(plans.count) file\(plans.count == 1 ? "" : "s")") {
                Task { await applyMigration() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each file moves from \(services.watchedMusicFolder.path) to \(newRoot.path), preserving the letter buckets. The DB and Serato library update in one undoable batch — one Undo on History reverses the entire move.")
        }
        .alert("Restart required", isPresented: $showRestartAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text("crate-agent will start watching \(newRoot.lastPathComponent) the next time it launches.")
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Move Library")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                pathRow(label: "Currently at", path: services.watchedMusicFolder.path)
                pathRow(label: "New location", path: newRoot.path, isDestination: true)
            }
            HStack(spacing: 8) {
                FolderPickerButton(
                    title: "Change Destination…",
                    message: "Pick a different folder for the new library root."
                ) { pickedUrl in
                    newRoot = pickedUrl
                    Task { await rescan() }
                }
                .controlSize(.small)

                Button("Use _DJ_Library_") {
                    if let recommended = try? UserPreferences.defaultLibraryRoot() {
                        newRoot = recommended
                        Task { await rescan() }
                    }
                }
                .controlSize(.small)
                .disabled(
                    (try? UserPreferences.defaultLibraryRoot())?.path == newRoot.path
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func pathRow(label: String, path: String, isDestination: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(isDestination ? .primary : .secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isScanning && plans.isEmpty {
            ProgressView("Planning move…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if plans.isEmpty {
            emptyState
        } else {
            planList
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text(emptyHeadline)
                .font(.headline)
            Text(emptyDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyHeadline: String {
        if services.watchedMusicFolder.path == newRoot.path {
            return "Source and destination are the same"
        }
        return "Nothing to move"
    }

    private var emptyDetail: String {
        if services.watchedMusicFolder.path == newRoot.path {
            return "Pick a different destination to see a move plan."
        }
        return "No tracked files were found under the current root. If you've already moved them manually, use \"Change Without Moving…\" in Settings instead."
    }

    @ViewBuilder
    private var planList: some View {
        List(plans) { plan in
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.sourcePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.right")
                        .foregroundStyle(.tertiary)
                        .font(.caption2)
                    Text(plan.destinationPath)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
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
            } else if !plans.isEmpty {
                Text("\(plans.count) file\(plans.count == 1 ? "" : "s") will move")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .disabled(isApplying)
            Button("Move Library") {
                pendingConfirm = true
            }
            .keyboardShortcut(.defaultAction)
            .disabled(plans.isEmpty || isApplying || seratoWatchdog.isSeratoRunning)
            .help(seratoWatchdog.isSeratoRunning
                  ? "Quit Serato before moving — the Serato library writes shouldn't run while Serato is open."
                  : "Move every tracked file to the new root and update Serato + DB in one batch.")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func rescan() async {
        isScanning = true
        defer { isScanning = false }
        actionError = nil
        do {
            let files = try await services.database.writer.read { db in
                try HygieneFileRow.fetchAll(db, sql: HygieneFileRow.hygieneFetchSQL)
            }
            plans = LibraryMigrator.findMoves(
                in: files,
                oldRoot: services.watchedMusicFolder,
                newRoot: newRoot
            )
        } catch {
            actionError = "Couldn't plan move: \(error.localizedDescription)"
        }
    }

    private func applyMigration() async {
        guard !plans.isEmpty else { return }
        isApplying = true
        defer { isApplying = false }
        actionError = nil
        lastResult = nil

        // Make sure the destination root exists. The migrator's
        // per-file `createDirectory(withIntermediateDirectories:)`
        // covers letter buckets, but the root itself is needed for
        // the children to land somewhere.
        do {
            try FileManager.default.createDirectory(
                at: newRoot,
                withIntermediateDirectories: true
            )
        } catch {
            actionError = "Couldn't create destination: \(error.localizedDescription)"
            return
        }

        let migrator = LibraryMigrator(
            operationEngine: services.operationEngine,
            activityLog: services.activityLog
        )
        do {
            let outcome = try await migrator.migrate(plans)
            if outcome.failureCount == 0 {
                lastResult = "Moved \(outcome.movedCount) file\(outcome.movedCount == 1 ? "" : "s")"
            } else {
                lastResult = "Moved \(outcome.movedCount); \(outcome.failureCount) skipped (see activity log)"
            }
            // Point the watched-folder preference at the new root
            // so the next launch picks up there.
            UserPreferences.watchedMusicFolder = newRoot
            showRestartAlert = true
        } catch {
            actionError = "Migration failed: \(error.localizedDescription)"
        }
    }
}
