import GRDB
import SwiftUI

/// Sidebar tab for bulk file organization. Finds files whose
/// current path doesn't match their canonical destination
/// (`<MusicFolder>/<Letter>/<rendered-filename>.<ext>`) and lets
/// the user bulk-apply the moves. First use case: tracks dropped
/// into `~/Downloads`, soulseek dirs, etc. — pull them into the
/// main library folder.
struct OrganizeView: View {

    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    @State private var plans: [LibraryOrganizer.Plan] = []
    @State private var selection: Set<Int64> = []
    @State private var filter: Filter = .outsideOnly
    @State private var isScanning: Bool = false
    @State private var isApplying: Bool = false
    @State private var actionError: String?
    @State private var lastResult: String?
    @State private var pendingConfirm: Bool = false

    private enum Filter: String, CaseIterable, Identifiable {
        case outsideOnly
        case all

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .outsideOnly:  return "Outside music folder"
            case .all:          return "All"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if seratoWatchdog.isSeratoRunning {
                SeratoRunningBanner(message: "Serato is running — quit it before organizing.")
                Divider()
            }
            header
            Divider()
            content
            Divider()
            footer
        }
        .navigationTitle("Organize")
        .frame(minWidth: 720, minHeight: 480)
        .task { await rescan() }
        .alert(
            "Organize \(selectedPlans.count) file\(selectedPlans.count == 1 ? "" : "s")?",
            isPresented: $pendingConfirm
        ) {
            Button("Move \(selectedPlans.count) file\(selectedPlans.count == 1 ? "" : "s")") {
                Task { await applySelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each selected file moves to its canonical location under \(services.watchedMusicFolder.path). Serato references update in the same batch — one Undo on History reverts every move.")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .onChange(of: filter) { _, _ in
                // Selection only contains visible plans;
                // re-derive when the filter changes.
                let visibleIds = Set(visiblePlans.map(\.id))
                selection = selection.intersection(visibleIds)
            }
            Spacer()
            Text("Template: \(UserPreferences.filenameTemplate)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .help("Filename template applied to every move. Change it in Settings → General.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isScanning && plans.isEmpty {
            ProgressView("Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visiblePlans.isEmpty {
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
            Text(filter == .outsideOnly
                 ? "No files outside the music folder"
                 : "Every file is at its canonical path")
                .font(.headline)
            Text(filter == .outsideOnly
                 ? "Drop tracks here from Finder or import them; they'll land outside the folder and show up for organizing."
                 : "Filenames and letter buckets all match the configured template.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var planList: some View {
        List {
            ForEach(visiblePlans) { plan in
                planRow(plan)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func planRow(_ plan: LibraryOrganizer.Plan) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(
                get: { selection.contains(plan.id) },
                set: { include in
                    if include { selection.insert(plan.id) }
                    else { selection.remove(plan.id) }
                }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if plan.isOutsideMusicFolder {
                        Text("Outside")
                            .font(.caption2.smallCaps())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.orange.opacity(0.18))
                            )
                            .foregroundStyle(.orange)
                    } else {
                        Text("Inside")
                            .font(.caption2.smallCaps())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.blue.opacity(0.18))
                            )
                            .foregroundStyle(.blue)
                    }
                    Text(plan.sourcePath)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.right")
                        .foregroundStyle(.tertiary)
                        .font(.caption2)
                    Text(plan.destinationPath)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Footer

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
            } else if !visiblePlans.isEmpty {
                Text("\(selection.count) of \(visiblePlans.count) selected")
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
                selection = Set(visiblePlans.map(\.id))
            }
            .controlSize(.small)
            .disabled(visiblePlans.isEmpty)
            Button("Organize Selected") {
                pendingConfirm = true
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection.isEmpty || isApplying || seratoWatchdog.isSeratoRunning)
            .help(seratoWatchdog.isSeratoRunning
                  ? "Quit Serato before organizing — renames write to Serato library files and would be clobbered on Serato's next save."
                  : "Move every selected file into its canonical letter bucket and update Serato + DB in one batch.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Derived

    private var visiblePlans: [LibraryOrganizer.Plan] {
        switch filter {
        case .outsideOnly:
            return plans.filter(\.isOutsideMusicFolder)
        case .all:
            return plans
        }
    }

    private var selectedPlans: [LibraryOrganizer.Plan] {
        plans.filter { plan in selection.contains(plan.id) }
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
            let computedPlans = LibraryOrganizer.findMoves(
                in: files,
                musicFolder: services.watchedMusicFolder,
                template: UserPreferences.filenameTemplate
            )
            plans = computedPlans
            // Default selection: every visible plan. The user can
            // narrow before applying.
            selection = Set(visiblePlans.map(\.id))
        } catch {
            actionError = "Couldn't scan library: \(error.localizedDescription)"
        }
    }

    private func applySelected() async {
        let toApply = selectedPlans
        guard !toApply.isEmpty else { return }
        isApplying = true
        defer { isApplying = false }
        actionError = nil
        lastResult = nil

        let organizer = LibraryOrganizer(
            operationEngine: services.operationEngine,
            activityLog: services.activityLog
        )
        do {
            let outcome = try await organizer.organize(toApply)
            if outcome.failureCount == 0 {
                lastResult = "Organized \(outcome.movedCount) file\(outcome.movedCount == 1 ? "" : "s")"
            } else {
                lastResult = "Organized \(outcome.movedCount); \(outcome.failureCount) skipped (see activity log)"
            }
            await rescan()
        } catch {
            actionError = "Organize failed: \(error.localizedDescription)"
        }
    }
}
