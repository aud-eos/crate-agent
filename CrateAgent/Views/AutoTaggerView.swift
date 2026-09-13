import GRDB
import SwiftUI

/// SP-2's Auto-Tag review surface. Scans the library against
/// AcoustID/MusicBrainz via `AutoTaggerService`, then lets the user
/// review and selectively confirm each resolved match before applying
/// every confirmed row in one undoable batch through `OperationEngine`.
/// Models the scan → preview → apply skeleton from `LibraryHygieneView`.
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
    @State private var rowModels: [Int64: AutoTagRowModel] = [:]
    @State private var confirmedFileIDs: Set<Int64> = []
    @State private var isLoadingFiles: Bool = false
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
        } else if autoTaggerService.rows.isEmpty {
            scanPrompt
        } else {
            reviewList
        }
    }

    private var scanPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("\(files.count) track\(files.count == 1 ? "" : "s") ready to scan")
                .font(.headline)
            Text("Looks up each file's audio fingerprint against AcoustID and MusicBrainz to propose corrected tags. You review and confirm every field before anything is written.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Scan Library") {
                Task { await startScan() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewList: some View {
        List(files, id: \.id) { file in
            if let fileID = file.id {
                rowContainer(fileID: fileID, path: file.path)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func rowContainer(fileID: Int64, path: String) -> some View {
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

    private var footer: some View {
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
            } else if !rowModels.isEmpty {
                Text("\(confirmedFileIDs.count) of \(rowModels.count) confirmed")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
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

    // MARK: - Bindings

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

    /// Builds an `AutoTagRowModel` for every newly-resolved candidate in
    /// `autoTaggerService.rows`, without touching rows that already have
    /// one — preserves the user's field toggles / title choice / release
    /// pick across the service publishing updates for other, still-in-
    /// flight files.
    private func syncRowModels() {
        for (fileID, state) in autoTaggerService.rows {
            guard rowModels[fileID] == nil else { continue }

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

    private func startScan() async {
        confirmedFileIDs.removeAll()
        rowModels.removeAll()
        let fileIDs = files.compactMap(\.id)
        await autoTaggerService.run(fileIDs: fileIDs)
    }

    private func applyConfirmed() async {
        isApplying = true
        defer { isApplying = false }
        actionError = nil
        lastResult = nil

        let mutations: [TrackMutation] = confirmedFileIDs.compactMap { fileID in
            rowModels[fileID].map { .applyMusicBrainzMatch($0.payload()) }
        }
        guard !mutations.isEmpty else { return }

        let batchId = "auto-tag-\(UUID().uuidString)"
        do {
            _ = try await services.operationEngine.applyBatch(mutations, batchId: batchId)
            let appliedCount = mutations.count
            lastResult = "Applied \(appliedCount) match\(appliedCount == 1 ? "" : "es")"
            for fileID in confirmedFileIDs {
                rowModels.removeValue(forKey: fileID)
            }
            confirmedFileIDs.removeAll()
            await loadFiles()
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
