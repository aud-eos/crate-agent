import SwiftUI

struct AutoTaggerView: View {
    @ObservedObject var session: AutoTagSession
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @State private var showResetConfirmation = false
    @State private var chooserFile: ChooserFile?

    private struct ChooserFile: Identifiable { let id: Int64 }

    var body: some View {
        VStack(spacing: 0) {
            if seratoWatchdog.isSeratoRunning {
                SeratoRunningBanner(message: "Serato is running — applied library and tag writes queue until you quit Serato.")
                Divider()
            }
            if let fatalError = session.fatalError {
                ActionErrorMessage(message: fatalError).padding(density.pagePadding)
                Divider()
            }
            if session.scannedFileIDs.isEmpty {
                selectionStage
            } else {
                reviewStage
            }
        }
        .navigationTitle("Auto-Tag")
        .frame(minWidth: 680, minHeight: 480)
        .appPresentation()
        .confirmationDialog("Start a new scan?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Discard review and start new scan", role: .destructive) { session.reset() }
            Button("Keep reviewing", role: .cancel) {}
        } message: {
            Text("This stops any active lookup and discards this scan’s unapplied review decisions. Already applied changes remain in History.")
        }
        .sheet(item: $chooserFile) { file in AutoTagRecordingChooser(session: session, fileID: file.id) }
    }

    private var selectionStage: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: density.spacing) {
                PageHeading("Choose tracks to scan", subtitle: "Select files, look up their audio, then review and approve changes before applying tags.")
                Picker("Find tracks", selection: $session.selectionMode) {
                    Text("Browse untagged").tag(AutoTagSelectionMode.browse)
                    Text("Search").tag(AutoTagSelectionMode.search)
                }.pickerStyle(.segmented)
                if session.selectionMode == .browse {
                    Picker("Include", selection: Binding(get: { session.browseFilter }, set: session.setBrowseFilter)) {
                        ForEach(AutoTagBrowseFilter.allCases) { filter in Text(filter.title).tag(filter) }
                    }
                    Text("Missing fields means artist, title, or album in the indexed Serato library. Scanning reads the file’s actual tags. A MusicBrainz match identifies the recording; it does not mean this copy’s tags were written.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    TextField("Search by artist or title", text: Binding(get: { session.searchState.query }, set: session.updateSearchQuery))
                        .textFieldStyle(.roundedBorder)
                }
            }.padding(density.pagePadding)
            Divider()
            selectionResults
            if session.selectionMode == .browse {
                browsePagination
            }
            Divider()
            ActionBar {
                if let error = session.actionError {
                    ActionErrorMessage(message: error)
                } else {
                    Text("\(session.selectedFileIDs.count) selected across pages and searches").font(.callout.monospacedDigit())
                }
            } actions: {
                Button(session.selectionMode == .browse ? "Select this page" : "Select these results") {
                    session.selectVisibleFileIDs(visibleFiles.map(\.id))
                }.disabled(visibleFiles.isEmpty || selectionIsLoading || session.isScanning)
                Button("Clear selection", action: session.clearSelection).disabled(session.selectedFileIDs.isEmpty || session.isScanning)
                Button("Scan selected (\(session.selectedFileIDs.count))") { Task { await session.startScan() } }
                    .disabled(session.selectedFileIDs.isEmpty || session.isScanning || session.isApplying)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .task { await session.ensureBrowseLoaded() }
    }

    private var visibleFiles: [BrowserRow] {
        session.selectionMode == .browse ? session.browseResults.matches : session.searchState.results.matches
    }

    private var selectionIsLoading: Bool {
        session.selectionMode == .browse ? session.isBrowsing : session.searchState.isSearching
    }

    @ViewBuilder private var selectionResults: some View {
        let error = session.selectionMode == .browse ? session.browseError : session.searchState.error
        if selectionIsLoading {
            ProgressView("Loading tracks…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            VStack(spacing: density.spacing) {
                ActionErrorMessage(message: error)
                Button("Retry") {
                    Task {
                        if session.selectionMode == .browse {
                            await session.loadBrowsePage()
                        } else {
                            await session.performSearch()
                        }
                    }
                }
            }.padding(density.pagePadding).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.selectionMode == .search, session.searchState.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AppEmptyState(title: "Search to find tracks", detail: "Enter an artist or title. Your existing selections stay selected.", systemImage: "magnifyingglass")
        } else if visibleFiles.isEmpty {
            AppEmptyState(title: "No tracks found", detail: "Try another filter or search. Opening this view never scans or writes files.", systemImage: "music.note.list")
        } else {
            VStack(spacing: 0) {
                List(visibleFiles, id: \.id) { file in
                    AutoTagSelectionRow(fileID: file.id, path: file.path, artist: file.artist, title: file.title,
                                        isSelected: session.selectedFileIDs.contains(file.id),
                                        onToggle: { session.toggleSelection(file.id) })
                        .equatable().disabled(session.isScanning)
                }.listStyle(.inset)
                if session.selectionMode == .search, session.searchState.results.totalMatchCount > visibleFiles.count {
                    Text("Showing \(visibleFiles.count) of \(session.searchState.results.totalMatchCount) matches — refine your search for more.")
                        .font(.callout).foregroundStyle(.secondary).padding(density.spacing)
                }
            }
        }
    }

    private var browsePagination: some View {
        ActionBar {
            Text("Page \(session.browseResults.page + 1) · \(session.browseResults.totalMatchCount) matching files")
                .font(.callout.monospacedDigit())
        } actions: {
            Button("Previous page") { Task { await session.loadBrowsePage(session.browseResults.page - 1) } }
                .disabled(session.browseResults.page == 0 || session.isBrowsing)
            Button("Next page") { Task { await session.loadBrowsePage(session.browseResults.page + 1) } }
                .disabled(!session.browseResults.hasNextPage || session.isBrowsing)
        }
    }

    private var reviewStage: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: density.spacing) {
                PageHeading("Review audio matches", subtitle: "Approval stages your choices. Apply approved tracks writes them in one undoable batch.")
                Text("Audio match is the lookup’s fingerprint score; it does not verify tags, release, year or version. Multiple recording IDs may share one lookup score.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: density.spacing) {
                    Picker("Review mode", selection: $session.reviewMode) {
                        Text("List").tag(AutoTagReviewMode.list)
                        Text("Focus").tag(AutoTagReviewMode.focus)
                    }.pickerStyle(.segmented).frame(maxWidth: 220)
                    Spacer()
                    Text("\(session.completedCount) of \(session.totalCount) lookups finished").font(.callout.monospacedDigit())
                    if session.isScanning {
                        ProgressView().controlSize(density.controlSize)
                    }
                }
            }.padding(density.pagePadding)
            Divider()
            if session.reviewMode == .focus, let fileID = session.focusedFileID,
               let index = session.scannedFileIDs.firstIndex(of: fileID)
            {
                AutoTagFocusView(position: index + 1, total: session.totalCount,
                                 canApprove: session.canApprove(fileID: fileID),
                                 isApproved: session.confirmedFileIDs.contains(fileID),
                                 navigationEnabled: true, notice: session.focusNotice,
                                 previous: session.previous, next: session.next,
                                 approveAndAdvance: session.approveAndAdvance)
                {
                    reviewEntry(fileID, isFocused: true)
                }
            } else {
                List(session.scannedFileIDs, id: \.self) { fileID in reviewEntry(fileID, isFocused: false) }.listStyle(.inset)
            }
            Divider()
            reviewFooter
        }
    }

    @ViewBuilder private func reviewEntry(_ fileID: Int64, isFocused: Bool) -> some View {
        let file = session.filesByID[fileID]
        let path = file?.path ?? "File \(fileID) — no longer in the library"
        VStack(alignment: .leading, spacing: density.spacing) {
            if session.appliedFileIDs.contains(fileID) {
                StatusBadge(title: "Applied — read-only", systemImage: "checkmark.circle.fill", tint: .green)
            }
            if let model = session.rowModels[fileID] {
                AutoTagReviewRow(path: path, assessment: session.matchAssessment(for: fileID),
                                 model: Binding(get: { session.rowModels[fileID] ?? model }, set: { model in session.updateReviewModel(model, for: fileID) }),
                                 isConfirmed: Binding(get: { session.confirmedFileIDs.contains(fileID) }, set: { approved in session.setApproved(approved, for: fileID) }),
                                 canChooseRecording: hasAlternatives(fileID), onChooseRecording: { chooserFile = ChooserFile(id: fileID) }, isFocused: isFocused,
                                 isReadOnly: session.processingErrorByFileID[fileID] != nil || session.appliedFileIDs.contains(fileID) || session.isApplying || session.pendingRecordingFileIDs.contains(fileID),
                                 isApplied: session.appliedFileIDs.contains(fileID))
            } else {
                TrackHeading(artist: file?.artist, title: file?.title, filename: (path as NSString).lastPathComponent, prominent: isFocused)
                lookupStatus(fileID)
                if hasAlternatives(fileID) {
                    Button("Choose recording") { chooserFile = ChooserFile(id: fileID) }
                        .disabled(session.isApplying || session.appliedFileIDs.contains(fileID))
                }
            }
            if session.pendingRecordingFileIDs.contains(fileID) {
                ProgressView("Loading replacement recording…")
            }
            if let error = session.processingErrorByFileID[fileID] {
                ActionErrorMessage(message: error)
            }
            if let error = session.selectionErrorByFileID[fileID] {
                ActionErrorMessage(message: error)
            }
        }.padding(.vertical, density.rowPadding)
    }

    @ViewBuilder private func lookupStatus(_ fileID: Int64) -> some View {
        switch session.rows[fileID] {
        case .none, .pending: ProgressView("Looking up audio…")
        case .noMatch: StatusBadge(title: "No recording IDs returned", systemImage: "questionmark.circle", tint: .secondary)
        case let .failed(reason): ActionErrorMessage(message: reason)
        case let .stopped(reason): Label("Stopped — \(reason)", systemImage: "stop.circle").font(.body)
        case .strong, .weak: Text("Preparing review…").font(.body)
        }
    }

    private func hasAlternatives(_ fileID: Int64) -> Bool {
        !(session.lookupService.recordingAlternatives[fileID]?.entries.isEmpty ?? true)
    }

    private var reviewFooter: some View {
        ActionBar {
            if session.isApplying {
                ProgressView("Applying approved tracks…")
            } else if let error = session.actionError {
                ActionErrorMessage(message: error)
            } else if let result = session.lastResult {
                StatusBadge(title: result, systemImage: "checkmark.circle", tint: .green)
            } else {
                Text("\(session.confirmedFileIDs.count) approved · \(session.appliedFileIDs.count) applied").font(.body.monospacedDigit())
            }
        } actions: {
            Button("New Scan") {
                if session.requiresDiscardConfirmation {
                    showResetConfirmation = true
                } else {
                    session.reset()
                }
            }
            .disabled(session.isApplying || session.pendingResyncBatchId != nil)
            .help(session.pendingResyncBatchId == nil ? "Choose a new set of files to scan." : "Finish Re-sync before starting a new scan.")
            if session.isScanning {
                Button("Stop scan", action: session.stopScan).disabled(session.isApplying)
            }
            Menu("Approval") {
                Button("Approve suggested matches", action: session.approveAllSuggested)
                Button("Approve all ready matches") {
                    for fileID in session.scannedFileIDs {
                        session.setApproved(true, for: fileID)
                    }
                }
                Button("Clear approvals", action: session.clearApprovals)
            }.disabled(session.isApplying || session.rowModels.isEmpty)
            if session.pendingResyncBatchId != nil {
                Button("Re-sync") { Task { await session.resyncPartialApply() } }.disabled(session.isApplying)
            } else {
                Button("Apply approved tracks (\(session.confirmedFileIDs.count))") { Task { await session.applyConfirmed() } }
                    .disabled(session.confirmedFileIDs.isEmpty || session.isApplying || !session.pendingRecordingFileIDs.isDisjoint(with: session.confirmedFileIDs))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
