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
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable

    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog
    @Environment(\.dismiss) private var dismiss

    @State private var newRoot: URL = (try? UserPreferences.defaultLibraryRoot())
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/_DJ_Library_")
    @State private var trackIdentities: [String: TrackDisplayIdentity] = [:]
    @State private var plans: [LibraryMigrator.Plan] = []
    @State private var query = ""
    @State private var searchIndex: [String: String] = [:]
    @State private var scanID = UUID()
    @State private var isScanning: Bool = false
    @State private var isApplying: Bool = false
    @State private var actionError: String?
    @State private var lastResult: String?
    @State private var pendingConfirm: Bool = false
    @State private var showRestartAlert: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if seratoWatchdog.isSeratoRunning {
                SeratoRunningBanner(message: "Serato is running — quit it before moving the library.")
                Divider()
            }
            header
            Divider()
            ListSearchField(text: $query).padding(.horizontal, density.pagePadding).disabled(isApplying)
            Text("Whole-library move · search filters the preview only").font(.callout).padding(.vertical, density.spacing)
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 600)
        .appPresentation()
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

    private var header: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            PageHeading("Move library", subtitle: "Review the new location before moving your tracked files.")
            MetadataComparison(current: services.watchedMusicFolder.path, proposed: newRoot.path, field: "Library folder")
            HStack(spacing: density.spacing) {
                FolderPickerButton(
                    title: "Change Destination…",
                    message: "Pick a different folder for the new library root."
                ) { pickedUrl in
                    newRoot = pickedUrl
                    Task { await rescan() }
                }
                .controlSize(density.controlSize)

                Button("Use _DJ_Library_") {
                    if let recommended = try? UserPreferences.defaultLibraryRoot() {
                        newRoot = recommended
                        Task { await rescan() }
                    }
                }
                .controlSize(density.controlSize)
                .disabled(
                    (try? UserPreferences.defaultLibraryRoot())?.path == newRoot.path
                )
            }
            .disabled(isApplying)
        }
        .padding(.horizontal, density.pagePadding)
        .padding(.vertical, density.spacing)
    }

    @ViewBuilder
    private var content: some View {
        if isScanning, plans.isEmpty {
            ProgressView("Planning move…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if plans.isEmpty {
            emptyState
        } else if visiblePlans.isEmpty {
            AppEmptyState(title: ListControlLabels.noMatches, detail: ListControlLabels.resetSearch, systemImage: "magnifyingglass")
        } else {
            planList
        }
    }

    private var emptyState: some View {
        VStack(spacing: density.spacing) {
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text(emptyHeadline)
                .font(.headline)
            Text(emptyDetail)
                .font(.callout)
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

    private var visiblePlans: [LibraryMigrator.Plan] {
        let needle = ListSearch.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return needle.isEmpty ? plans : plans.filter { (searchIndex[$0.sourcePath] ?? "").contains(needle) }
    }

    private var planList: some View {
        let rows = visiblePlans
        let identities = trackIdentities
        return VirtualizedPreviewTable(
            dataID: "\(scanID):\(query)", accessibilityLabel: "Library move preview", rowCount: rows.count,
            row: { index in rows[index] },
            columns: [
                PreviewTableColumn(identifier: "artist", title: "Artist", width: 150, text: { plan in identities[plan.sourcePath]?.artist ?? "" }),
                PreviewTableColumn(identifier: "title", title: "Title", width: 200, text: { plan in
                    identities[plan.sourcePath]?.title ?? (plan.sourcePath as NSString).lastPathComponent
                }),
                PreviewTableColumn(identifier: "source", title: "Current path", width: 300, text: { plan in plan.sourcePath }),
                PreviewTableColumn(identifier: "destination", title: "New path", width: 300, text: { plan in plan.destinationPath }),
            ],
            selection: nil, enabled: !isApplying, density: density
        )
    }

    private var footer: some View {
        ActionBar {
            if let actionError {
                ActionErrorMessage(message: actionError)
            } else if let lastResult {
                Label(lastResult, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else if !plans.isEmpty {
                Text("\(plans.count) file\(plans.count == 1 ? "" : "s") will move")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .disabled(isApplying)
            Button("Re-scan") { Task { await rescan() } }
                .disabled(isScanning || isApplying)
            Button("Move \(plans.count) files") {
                pendingConfirm = true
            }
            .keyboardShortcut(.defaultAction)
            .disabled(plans.isEmpty || isScanning || isApplying || seratoWatchdog.isSeratoRunning)
            .help(seratoWatchdog.isSeratoRunning
                ? "Quit Serato before moving — the Serato library writes shouldn't run while Serato is open."
                : "Move every tracked file to the new root and update Serato + DB in one batch.")
        }
    }

    // MARK: - Actions

    private func rescan() async {
        let requestID = UUID()
        scanID = requestID
        let destinationRoot = newRoot
        let oldRoot = services.watchedMusicFolder
        isScanning = true
        plans = []
        defer {
            if scanID == requestID {
                isScanning = false
            }
        }
        actionError = nil
        do {
            let preview = try await services.database.writer.read { database in
                let files = try HygieneFileRow.fetchAll(database, sql: HygieneFileRow.hygieneFetchSQL)
                let plans = try LibraryMigrator.prepareMoves(in: files, oldRoot: oldRoot, newRoot: destinationRoot)
                return (files, plans)
            }
            guard scanID == requestID else { return }
            trackIdentities = TrackDisplayIdentity.index(preview.0)
            searchIndex = ListSearch.index(preview.0).mapValues(ListSearch.normalized)
            plans = preview.1
        } catch {
            guard scanID == requestID else { return }
            actionError = "Couldn't plan move: \(error.localizedDescription)"
        }
    }

    private func applyMigration() async {
        guard !plans.isEmpty, !isScanning, !isApplying else { return }
        let destinationRoot = newRoot
        isApplying = true
        defer { isApplying = false }
        actionError = nil
        lastResult = nil

        let migrator = LibraryMigrator(
            operationEngine: services.operationEngine,
            activityLog: services.activityLog
        )
        do {
            let outcome = try await migrator.migrate(plans)
            if outcome.failureCount == 0 {
                lastResult = "Moved \(outcome.movedCount) file\(outcome.movedCount == 1 ? "" : "s")"
            } else {
                actionError = (["Moved \(outcome.movedCount); \(outcome.failureCount) skipped. Library folder unchanged."]
                    + Array(outcome.errors.prefix(3))
                    + ["See activity log for errors. Re-scan to retry, or undo the completed moves in History."]).joined(separator: "\n")
                plans = []
                return
            }
            let remaining = try await LibraryMigrator.remainingFileCount(in: services.database,
                                                                         oldRoot: services.watchedMusicFolder, newRoot: destinationRoot)
            guard remaining == 0 else {
                actionError = "Moved \(outcome.movedCount); \(remaining) tracked files still need migration, including unavailable files. Library folder unchanged. Restore availability and re-scan, or undo in History."
                plans = []
                return
            }
            // Point the watched-folder preference at the new root
            // so the next launch picks up there.
            UserPreferences.watchedMusicFolder = destinationRoot
            showRestartAlert = true
        } catch {
            plans = []
            actionError = "Migration failed: \(error.localizedDescription)"
        }
    }
}
