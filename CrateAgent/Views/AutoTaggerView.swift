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
/// selections, and "Select All" (the only path to a library-wide pass)
/// is gated behind a confirmation showing the track count and a rough
/// time estimate against the shared ≤1 req/sec AcoustID/MusicBrainz
/// rate limit.
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

    @State private var files: [FileRecord] = []
    @State private var filesByID: [Int64: FileRecord] = [:]
    @State private var currentYearByFileID: [Int64: Int?] = [:]

    /// The user's checkbox picks on the pre-scan selection list. Starts
    /// empty on every launch of this view — never defaults to "all".
    @State private var selectedFileIDs: Set<Int64> = []
    /// The exact file IDs the most recent scan was run against, in
    /// library order. Drives which rows `reviewList` renders — NOT
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

    @State private var isLoadingFiles: Bool = false
    @State private var isApplying: Bool = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var lastResult: String?
    @State private var showSelectAllConfirmation: Bool = false

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
        .task { await loadFiles() }
        .onChange(of: autoTaggerService.rows) { _, _ in syncRowModels() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoadingFiles {
            ProgressView("Loading library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            placeholder(icon: "exclamationmark.triangle", color: .orange, headline: "Couldn't load library", detail: loadError)
        } else if files.isEmpty {
            placeholder(
                icon: "tray",
                color: .secondary,
                headline: "No tracks indexed yet",
                detail: "Auto-Tag needs files in your library before it can look up matches."
            )
        } else if scannedFileIDs.isEmpty {
            selectionList
        } else {
            reviewList
        }
    }

    // MARK: - Selection stage

    private var selectionList: some View {
        List(files, id: \.id) { file in
            if let fileID = file.id {
                selectionRow(fileID: fileID, file: file)
            }
        }
        .listStyle(.inset)
    }

    private func selectionRow(fileID: Int64, file: FileRecord) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: selectionBinding(for: fileID)) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(for: file))
                    .font(.caption)
                    .lineLimit(1)
                Text((file.path as NSString).lastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { toggleSelection(fileID) }
    }

    private func displayTitle(for file: FileRecord) -> String {
        switch (file.artist, file.title) {
        case let (artist?, title?): return "\(artist) — \(title)"
        case let (artist?, nil): return artist
        case let (nil, title?): return title
        case (nil, nil): return (file.path as NSString).lastPathComponent
        }
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
        if !isLoadingFiles && loadError == nil && !files.isEmpty {
            if scannedFileIDs.isEmpty {
                selectionFooter
            } else {
                reviewFooter
            }
        }
    }

    private var selectionFooter: some View {
        HStack(spacing: 12) {
            Text("\(selectedFileIDs.count) of \(files.count) selected")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select All") {
                showSelectAllConfirmation = true
            }
            .controlSize(.small)
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
        .alert("Scan all \(files.count) tracks?", isPresented: $showSelectAllConfirmation) {
            Button("Select All \(files.count)") {
                selectedFileIDs = Set(files.compactMap(\.id))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Auto-Tag looks up every selected track against AcoustID and MusicBrainz through a shared rate limit of about 1 request per second (2 requests per track). \
            At \(files.count) track\(files.count == 1 ? "" : "s"), that's roughly \(Self.estimatedDuration(trackCount: files.count)). \
            You'll still review and confirm every match before anything is written — this only starts the lookup pass.
            """)
        }
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

    private func selectionBinding(for fileID: Int64) -> Binding<Bool> {
        Binding(
            get: { selectedFileIDs.contains(fileID) },
            set: { include in
                if include {
                    selectedFileIDs.insert(fileID)
                } else {
                    selectedFileIDs.remove(fileID)
                }
            }
        )
    }

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

    private func loadFiles() async {
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        loadError = nil
        do {
            let loadedFiles = try await services.database.writer.read { db in
                try FileRecord.fetchAll(db)
            }
            let trackIDs = Set(loadedFiles.compactMap(\.trackId))
            let tracks = try await services.database.writer.read { db in
                try TrackRecord.filter(keys: trackIDs).fetchAll(db)
            }
            let yearByTrackID: [Int64: Int] = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
                guard let trackID = track.id, let year = track.year else { return nil }
                return (trackID, year)
            })

            files = loadedFiles
            filesByID = Dictionary(uniqueKeysWithValues: loadedFiles.compactMap { file in
                file.id.map { ($0, file) }
            })
            currentYearByFileID = Dictionary(uniqueKeysWithValues: loadedFiles.compactMap { file -> (Int64, Int?)? in
                guard let fileID = file.id else { return nil }
                return (fileID, file.trackId.flatMap { yearByTrackID[$0] })
            })
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
    /// every loaded file. Preserves the library's display order so the
    /// review list reads top-to-bottom the same way the selection list did.
    private func startScan() async {
        let idsToScan = files.compactMap(\.id).filter { selectedFileIDs.contains($0) }
        guard !idsToScan.isEmpty else { return }

        scannedFileIDs = idsToScan
        confirmedFileIDs.removeAll()
        appliedFileIDs.removeAll()
        rowModels.removeAll()
        actionError = nil
        lastResult = nil
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
            // currentYearByFileID) so a later "New Scan" over the same
            // files — including these just-applied ones, if re-selected —
            // diffs against what's actually in the DB now, not against
            // stale pre-apply values. Without this, `syncRowModels`
            // rebuilds a re-scanned row's `AutoTagRowModel` from outdated
            // current-artist/title/album/year, undermining the review
            // UI's whole current→proposed diff.
            await loadFiles()
        } catch {
            actionError = "Apply failed: \(error.localizedDescription)"
        }
    }

    /// Rough wall-clock estimate for scanning `trackCount` tracks: 2
    /// sequential lookups per track (AcoustID, then MusicBrainz), both
    /// routed through one shared rate limiter capped at ≤1 request/second
    /// (MusicBrainz's own ceiling; `AppServices` shares it with AcoustID
    /// too, conservatively).
    private static func estimatedDuration(trackCount: Int) -> String {
        let totalSeconds = TimeInterval(trackCount * 2)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: totalSeconds) ?? "\(Int(totalSeconds))s"
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
