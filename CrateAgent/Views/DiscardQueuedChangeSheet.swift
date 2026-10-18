import SwiftUI

/// Confirms discarding a queued Serato change that cannot apply (#163). The
/// preview and the discard both come from `OperationEngine`; this view only
/// shows what the engine reports.
struct DiscardQueuedChangeSheet: View {
    let change: QueuedSeratoChange
    let onDiscarded: (String) async -> Void
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var preview: QueuedChangeDiscardPreview?
    @State private var actionError: String?
    @State private var isDiscarding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SeratoRunningBanner(message: QueuedChangeDiscardMessages.runningHelp)
            VStack(alignment: .leading, spacing: density.spacing) {
                PageHeading(QueuedChangeDiscardMessages.confirmTitle, subtitle: fileName(change.path))
                Text(change.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = change.failure {
                    ActionErrorMessage(message: failure)
                } else {
                    Text(QueuedChangeDiscardMessages.waitingBehindFailure).font(.callout).foregroundStyle(.secondary)
                }
                details
                if let actionError {
                    ActionErrorMessage(message: actionError)
                }
            }
            .padding(density.pagePadding)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(QueuedChangeDiscardMessages.confirmAction, role: .destructive) {
                    Task { await discard() }
                }
                .disabled(preview?.laterChanges.isEmpty != true || isDiscarding)
                .seratoWriteGated(help: QueuedChangeDiscardMessages.confirmHelp, runningHelp: QueuedChangeDiscardMessages.runningHelp)
            }
            .padding(density.pagePadding)
        }
        .frame(minWidth: 480, idealWidth: 560)
        .appPresentation()
        .task { await load() }
    }

    @ViewBuilder
    private var details: some View {
        if let preview {
            if !preview.fieldChanges.isEmpty {
                Text(QueuedChangeDiscardMessages.revertsHeading).font(.headline)
                ForEach(preview.fieldChanges, id: \.self) { fieldChange in
                    Text(QueuedChangeDiscardMessages.fieldChange(fieldChange)).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if preview.writesBackOldValues {
                Label(QueuedChangeDiscardMessages.writesBack, systemImage: "arrow.uturn.backward.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !preview.laterChanges.isEmpty {
                Text(QueuedChangeDiscardMessages.laterChangesHeading).font(.headline)
                ForEach(preview.laterChanges) { later in
                    Text(fileName(later.path)).font(.callout)
                }
            }
        } else if actionError == nil {
            ProgressView().controlSize(.small)
        }
    }

    private func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func load() async {
        do {
            preview = try await services.operationEngine.discardPreview(batchID: change.batchID, fileID: change.fileID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func discard() async {
        isDiscarding = true
        defer { isDiscarding = false }
        let discarded = QueuedChangeDiscardMessages.discarded(fileName: fileName(change.path))
        do {
            try await services.operationEngine.discardQueuedChange(batchID: change.batchID, fileID: change.fileID)
            await onDiscarded(discarded)
            dismiss()
        } catch let OperationEngineError.externalSyncIncomplete(_, underlying) {
            // The discard committed; only writing old values back is unfinished.
            await onDiscarded("\(discarded) \(underlying)")
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }
}
