import GRDB
import SwiftUI

/// SP-2's Auto-Tag review surface. Lets the user pick a set of tracks,
/// looks those (and only those) up against AcoustID/MusicBrainz via
/// `AutoTaggerService`, then lets the user review and selectively confirm
/// each resolved match before applying every confirmed row in one
/// undoable batch through `OperationEngine`. Models the select → scan →
/// preview → apply skeleton from `LibraryHygieneView`.
///
/// Ruling M: a pass must never fan out to the whole library unprompted.
/// Nothing is looked up until the user has explicitly selected tracks —
/// selection starts empty, "Scan Selected" is disabled at zero
/// selections, and the only way to add tracks to the selection is
/// `AutoTagFileSearch` — a search that never returns more than
/// `AutoTagFileSearch.resultCap` rows. There is no "select everything"
/// control, so no single action can ever queue up a library-wide pass.
///
/// `autoTaggerService` is taken as an explicit `@ObservedObject` init
/// parameter (rather than reached via `services.autoTaggerService`
/// inside the body) so its `@Published rows`/`fatalError` changes
/// actually drive re-renders — `AppServices` doesn't re-publish its
/// child services' own `@Published` properties.
struct AutoTaggerView: View {
    @ObservedObject var autoTaggerService: AutoTaggerService
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    /// "Current" (pre-match) tag snapshot, loaded only for files that
    /// have been scanned at least once — never the whole library. See
    /// `loadCurrentMetadata(forFileIDs:)`.
    @State private var filesByID: [Int64: FileRecord] = [:]
    @State private var currentYearByFileID: [Int64: Int?] = [:]

    /// Total row count in the `files` table, used only to distinguish
    /// "library is genuinely empty" from "nothing matches the current
    /// search" — a cheap `SELECT COUNT(*)`, never a full-table fetch.
    @State private var libraryFileCount: Int = 0

    /// The selection-stage search box and its debounced, capped results.
    @State private var searchQuery: String = ""
    @State private var searchResults: [BrowserRow] = []
    @State private var searchTotalMatchCount: Int = 0
    @State private var isSearching: Bool = false
    @State private var searchError: String?

    /// The user's checkbox picks across every search the user has run
    /// this session. Starts empty on every launch of this view — never
    /// defaults to "all" — and persists across query changes, so
    /// searching again to find more tracks doesn't lose earlier picks.
    @State private var selectedFileIDs: Set<Int64> = []
    /// The exact file IDs the most recent scan was run against.
    /// Drives which rows `reviewList` renders — NOT
    /// `autoTaggerService.rows`' full key set, which is shared,
    /// long-lived service state that can carry entries from a prior
    /// scan the current view instance never asked for.
    @State private var scannedFileIDs: [Int64] = []
    @State private var rowModels: [Int64: AutoTagRowModel] = [:]
    @State private var confirmedFileIDs: Set<Int64> = []
    /// File IDs whose match has already been written via `applyBatch`.
    /// Kept (rather than just deleting the row) so the row shows an
    /// "Applied" indicator instead of silently vanishing from the list.
    @State private var appliedFileIDs: Set<Int64> = []

    @State private var isLoadingLibraryCount: Bool = false
    @State private var isApplying: Bool = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var lastResult: String?

    var body: some View {
        VStack(spacing: 0) {
            if seratoWatchdog.isSeratoRunning {
                SeratoRunningBanner(message: "Serato is running — quit it before applying Auto-Tag matches.")
                Divider()
            }
            if let fatalMessage = autoTaggerService.fatalError {
                fatalBanner(fatalMessage)
                Divider()
            }
            content
            Divider()
            footer
        }
        .navigationTitle("Auto-Tag")
        .frame(minWidth: 680, minHeight: 480)
        .task { await loadLibraryFileCount() }
        .onChange(of: autoTaggerService.rows) { _, _ in syncRowModels() }
        // Debounce: every keystroke restarts this task; the sleep +
        // cancellation check coalesces a burst of typing into one
        // query. Without this, every character typed would fire a
        // fresh bounded DB read — cheap individually, but wasteful at
        // typing speed. Mirrors LibraryBrowserView's search debounce.
        .task(id: searchQuery) {
            let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuery.isEmpty else {
                searchResults = []
                searchTotalMatchCount = 0
                searchError = nil
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(query: trimmedQuery)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoadingLibraryCount {
            ProgressView("Loading library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            placeholder(icon: "exclamationmark.triangle", color: .orange, headline: "Couldn't load library", detail: loadError)
        } else if libraryFileCount == 0 {
            placeholder(
                icon: "tray",
                color: .secondary,
                headline: "No tracks indexed yet",
                detail: "Auto-Tag needs files in your library before it can look up matches."
            )
        } else if scannedFileIDs.isEmpty {
            selectionStage
        } else {
            reviewList
        }
    }

    // MARK: - Selection stage

    /// Search field + capped results. Never renders more than
    /// `AutoTagFileSearch.resultCap` rows, and renders nothing at all
    /// until the user types a query — the whole point being that this
    /// stage never materializes the whole library.
    private var selectionStage: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            selectionResultsSection
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search by artist or title…", text: $searchQuery)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var selectionResultsSection: some View {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if let searchError {
            placeholder(icon: "exclamationmark.triangle", color: .orange, headline: "Search failed", detail: searchError)
        } else if trimmedQuery.isEmpty {
            placeholder(
                icon: "magnifyingglass",
                color: .secondary,
                headline: "Search to select tracks",
                detail: "Auto-Tag never loads the whole library at once — search by artist or title to find tracks to scan."
            )
        } else if isSearching && searchResults.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchResults.isEmpty {
            placeholder(
                icon: "questionmark.circle",
                color: .secondary,
                headline: "No matches",
                detail: "No artist or title contains “\(trimmedQuery)”."
            )
        } else {
            VStack(spacing: 0) {
                selectionList
                if searchIsCapped {
                    Text("Showing first \(searchResults.count) of \(searchTotalMatchCount) — refine your search")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private var searchIsCapped: Bool {
        searchTotalMatchCount > searchResults.count
    }

    private var selectionList: some View {
        List(searchResults, id: \.id) { result in
            AutoTagSelectionRow(
                fileID: result.id,
                path: result.path,
                artist: result.artist,
                title: result.title,
                isSelected: selectedFileIDs.contains(result.id),
                onToggle: { toggleSelection(result.id) }
            )
            .equatable()
        }
        .listStyle(.inset)
    }

    // MARK: - Review stage

    private var reviewList: some View {
        List(scannedFileIDs, id: \.self) { fileID in
            if let file = filesByID[fileID] {
                rowContainer(fileID: fileID, path: file.path)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func rowContainer(fileID: Int64, path: String) -> some View {
        if appliedFileIDs.contains(fileID) {
            statusRow(path: path, systemImage: "checkmark.circle.fill", text: "Applied", tint: .green)
        } else {
            switch autoTaggerService.rows[fileID] {
            case .none, .pending:
                statusRow(path: path, systemImage: "hourglass", text: "Looking up…", tint: .secondary)
            case .noMatch:
                statusRow(path: path, systemImage: "questionmark.circle", text: "No match", tint: .secondary)
            case let .failed(reason):
                statusRow(path: path, systemImage: "exclamationmark.triangle", text: reason, tint: .orange)
            case .strong, .weak:
                if let binding = rowModelBinding(for: fileID) {
                    AutoTagReviewRow(
                        path: path,
                        score: autoTaggerService.candidate(for: fileID)?.score ?? 0,
                        isStrong: isStrongMatch(fileID: fileID),
                        model: binding,
                        isConfirmed: confirmedBinding(for: fileID)
                    )
                }
            }
        }
    }

    private func statusRow(path: String, systemImage: String, text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text((path as NSString).lastPathComponent)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private func fatalBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if !isLoadingLibraryCount && loadError == nil && libraryFileCount > 0 {
            if scannedFileIDs.isEmpty {
                selectionFooter
            } else {
                reviewFooter
            }
        }
    }

    private var selectionFooter: some View {
        HStack(spacing: 12) {
            Text("\(selectedFileIDs.count) selected")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select All Results") {
                selectedFileIDs.formUnion(searchResults.map(\.id))
            }
            .controlSize(.small)
            .disabled(searchResults.isEmpty)
            .help("Adds every currently-shown search result to the selection — never the whole library.")
            Button("Select None") {
                selectedFileIDs.removeAll()
            }
            .controlSize(.small)
            .disabled(selectedFileIDs.isEmpty)
            Button("Scan Selected (\(selectedFileIDs.count))") {
                Task { await startScan() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var reviewFooter: some View {
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
            } else {
                Text(reviewStatusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("New Scan") {
                resetToSelectionStage()
            }
            .controlSize(.small)
            .disabled(isApplying)
            if !rowModels.isEmpty {
                Button("Confirm All Strong Matches") {
                    confirmAllStrongMatches()
                }
                .controlSize(.small)
                Button("Select All") {
                    confirmedFileIDs = Set(rowModels.keys)
                }
                .controlSize(.small)
                Button("Select None") {
                    confirmedFileIDs.removeAll()
                }
                .controlSize(.small)
                Button("Apply") {
                    Task { await applyConfirmed() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(confirmedFileIDs.isEmpty || isApplying || seratoWatchdog.isSeratoRunning)
                .help(seratoWatchdog.isSeratoRunning
                    ? "Quit Serato before applying — matches write to Serato library files and would be clobbered on Serato's next save."
                    : "Apply every confirmed match in one undoable batch.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var reviewStatusText: String {
        var parts = ["\(confirmedFileIDs.count) of \(rowModels.count) confirmed"]
        if !appliedFileIDs.isEmpty {
            parts.append("\(appliedFileIDs.count) applied")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Bindings

    private func toggleSelection(_ fileID: Int64) {
        if selectedFileIDs.contains(fileID) {
            selectedFileIDs.remove(fileID)
        } else {
            selectedFileIDs.insert(fileID)
        }
    }

    private func rowModelBinding(for fileID: Int64) -> Binding<AutoTagRowModel>? {
        guard rowModels[fileID] != nil else { return nil }
        return Binding(
            get: { rowModels[fileID]! },
            set: { rowModels[fileID] = $0 }
        )
    }

    private func confirmedBinding(for fileID: Int64) -> Binding<Bool> {
        Binding(
            get: { confirmedFileIDs.contains(fileID) },
            set: { include in
                if include {
                    confirmedFileIDs.insert(fileID)
                } else {
                    confirmedFileIDs.remove(fileID)
                }
            }
        )
    }

    private func isStrongMatch(fileID: Int64) -> Bool {
        if case .strong = autoTaggerService.rows[fileID] {
            return true
        }
        return false
    }

    private func confirmAllStrongMatches() {
        for (fileID, _) in rowModels where isStrongMatch(fileID: fileID) {
            confirmedFileIDs.insert(fileID)
        }
    }

    // MARK: - Loading

    /// Cheap `SELECT COUNT(*)` used only to tell "library genuinely
    /// empty" apart from "nothing matches the current search" — never
    /// a full-table fetch.
    private func loadLibraryFileCount() async {
        isLoadingLibraryCount = true
        defer { isLoadingLibraryCount = false }
        loadError = nil
        do {
            libraryFileCount = try await services.database.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? 0
            }
        } catch {
            loadError = "\(error.localizedDescription)"
        }
    }

    /// Runs the debounced search behind the selection stage. Bounded by
    /// `AutoTagFileSearch.resultCap` — this never loads the whole
    /// library, on the main thread or otherwise.
    private func performSearch(query: String) async {
        isSearching = true
        defer { isSearching = false }
        searchError = nil
        do {
            let results = try await services.database.writer.read { db in
                try AutoTagFileSearch.search(query: query, in: db)
            }
            searchResults = results.matches
            searchTotalMatchCount = results.totalMatchCount
        } catch {
            searchError = "\(error.localizedDescription)"
        }
    }

    /// Loads (or refreshes) the "current" tag baseline — `filesByID`
    /// and `currentYearByFileID` — for exactly `fileIDs`, never the
    /// whole library. Called before a scan starts (so the review stage
    /// has current values to diff the proposed match against) and
    /// again after a successful apply (so a later re-scan of the same
    /// files diffs against what's actually in the DB now, not stale
    /// pre-apply values).
    private func loadCurrentMetadata(forFileIDs fileIDs: [Int64]) async {
        guard !fileIDs.isEmpty else { return }
        do {
            let loadedFiles = try await services.database.writer.read { db in
                try FileRecord.filter(keys: fileIDs).fetchAll(db)
            }
            let trackIDs = Set(loadedFiles.compactMap(\.trackId))
            let tracks = try await services.database.writer.read { db in
                try TrackRecord.filter(keys: trackIDs).fetchAll(db)
            }
            let yearByTrackID: [Int64: Int] = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
                guard let trackID = track.id, let year = track.year else { return nil }
                return (trackID, year)
            })

            for file in loadedFiles {
                guard let fileID = file.id else { continue }
                filesByID[fileID] = file
                currentYearByFileID[fileID] = file.trackId.flatMap { yearByTrackID[$0] }
            }
        } catch {
            loadError = "\(error.localizedDescription)"
        }
    }

    /// Builds an `AutoTagRowModel` for every newly-resolved candidate
    /// among `scannedFileIDs` — deliberately scoped to the current
    /// scan's selection, not to every key in `autoTaggerService.rows`
    /// (shared, long-lived service state that can carry entries from a
    /// scan this view instance never asked for). Skips fileIDs that
    /// already have a model, and ones already marked applied — preserves
    /// the user's field toggles / title choice / release pick across the
    /// service publishing updates for other, still-in-flight files.
    private func syncRowModels() {
        for fileID in scannedFileIDs {
            guard rowModels[fileID] == nil, !appliedFileIDs.contains(fileID) else { continue }
            guard let state = autoTaggerService.rows[fileID] else { continue }

            let candidate: MatchCandidate?
            switch state {
            case let .strong(value), let .weak(value):
                candidate = value
            case .pending, .noMatch, .failed:
                candidate = nil
            }
            guard let candidate, let file = filesByID[fileID] else { continue }

            rowModels[fileID] = AutoTagRowModel(
                candidate: candidate,
                currentArtist: file.artist ?? "",
                currentTitle: file.title ?? "",
                currentAlbum: file.album ?? "",
                currentYear: currentYearByFileID[fileID] ?? nil
            )
        }
    }

    // MARK: - Actions

    /// Runs the lookup pass over exactly `selectedFileIDs` — never over
    /// every loaded file. Selections can be accumulated across several
    /// searches (in no particular library order), so we sort ascending
    /// by file id for a stable, deterministic review order rather than
    /// the search-result order of whichever query last touched a row.
    private func startScan() async {
        let idsToScan = selectedFileIDs.sorted()
        guard !idsToScan.isEmpty else { return }

        scannedFileIDs = idsToScan
        confirmedFileIDs.removeAll()
        appliedFileIDs.removeAll()
        rowModels.removeAll()
        actionError = nil
        lastResult = nil
        await loadCurrentMetadata(forFileIDs: idsToScan)
        await autoTaggerService.run(fileIDs: idsToScan)
    }

    private func resetToSelectionStage() {
        scannedFileIDs.removeAll()
        selectedFileIDs.removeAll()
        confirmedFileIDs.removeAll()
        appliedFileIDs.removeAll()
        rowModels.removeAll()
        actionError = nil
        lastResult = nil
    }

    private func applyConfirmed() async {
        isApplying = true
        defer { isApplying = false }
        actionError = nil
        lastResult = nil

        let confirmedIDs = confirmedFileIDs
        let mutations: [TrackMutation] = confirmedIDs.compactMap { fileID in
            rowModels[fileID].map { .applyMusicBrainzMatch($0.payload()) }
        }
        guard !mutations.isEmpty else { return }

        let batchId = "auto-tag-\(UUID().uuidString)"
        do {
            _ = try await services.operationEngine.applyBatch(mutations, batchId: batchId)
            let appliedCount = mutations.count
            lastResult = "Applied \(appliedCount) match\(appliedCount == 1 ? "" : "es")"
            appliedFileIDs.formUnion(confirmedIDs)
            confirmedFileIDs.subtract(confirmedIDs)
            for fileID in confirmedIDs {
                rowModels.removeValue(forKey: fileID)
            }
            // Refresh the cached current-tag baseline (filesByID /
            // currentYearByFileID) for exactly the files this scan
            // covered, so a later "New Scan" over the same files —
            // including these just-applied ones, if re-selected —
            // diffs against what's actually in the DB now, not against
            // stale pre-apply values. Without this, `syncRowModels`
            // rebuilds a re-scanned row's `AutoTagRowModel` from outdated
            // current-artist/title/album/year, undermining the review
            // UI's whole current→proposed diff.
            await loadCurrentMetadata(forFileIDs: scannedFileIDs)
        } catch {
            actionError = "Apply failed: \(error.localizedDescription)"
        }
    }
}

private func placeholder(
    icon: String,
    color: Color,
    headline: String,
    detail: String
) -> some View {
    VStack(spacing: 8) {
        Image(systemName: icon)
            .font(.largeTitle)
            .foregroundStyle(color)
        Text(headline)
            .font(.headline)
        Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
