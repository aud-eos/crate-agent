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
    /// Set when `applyBatch` committed the batch to the DB but one or
    /// more external Serato/file-tag writes failed afterward (issue
    /// #836). The batch IS applied; this holds its id so the user can
    /// Re-sync to finish the external writes — a plain re-Apply would
    /// re-journal against the already-mutated rows and corrupt undo.
    @State private var pendingResyncBatchId: String?

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
        // Leaving the Auto-Tag panel entirely (not just "New Scan", which
        // already cancels via resetToSelectionStage) must also stop an
        // in-flight pass — otherwise it keeps issuing rate-limited
        // AcoustID/MusicBrainz requests, invisibly, for as long as it takes
        // to finish the selection it was given.
        .onDisappear { autoTaggerService.cancel() }
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
            case let .stopped(reason):
                statusRow(path: path, systemImage: "stop.circle", text: "Stopped — \(reason)", tint: .secondary)
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
            if pendingResyncBatchId != nil {
                Button("Re-sync") {
                    Task { await resyncPartialApply() }
                }
                .controlSize(.small)
                .disabled(isApplying)
                .help("Finish applying the last batch — replays the Serato/file writes that didn't land, without re-applying (which would corrupt undo).")
            }
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
    ///
    /// `.task(id: searchQuery)` cancels the previous task when the query
    /// changes, but cancellation is cooperative: a slower, older query's
    /// `database.writer.read` can still complete after a newer query's
    /// read already published its results. Guarding only on
    /// `Task.isCancelled` right after the `await` is not enough — by the
    /// time an old task resumes post-await it may already have raced past
    /// its own cancellation check. So the guard also compares the query
    /// this call ran for against the current `searchQuery`: if a newer
    /// query has since taken over, this call's result is stale and must
    /// be dropped rather than published, however it got here.
    private func performSearch(query: String) async {
        isSearching = true
        defer { isSearching = false }
        searchError = nil

        let outcome: Result<AutoTagFileSearch.Results, Error>
        do {
            let results = try await services.database.writer.read { db in
                try AutoTagFileSearch.search(query: query, in: db)
            }
            outcome = .success(results)
        } catch {
            outcome = .failure(error)
        }

        guard Self.shouldPublishSearchResult(
            queryTaskRanFor: query,
            currentQuery: searchQuery,
            isCancelled: Task.isCancelled
        ) else { return }

        switch outcome {
        case let .success(results):
            searchResults = results.matches
            searchTotalMatchCount = results.totalMatchCount
        case let .failure(error):
            searchError = "\(error.localizedDescription)"
        }
    }

    /// Pure "should this completed search's results still be published"
    /// guard, extracted so it's unit-testable without the SwiftUI/`Task`
    /// machinery around it. Both the task's own cancellation and a
    /// query-mismatch (a newer search has since taken over the search
    /// box) must block publishing — either alone is insufficient, since
    /// cancellation is cooperative and can lose the race.
    static func shouldPublishSearchResult(queryTaskRanFor: String, currentQuery: String, isCancelled: Bool) -> Bool {
        guard !isCancelled else { return false }
        let trimmedCurrentQuery = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return queryTaskRanFor == trimmedCurrentQuery
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
            case .pending, .noMatch, .failed, .stopped:
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
        pendingResyncBatchId = nil
        await loadCurrentMetadata(forFileIDs: idsToScan)
        await autoTaggerService.run(fileIDs: idsToScan)
    }

    private func resetToSelectionStage() {
        autoTaggerService.cancel()
        scannedFileIDs.removeAll()
        selectedFileIDs.removeAll()
        confirmedFileIDs.removeAll()
        appliedFileIDs.removeAll()
        rowModels.removeAll()
        searchQuery = ""
        actionError = nil
        lastResult = nil
        pendingResyncBatchId = nil
    }

    private func applyConfirmed() async {
        isApplying = true
        defer { isApplying = false }
        actionError = nil
        lastResult = nil
        pendingResyncBatchId = nil

        let confirmedIDs = confirmedFileIDs
        let payloadByFileID: [Int64: ApplyMusicBrainzMatchPayload] = confirmedIDs.reduce(into: [:]) { accumulator, fileID in
            if let model = rowModels[fileID] { accumulator[fileID] = model.payload() }
        }
        guard !payloadByFileID.isEmpty else { return }

        // D-A: revalidate every confirmed candidate against the file on disk
        // NOW. A review pass can stay open a long time; a file edited or
        // replaced since its candidate was built must NOT get the stale
        // recording/identity applied. Stale rows are excluded from the apply
        // and surfaced (no silent drop) so the user can re-scan them.
        let staleIDs = await autoTaggerService.staleFileIDs(for: Array(payloadByFileID.values))
        let freshPayloadByFileID = payloadByFileID.filter { !staleIDs.contains($0.key) }
        let appliedIDs = Set(freshPayloadByFileID.keys)
        let mutations: [TrackMutation] = freshPayloadByFileID.values.map { .applyMusicBrainzMatch($0) }

        let staleNotice = staleIDs.isEmpty
            ? nil
            : "\(staleIDs.count) file\(staleIDs.count == 1 ? "" : "s") changed on disk since review and \(staleIDs.count == 1 ? "was" : "were") skipped — re-scan to review the current audio."

        guard !mutations.isEmpty else {
            actionError = staleNotice
            return
        }

        let batchId = "auto-tag-\(UUID().uuidString)"
        do {
            _ = try await services.operationEngine.applyBatch(mutations, batchId: batchId)
            let appliedCount = mutations.count
            markConfirmedApplied(appliedIDs)
            lastResult = "Applied \(appliedCount) match\(appliedCount == 1 ? "" : "es")"
            actionError = staleNotice
            await refreshCurrentMetadataAfterApply()
        } catch let error as OperationEngineError {
            // A committed batch whose external writes partially failed is
            // still APPLIED (issue #836). Move the rows to applied and
            // offer a Re-sync that replays the missing external writes
            // idempotently from the journal — never a plain re-Apply,
            // which would re-journal against the mutated rows and corrupt
            // undo (invariant #2).
            if case let .externalSyncIncomplete(failedBatchId, _) = error {
                markConfirmedApplied(appliedIDs)
                await refreshCurrentMetadataAfterApply()
                pendingResyncBatchId = failedBatchId
                let base = "Applied to the library, but some Serato/file writes didn't land. Use Re-sync to finish."
                actionError = staleNotice.map { "\(base) \($0)" } ?? base
            } else {
                actionError = "Apply failed: \(error.localizedDescription)"
            }
        } catch {
            actionError = "Apply failed: \(error.localizedDescription)"
        }
    }

    /// Move a set of confirmed rows into the applied state: mark them
    /// applied, clear them from the confirmed set, and drop their review
    /// models. Shared by the full-success and partial-failure paths —
    /// both mean the rows are committed in the DB.
    private func markConfirmedApplied(_ confirmedIDs: Set<Int64>) {
        appliedFileIDs.formUnion(confirmedIDs)
        confirmedFileIDs.subtract(confirmedIDs)
        for fileID in confirmedIDs {
            rowModels.removeValue(forKey: fileID)
        }
    }

    /// Refresh the cached current-tag baseline (filesByID /
    /// currentYearByFileID) for exactly the files this scan covered, so
    /// a later "New Scan" over the same files — including these
    /// just-applied ones, if re-selected — diffs against what's actually
    /// in the DB now, not against stale pre-apply values. Without this,
    /// `syncRowModels` rebuilds a re-scanned row's `AutoTagRowModel` from
    /// outdated current-artist/title/album/year, undermining the review
    /// UI's whole current→proposed diff.
    private func refreshCurrentMetadataAfterApply() async {
        await loadCurrentMetadata(forFileIDs: scannedFileIDs)
    }

    /// Finish a partially-applied batch by replaying its still-missing
    /// external writes from the journal (idempotent, no re-journaling).
    private func resyncPartialApply() async {
        guard let batchId = pendingResyncBatchId else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            let outcome = try await services.operationEngine.resyncSeratoForBatch(batchId)
            if outcome.appliedCount > 0 && outcome.queuedCount == 0 {
                pendingResyncBatchId = nil
                actionError = nil
                lastResult = outcome.summaryMessage
            } else {
                // Nothing landed on disk (e.g. Serato started up), or the
                // writes queued — keep the recovery affordance available.
                actionError = outcome.summaryMessage
            }
        } catch {
            actionError = "Re-sync failed: \(error.localizedDescription)"
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
