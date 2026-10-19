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

    @State private var batches: [BatchSummary] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var actionNotice: String?
    @State private var undoInFlightBatchId: String?
    @State private var resyncInFlightBatchId: String?
    @State private var discardTarget: QueuedSeratoChange?

    var body: some View {
        VStack(spacing: 0) {
            SeratoRunningBanner(message: SeratoGateMessages.quitBefore("re-syncing"))
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
        .sheet(item: $discardTarget) { change in
            DiscardQueuedChangeSheet(change: change) { message in
                actionError = nil
                actionNotice = message
                await reload()
            }
            .environmentObject(services)
            .environmentObject(services.seratoWatchdog)
        }
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
                    actionBanner(actionError, systemImage: "exclamationmark.triangle.fill", tint: .orange) { self.actionError = nil }
                } else if let actionNotice {
                    actionBanner(actionNotice, systemImage: "checkmark.circle", tint: .green) { self.actionNotice = nil }
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
                } else if batch.isDiscardBatch {
                    StatusBadge(title: QueuedChangeDiscardMessages.discardedBatchBadge, systemImage: "xmark.circle")
                } else {
                    StatusBadge(title: batch.isUndoBatch ? "Undo batch" : "Recorded changes",
                                systemImage: batch.isUndoBatch ? "arrow.uturn.backward.circle" : "clock")
                }
                if !batch.stuckChanges.isEmpty {
                    stuckChanges(batch.stuckChanges)
                }
                if batch.notApplied.hasRecordedChanges {
                    if batch.notApplied.changeCount > 0 {
                        StatusBadge(title: SeratoWriteDispositionMessages.historyBadge(count: batch.notApplied.changeCount),
                                    systemImage: "exclamationmark.triangle", tint: .orange)
                            .help(SeratoWriteDispositionMessages.historyHelp)
                    }
                    if batch.notApplied.resolvedChangeCount > 0 {
                        Label(SeratoWriteDispositionMessages.resolvedSummary(count: batch.notApplied.resolvedChangeCount), systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(batch.notApplied.reasons, id: \.self) { reason in
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    NotAppliedFilesList(batch: batch, database: services.database,
                                        actionsDisabled: resyncInFlightBatchId != nil || undoInFlightBatchId != nil)
                    { file in
                        guard let fileID = file.fileID else { return }
                        await resync(batch: batch, fileID: fileID)
                    }
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
                .disabled(resyncInFlightBatchId != nil || undoInFlightBatchId != nil)
                .seratoWriteGated(help: "Re-run this batch's Serato library and audio-tag writes. Newer edits made in external tag editors can be overwritten.",
                                  runningHelp: SeratoGateMessages.quitBefore("re-syncing"))
            }

            Button("Undo") {
                Task { await undo(batch: batch) }
            }
            .disabled(!batch.canUndo || undoInFlightBatchId != nil || resyncInFlightBatchId != nil)
            .help(batch.undoUnavailableReason ?? "Reverse every change in this batch.")
        }
        .padding(.vertical, density.rowPadding)
    }

    /// Queued changes that cannot apply, each with its discard action.
    private func stuckChanges(_ changes: [QueuedSeratoChange]) -> some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            StatusBadge(title: QueuedChangeDiscardMessages.historySummary(count: changes.count), systemImage: "exclamationmark.octagon", tint: .orange)
            ForEach(changes) { change in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((change.path as NSString).lastPathComponent).font(.callout).textSelection(.enabled)
                        Text(change.failure ?? QueuedChangeDiscardMessages.waitingBehindFailure)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(QueuedChangeDiscardMessages.discardAction) { discardTarget = change }
                        .controlSize(.small)
                        .disabled(undoInFlightBatchId != nil || resyncInFlightBatchId != nil)
                        .seratoWriteGated(help: QueuedChangeDiscardMessages.confirmHelp, runningHelp: QueuedChangeDiscardMessages.runningHelp)
                }
            }
        }
    }

    private func actionBanner(_ message: String, systemImage: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        ActionBar {
            Label(message, systemImage: systemImage)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button(CommonLabels.dismiss, action: dismiss)
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

    private func resync(batch: BatchSummary, fileID: Int64? = nil) async {
        resyncInFlightBatchId = batch.batchId
        defer { resyncInFlightBatchId = nil }
        do {
            let outcome = try await services.operationEngine.resyncSeratoForBatch(batch.batchId, fileID: fileID)
            // The activity strip's message scrolls past quickly, so History
            // keeps the outcome on its own banner until dismissed.
            if outcome.missingTargetCount > 0 || (outcome.queuedCount > 0 && outcome.appliedCount == 0) {
                actionError = outcome.summaryMessage
                actionNotice = nil
            } else {
                actionError = nil
                actionNotice = outcome.summaryMessage
            }
        } catch {
            actionError = "Re-sync failed: \(error.localizedDescription)"
            actionNotice = nil
        }
        await reload()
    }
}

/// The files a batch's not-applied changes touch, loaded a page at a time
/// only once the reader asks for them.
private struct NotAppliedFilesList: View {
    let batch: BatchSummary
    let database: LibraryDatabase
    let actionsDisabled: Bool
    let resync: (NotAppliedFile) async -> Void
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @State private var isExpanded = false
    @State private var files: [NotAppliedFile] = []
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            DisclosureButton(showTitle: SeratoWriteDispositionMessages.showFiles(count: batch.notApplied.listedFileCount),
                             hideTitle: SeratoWriteDispositionMessages.hideFiles, isExpanded: $isExpanded)
                .onChange(of: isExpanded) { _, expanded in
                    if expanded, files.isEmpty {
                        Task { await loadPage() }
                    }
                }
            if isExpanded {
                ForEach(files) { file in
                    fileRow(file)
                }
                if let loadError {
                    ActionErrorMessage(message: loadError)
                } else if isLoading {
                    ProgressView().controlSize(.small)
                } else if !reachedEnd {
                    Button(SeratoWriteDispositionMessages.showMoreFiles(remaining: batch.notApplied.listedFileCount - files.count)) {
                        Task { await loadPage() }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func fileRow(_ file: NotAppliedFile) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.path ?? (file.fileID == nil ? SeratoWriteDispositionMessages.changeWithoutFile : SeratoWriteDispositionMessages.fileNoLongerInLibrary))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if file.isResolved {
                    Label(SeratoWriteDispositionMessages.fileResolved, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(file.reasons, id: \.self) { reason in
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if file.canResync {
                Button("Re-sync") {
                    Task {
                        await resync(file)
                        await reloadLoadedFiles()
                    }
                }
                .controlSize(.small)
                .accessibilityLabel(SeratoWriteDispositionMessages.fileResyncLabel(fileName: fileName(file)))
                .disabled(actionsDisabled)
                .seratoWriteGated(help: SeratoWriteDispositionMessages.fileResyncHelp, runningHelp: SeratoGateMessages.quitBefore("re-syncing"))
            }
        }
    }

    private func fileName(_ file: NotAppliedFile) -> String {
        file.path.map { path in (path as NSString).lastPathComponent } ?? SeratoWriteDispositionMessages.fileNoLongerInLibrary
    }

    private func loadPage() async {
        await load(after: files.last, limit: EventHistoryQuery.notAppliedFilePageSize) { page in files + page }
    }

    /// Re-reads the files already shown in one query and swaps them in, so
    /// the list never empties while it reloads.
    private func reloadLoadedFiles() async {
        await load(after: nil, limit: max(files.count, EventHistoryQuery.notAppliedFilePageSize)) { page in page }
    }

    private func load(after last: NotAppliedFile?, limit: Int, merge: ([NotAppliedFile]) -> [NotAppliedFile]) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await EventHistoryQuery.loadNotAppliedFiles(for: batch, database: database, limit: limit, after: last)
            files = merge(page)
            reachedEnd = page.count < limit
            loadError = nil
        } catch {
            loadError = "Could not load the affected files: \(error.localizedDescription)"
        }
    }
}

struct FileHistoryView: View {
    let database: LibraryDatabase
    let file: BrowserRow
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FileHistoryEntry] = []
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            FileHistoryContent(file: file, entries: entries, error: error)
            Button("Done") { dismiss() }.padding()
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            do {
                let fileID = file.id
                entries = try await database.writer.read { database in
                    try EventHistoryQuery.loadFileHistory(fileID: fileID, in: database).map(FileHistoryEntry.init)
                }
                error = nil
            } catch { self.error = "Could not load file history: \(error.localizedDescription)" }
        }
    }
}

struct FileHistoryEntry: Identifiable {
    let id: Int64
    let description: String
    let timestamp: Date

    init(event: EventRecord) throws {
        guard let eventID = event.eventId else { throw FileHistoryError.missingEventID }
        id = eventID
        description = try EventHistoryQuery.fileEventDescription(event)
        timestamp = Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000)
    }

    private enum FileHistoryError: Error { case missingEventID }
}

struct FileHistoryContent: View {
    let file: BrowserRow
    let entries: [FileHistoryEntry]
    var error: String?
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                PageHeading("File history", subtitle: file.filenameOnly)
                Text(file.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                LibraryFileStatusView(file: file)
                Text("Most recent 200 events for this file. Recorded observations do not restore audio or import it into Serato.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(density.pagePadding)
            Divider()
            if let error {
                ActionErrorMessage(message: error).padding(density.pagePadding)
            } else if entries.isEmpty {
                AppEmptyState(title: "No recorded changes", detail: "Future events for this file will appear here.", systemImage: "clock")
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: density.detailSpacing) {
                        Text(entry.description).font(.headline)
                        Text(entry.timestamp, format: .dateTime.month().day().hour().minute()).font(.callout).foregroundStyle(.secondary)
                    }.padding(.vertical, density.rowPadding)
                }.listStyle(.inset)
            }
        }.appPresentation()
    }
}
