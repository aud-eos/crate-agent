import SwiftUI

/// Recent-activity timeline plus per-batch Undo controls. Reads the
/// `events` table via `EventHistoryQuery` and routes Undo clicks
/// into `OperationEngine.undoBatch`.
///
/// Presented as a sheet from the library browser — short-lived view,
/// loads its batches on appear and after every undo. No live
/// observation: history doesn't update fast enough for SwiftUI's
/// ValueObservation overhead to be worth the wiring.
struct HistoryView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var batches: [BatchSummary] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var undoInFlightBatchId: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("History")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await reload() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(isLoading)
                    }
                }
        }
        .frame(minWidth: 520, minHeight: 360)
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && batches.isEmpty {
            ProgressView("Loading history…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Couldn't load history")
                    .font(.headline)
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if batches.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No activity yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Renames, metadata edits, and imports will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @ViewBuilder
    private func row(for batch: BatchSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if batch.isUndoBatch {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .foregroundStyle(.tertiary)
                            .help("This batch was itself produced by undoing another batch.")
                    }
                    Text(batch.description)
                        .font(.body)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Text(batch.timestamp, style: .relative)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    + Text(" ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Undo") {
                Task { await undo(batch: batch) }
            }
            .disabled(!batch.canUndo || undoInFlightBatchId != nil)
            .help(batch.canUndo
                  ? "Reverse every change in this batch."
                  : "This batch contains operations that can't be undone yet (Serato-side imports/commits).")
        }
        .padding(.vertical, 4)
        .opacity(undoInFlightBatchId == batch.batchId ? 0.55 : 1)
    }

    @ViewBuilder
    private func actionErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { actionError = nil }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
}
