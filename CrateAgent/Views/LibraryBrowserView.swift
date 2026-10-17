import GRDB
import SwiftUI

struct LibraryBrowserView: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices

    @State private var statusFilter: LibraryStatusFilter = .active
    @State private var loadError: String?
    @State private var historyTarget: BrowserRow?
    @State private var model: LibraryBrowserModel?
    @State private var searchText: String = ""
    /// Debounced copy of `searchText` — drives the actual SQL query.
    /// Updated 150 ms after the user stops typing so fast typing
    /// doesn't trigger a query per keystroke.
    @State private var debouncedSearch: String = ""
    @State private var showRestartAlert: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var lastImportSummary: String?
    @State private var renameTarget: FileRecord?

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("Library", subtitle: "Search your indexed Serato tracks. Right-click a track to rename, open or reveal it in Finder.")
                .padding(density.pagePadding)
            statusHeader
            Divider()
            LibraryStatusFilterBar(selection: $statusFilter)
            if let loadError {
                ActionErrorMessage(message: loadError).padding(density.pagePadding)
            }
            ListSearchField(text: $searchText).padding(.horizontal, density.pagePadding).padding(.vertical, density.spacing)
            if let model {
                LibraryPagedContent(model: model, density: density, showsFilenames: statusFilter != .active, readiness: services.readiness,
                                    player: services.trackPlayer, opener: services.fileOpener)
                { identifier, action in
                    Task { await perform(action, for: identifier) }
                }
            } else if loadError == nil {
                ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Button(PagingLabels.retry) { Task { await initializeModel() } }
                Spacer()
            }
            Divider()
            footer
        }
        .frame(minWidth: 920, minHeight: 600)
        .appPresentation()
        // Debounce: 150 ms after typing settles, copy searchText to
        // debouncedSearch which is the actual query input.
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            if debouncedSearch != searchText {
                debouncedSearch = searchText
            }
        }
        .task { await initializeModel() }
        .onAppear(perform: applySearchRequest)
        .onChange(of: services.librarySearchRequest) { _, _ in applySearchRequest() }
        .onChange(of: debouncedSearch) { _, _ in updateQuery() }
        .onChange(of: statusFilter) { _, _ in updateQuery() }
        .onDisappear { model?.stop(); model = nil }
        .alert("Restart required", isPresented: $showRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("crate-agent will start watching the new folder the next time it launches.")
        }
        .overlay(alignment: .center) {
            if isDropTargeted {
                dropOverlay
            }
        }
        .dropDestination(for: URL.self) { droppedUrls, _ in
            let coordinator = services.importCoordinator
            Task { @MainActor in
                let result = await coordinator.importDroppedItems(droppedUrls)
                loadError = result.blockedFiles.isEmpty ? nil : result.blockedFiles.joined(separator: "\n")
                if result.filesPendingSync > 0 {
                    lastImportSummary = "\(result.filesImported) imported; \(result.filesPendingSync) pending sync; \(result.filesSkipped) skipped"
                    services.syncSession.reportFailure(
                        (["Import sync failed. Use Retry Sync to finish pending imports."] + result.syncFailures).joined(separator: "\n")
                    )
                } else {
                    lastImportSummary = result.filesImported == 0
                        ? "Nothing imported (\(result.filesSkipped) skipped)"
                        : "Imported \(result.filesImported) track\(result.filesImported == 1 ? "" : "s")"
                }
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .sheet(item: $historyTarget) { row in
            FileHistoryView(database: services.database, file: row)
        }
        .sheet(item: $renameTarget) { fileToRename in
            RenameDialogView(file: fileToRename)
                .environmentObject(services)
        }
    }

    private var dropOverlay: some View {
        VStack(spacing: density.spacing) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36))
            Text("Drop to import into Serato")
                .font(.headline)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        )
        .padding(40)
    }

    private var statusHeader: some View {
        HStack(spacing: density.spacing) {
            if let progress = services.scanProgress {
                ProgressView().controlSize(density.controlSize)
                Text("Syncing from Serato… \(progress.filesIndexed) new, \(progress.filesMetadataUpdated) updated, of \(progress.seratoReferenceCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if isRescanning {
                ProgressView().controlSize(density.controlSize)
                Text((services.syncPhase?.rawValue ?? "Checking saved library") + "…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let fingerprintError = services.fingerprintProgress?.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(fingerprintError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if let fingerprintProgress = services.fingerprintProgress,
                      fingerprintProgress.totalPending > 0
            {
                ProgressView().controlSize(density.controlSize)
                Text("Fingerprinting… \(fingerprintProgress.totalDone) done, \(fingerprintProgress.totalPending) pending")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if case .ready = services.syncState {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("Library in sync with Serato")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                services.open(.workers)
            } label: {
                Label(WorkerMessages.sectionTitle, systemImage: MainWindowView.Section.workers.iconName)
            }
            .help("Re-scan file info, stop a scan, and retry fingerprinting in Workers.")

            Text("Watching: \(services.watchedMusicFolder.path)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            FolderPickerButton(
                title: "Change…",
                message: "Choose the folder crate-agent should watch."
            ) { pickedUrl in
                UserPreferences.watchedMusicFolder = pickedUrl
                showRestartAlert = true
            }
            .controlSize(density.controlSize)
            .help("Watched folder for rename detection. crate-agent indexes only files Serato references; add tracks via Serato or drag-drop onto this window.")
        }
        .padding(.horizontal, density.pagePadding)
        .padding(.vertical, density.rowPadding)
    }

    private func applySearchRequest() {
        guard let request = services.consumeLibrarySearchRequest() else { return }
        statusFilter = .active
        searchText = request
    }

    private var isRescanning: Bool {
        if case .reconciling = services.syncState {
            return true
        }
        return false
    }

    private func initializeModel() async {
        guard model == nil else { return }
        do {
            let browser = try LibraryBrowserModel(database: services.database)
            model = browser
            loadError = nil
            await browser.start()
            updateQuery()
        } catch { loadError = error.localizedDescription }
    }

    private func updateQuery() {
        guard let model else { return }
        var query = model.query
        query.search = debouncedSearch
        query.filter = statusFilter
        model.setQuery(query)
    }

    private func perform(_ action: LibraryBrowserAction, for identifier: Int64) async {
        guard let model else { return }
        do {
            let record = try await model.resolveFile(id: identifier)
            switch action {
            case .rename:
                try FileProcessingEligibility.requireProcessable(record)
                try services.readiness.requireUnconflicted(.file(record))
                renameTarget = record
            case .history:
                historyTarget = BrowserRow(id: identifier, path: record.path, artist: record.artist, title: record.title,
                                           album: record.album, bpm: record.bpm, musicalKey: record.musicalKey,
                                           libraryMembership: record.libraryMembership, fileAvailability: record.fileAvailability,
                                           membershipRevision: record.membershipRevision)
            case let .open(target):
                await services.fileOpener.open(fileID: identifier, with: target)
            case .reveal:
                await services.fileOpener.reveal(fileID: identifier)
            }
        } catch { model.error = error.localizedDescription }
    }

    private var footer: some View {
        HStack(spacing: density.spacing) {
            if let summary = lastImportSummary {
                Text("·")
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
            Text("Rust core v\(coreVersion())")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, density.pagePadding)
        .padding(.vertical, density.rowPadding)
    }
}

struct LibraryStatusFilterBar: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @Binding var selection: LibraryStatusFilter

    var body: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            Picker("Library status", selection: $selection) {
                ForEach(LibraryStatusFilter.allCases) { filter in Text(filter.title).tag(filter) }
            }.pickerStyle(.segmented).frame(maxWidth: 480)
            Text(selection.detail).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, density.pagePadding)
        .padding(.vertical, density.rowPadding)
    }
}

struct LibraryFileStatusView: View {
    let file: BrowserRow
    var body: some View {
        Text(file.statusText)
            .font(.callout)
            .foregroundStyle(file.canProcess ? Color.secondary : Color.orange)
            .lineLimit(2)
            .help(file.statusText)
    }
}
