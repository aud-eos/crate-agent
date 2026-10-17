import SwiftUI

/// Background jobs and the library coverage they produce. Job state comes from the services
/// that own the jobs, so it is the same here as wherever the job was started.
struct WorkersView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var watchdog: SeratoWatchdog
    @ObservedObject var model: WorkersModel
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(WorkerMessages.sectionTitle,
                        subtitle: "Monitor and control background work. Job progress covers the current run; library coverage covers every indexed file.")
                .padding(density.pagePadding)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: density.spacing * 2) {
                    if let error = model.error {
                        ActionErrorMessage(message: error)
                    }
                    fileInfoJob
                    fingerprintJob
                    deferredWrites
                    coverage
                    drillDown
                }
                .padding(density.pagePadding)
            }
        }
        .frame(minWidth: 920, minHeight: 600)
        .appPresentation()
        .task { await model.monitor() }
    }

    // MARK: - Jobs

    private var fileInfoJob: some View {
        WorkerCard(title: "File-info scan") {
            HStack(spacing: density.spacing) {
                if isScanning {
                    ProgressView().controlSize(density.controlSize)
                }
                Text(fileInfoStatus).font(.callout.monospacedDigit())
                Spacer()
                if isScanning {
                    Button(WorkerMessages.stopSync, role: .cancel) { services.stopLibraryRescan() }
                } else {
                    Button {
                        services.requestLibraryRescan()
                    } label: {
                        Label(WorkerMessages.rescanFileInfo, systemImage: "arrow.clockwise")
                    }
                    .seratoWriteGated(help: WorkerMessages.rescanHelp, runningHelp: WorkerMessages.rescanRunningHelp)
                }
                if case .failed = services.syncState {
                    Button(WorkerMessages.retrySync) { services.retrySync() }
                }
            }
            if !services.syncFileInfoFailures.isEmpty {
                Text("File-info errors in the last scan (\(services.syncFileInfoFailures.count))")
                    .font(.callout.weight(.semibold)).foregroundStyle(.red)
                ForEach(Array(services.syncFileInfoFailures.prefix(WorkerCoverageQuery.drillDownLimit).enumerated()), id: \.offset) { entry in
                    Text(entry.element).font(.caption).textSelection(.enabled)
                }
            }
        }
    }

    private var fingerprintJob: some View {
        WorkerCard(title: "Fingerprinting") {
            HStack(spacing: density.spacing) {
                if let progress = services.fingerprintProgress, progress.error == nil, progress.totalPending > 0 {
                    ProgressView().controlSize(density.controlSize)
                }
                Text(fingerprintStatus).font(.callout.monospacedDigit())
                    .foregroundStyle(services.fingerprintProgress?.error == nil ? Color.primary : Color.red)
                Spacer()
                if services.fingerprintProgress?.error != nil {
                    Button("Retry Fingerprinting") { services.retryFingerprinting() }
                }
            }
            Text("Starts automatically and waits while library validation or Serato keeps processing closed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var deferredWrites: some View {
        WorkerCard(title: "Deferred Serato writes") {
            Text(deferredWriteStatus).font(.callout.monospacedDigit())
        }
    }

    // MARK: - Coverage

    @ViewBuilder
    private var coverage: some View {
        if let coverage = model.coverage {
            WorkerCard(title: "Library coverage") {
                let fingerprint = coverage.fingerprint
                Text("Fingerprints: \(fingerprint.done) of \(fingerprint.eligible) eligible files usable")
                    .font(.callout.weight(.semibold).monospacedDigit())
                CoverageLine(items: [
                    ("Pending", fingerprint.pending), ("Failed", fingerprint.failed), ("Invalid results", fingerprint.invalid),
                ])
                CoverageLine(items: [
                    ("Not eligible: unavailable", fingerprint.unavailable), ("awaiting Serato confirmation", fingerprint.awaitingMembership),
                    ("removed from Serato", fingerprint.removedFromSerato),
                ])
                let fileInfo = coverage.fileInfo
                Text("Files: \(fileInfo.available) of \(fileInfo.indexed) indexed files available")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .padding(.top, density.spacing)
                CoverageLine(items: [
                    ("Missing", fileInfo.missing), ("In Trash", fileInfo.trashed), ("Offline", fileInfo.offline),
                    ("Inaccessible", fileInfo.inaccessible), ("Not yet checked", fileInfo.unknown),
                ])
                Text("Removed from Serato: \(fileInfo.removedFromSerato)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            ProgressView("Reading library coverage…")
        }
    }

    private var drillDown: some View {
        WorkerCard(title: "Files needing attention") {
            HStack(spacing: density.spacing) {
                Picker("Show", selection: Binding(get: { model.category }, set: { category in Task { await model.show(category) } })) {
                    ForEach(WorkerFileCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)
                Spacer()
                if model.category.isRetryable {
                    Button("Retry Selected (\(model.selectedFileIDs.count))") { Task { await model.retrySelected() } }
                        .disabled(model.selectedFileIDs.isEmpty)
                    Button("Retry All Failed and Invalid") { Task { await model.retryAllFailed() } }
                }
            }
            if let result = model.lastRetryResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
            if model.rows.isEmpty {
                Text("No files in \(model.category.title).").font(.callout).foregroundStyle(.secondary)
            } else {
                if model.rows.count == WorkerCoverageQuery.drillDownLimit {
                    Text("Showing the first \(WorkerCoverageQuery.drillDownLimit) files.").font(.caption).foregroundStyle(.secondary)
                }
                List(model.rows, selection: $model.selectedFileIDs) { row in
                    WorkerFileRowView(row: row, showInLibrary: { services.showInLibrary(path: row.path) },
                                      reveal: { Task { await services.fileOpener.reveal(fileID: row.id) } })
                }
                .frame(minHeight: 260)
            }
        }
    }

    // MARK: - Status text

    private var isScanning: Bool {
        if case .reconciling = services.syncState {
            return true
        }
        return false
    }

    private var fileInfoStatus: String {
        if let progress = services.scanProgress {
            let checked = progress.completedFileCount.map { completed in "\(completed) of \(progress.seratoReferenceCount) checked, " } ?? ""
            return "Scanning: \(checked)\(progress.filesIndexed) new, \(progress.filesMetadataUpdated) updated"
        }
        switch services.syncState {
        case .idle: return "Idle."
        case .waitingForSerato: return "Waiting for Serato to close."
        case .reconciling: return (services.syncPhase?.rawValue ?? "Checking saved library") + "…"
        case .ready: return "Last scan finished; library in sync with Serato."
        case let .failed(message): return message
        }
    }

    private var fingerprintStatus: String {
        guard let progress = services.fingerprintProgress else { return "Not started yet." }
        if let error = progress.error {
            return error
        }
        let run = "This run: \(progress.totalDone) fingerprinted, \(progress.totalFailed) failed"
        return progress.totalPending > 0 ? run + ", \(progress.totalPending) pending." : run + "; nothing pending."
    }

    private var deferredWriteStatus: String {
        let depth = services.pendingSeratoQueueDepth
        guard depth > 0 else { return "No queued Serato library writes." }
        let reason = watchdog.isSeratoRunning ? "waiting for Serato to close" : "waiting for the next sync"
        return "\(depth) queued Serato library write(s), \(reason)."
    }
}

private struct WorkerCard<Content: View>: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(density.pagePadding)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CoverageLine: View {
    let items: [(String, Int)]

    var body: some View {
        Text(items.map { item in "\(item.0): \(item.1)" }.joined(separator: " · "))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

private struct WorkerFileRowView: View {
    let row: WorkerFileRow
    let showInLibrary: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if let detail = row.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            Button("Show in Library", action: showInLibrary).controlSize(.small)
            Button(FileOpenerMessages.reveal, action: reveal)
                .controlSize(.small)
                .disabled(row.availability != .available)
        }
        .tag(row.id)
    }
}
