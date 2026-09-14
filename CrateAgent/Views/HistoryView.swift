import SwiftUI

/// Recent-activity timeline plus per-batch Undo controls. Reads the
/// `events` table via `EventHistoryQuery` and routes Undo clicks
/// into `OperationEngine.undoBatch`.
///
/// Lives as a standalone resizable window opened from the browser
/// toolbar (see `CrateAgentApp.historyContent`). No live observation:
/// history doesn't update fast enough for SwiftUI's ValueObservation
/// overhead to be worth the wiring — the Refresh button covers the
/// "I just made a change, show me" case.
struct HistoryView: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    @State private var batches: [BatchSummary] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var undoInFlightBatchId: String?
    @State private var resyncInFlightBatchId: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("History", subtitle: "Review recorded changes, undo a batch, or retry its external writes.")
                .padding(density.pagePadding)
            Divider()
            content
        }
        .appPresentation()
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, batches.isEmpty {
            ProgressView("Loading history…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            AppEmptyState(title: "Couldn't load history", detail: loadError, systemImage: "exclamationmark.triangle", tint: .orange)
        } else if batches.isEmpty {
            AppEmptyState(title: "No activity yet", detail: "Renames, metadata edits, and imports will appear here.", systemImage: "clock")
        } else {
            List(batches) { batch in
                row(for: batch)
            }
            .listStyle(.inset)
            .overlay(alignment: .bottom) {
                if let actionError {
                    actionErrorBanner(actionError)
                }
            }
        }
    }

    private func row(for batch: BatchSummary) -> some View {
        ActionBar {
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                Text(batch.description)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(batch.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if undoInFlightBatchId == batch.batchId {
                    ProgressView("Undoing batch…")
                } else if resyncInFlightBatchId == batch.batchId {
                    ProgressView("Re-syncing batch…")
                } else {
                    StatusBadge(title: batch.isUndoBatch ? "Undo batch" : "Recorded changes",
                                systemImage: batch.isUndoBatch ? "arrow.uturn.backward.circle" : "clock")
                }
            }
        } actions: {
            if batch.canResync {
                Button {
                    Task { await resync(batch: batch) }
                } label: {
                    Label("Re-sync Serato", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(density.controlSize)
                .disabled(resyncInFlightBatchId != nil || undoInFlightBatchId != nil || seratoWatchdog.isSeratoRunning)
                .help(seratoWatchdog.isSeratoRunning
                    ? "Quit Serato before re-syncing — writes would queue in memory and disappear on app restart."
                    : "Re-run this batch's Serato library and audio-tag writes. Newer edits made in external tag editors can be overwritten.")
            }

            Button("Undo") {
                Task { await undo(batch: batch) }
            }
            .disabled(!batch.canUndo || undoInFlightBatchId != nil || resyncInFlightBatchId != nil)
            .help(batch.canUndo
                ? "Reverse every change in this batch."
                : "This batch contains operations that can't be undone yet (Serato-side imports/commits).")
        }
        .padding(.vertical, density.rowPadding)
    }

    private func actionErrorBanner(_ message: String) -> some View {
        ActionBar {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Dismiss") { actionError = nil }
                .controlSize(density.controlSize)
        }
        .padding(.horizontal, density.pagePadding)
        .padding(.vertical, density.rowPadding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            batches = try await EventHistoryQuery.loadRecentBatches(
                database: services.database
            )
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func undo(batch: BatchSummary) async {
        undoInFlightBatchId = batch.batchId
        defer { undoInFlightBatchId = nil }
        do {
            _ = try await services.operationEngine.undoBatch(batch.batchId)
            actionError = nil
        } catch {
            actionError = "Undo failed: \(error.localizedDescription)"
        }
        await reload()
    }

    private func resync(batch: BatchSummary) async {
        resyncInFlightBatchId = batch.batchId
        defer { resyncInFlightBatchId = nil }
        do {
            let outcome = try await services.operationEngine.resyncSeratoForBatch(batch.batchId)
            actionError = nil
            // If the resync ended with queued-only writes, surface
            // it on the inline banner too — the activity strip
            // message scrolls past quickly, but History's banner
            // stays visible until the user dismisses or undoes.
            if outcome.queuedCount > 0, outcome.appliedCount == 0 {
                actionError = outcome.summaryMessage
            }
        } catch {
            actionError = "Re-sync failed: \(error.localizedDescription)"
        }
        await reload()
    }
}
