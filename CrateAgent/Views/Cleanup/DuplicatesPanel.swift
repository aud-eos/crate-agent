import GRDB
import SwiftUI

struct DuplicatesPanel: View {
    private typealias ScannedGroup = DuplicateFinder.DuplicateGroup<DuplicateFileRow>

    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices

    @State private var mode: DuplicateFinder.Mode = .byteLevel
    /// Every group the last scan found; `groups` shows those `labelFilter` includes.
    @State private var scannedGroups: [ScannedGroup] = []
    @State private var labelFilter: LabelFilter = .duplicates
    @State private var results = ListResultSelection<ScannedGroup>()
    private var groups: [ScannedGroup] {
        get { results.rows }
        nonmutating set {
            results.replace(newValue, context: "\(mode.rawValue):\(labelFilter.rawValue)", searchText: { group in
                group.files.map { ListSearch.text(artist: $0.artist, title: $0.title, album: $0.album, path: $0.path) }.joined(separator: "\n")
            })
            refreshConflictSelection()
        }
    }

    /// Per-group user-chosen keeper id. When a group's id is absent
    /// from this map, we use the analyzer's default
    /// (DuplicateKeeperPicker.chooseDefaultKeeper). Per-group radio
    /// taps write into this dictionary.
    @State private var keeperOverrides: [String: Int64] = [:]
    /// The last file clicked; Command-O opens it.
    @State private var focusedFileID: Int64?
    /// Per group needing listening, the files the user explicitly checked
    /// for Trash. Such groups never pre-select anything.
    @State private var listeningSelections: [String: Set<Int64>] = [:]
    @State private var isScanning: Bool = false
    @State private var isResolving: Bool = false
    @State private var actionError: String?
    @State private var lastResolution: String?
    @State private var pendingResolveGroup: ScannedGroup?
    @State private var pendingResolveAll: Bool = false
    /// Fingerprint coverage for the modeBar's "X of Y fingerprinted"
    /// label, counted in SQL by `rescan()` alongside `groups`.
    @State private var fingerprintCoverage: (done: Int, total: Int) = (done: 0, total: 0)
    /// While a batch resolve-all is in flight, how many files of the
    /// planned total have made it to Trash so far. Drives the
    /// progress text in the action bar. Resets to (0,0) when idle.
    @State private var batchProgress: BatchProgress = .idle
    /// Memoized result of `DuplicateKeeperPicker.chooseDefaultKeeper`
    /// per group, layered with `keeperOverrides`. Rebuilt only when
    /// `groups` or `keeperOverrides` change. Previously the row
    /// body called the picker on every redraw — and every keeper-
    /// radio toggle invalidated all visible rows, fanning out to
    /// hundreds of redundant picker invocations per click.
    @State private var keeperIdByGroup: [String: Int64] = [:]
    /// Bumped by every rescan so a slower, older scan can't overwrite
    /// the results of a newer one (live updates and Rescan overlap).
    @State private var scanGeneration = 0
    /// The running digest check for the shown mode, if any.
    @State private var checkTask: (mode: DuplicateFinder.Mode, id: UUID, task: Task<Void, Never>)?
    /// Coalesces bursts of fingerprint writes into one rescan.
    private static let liveRescanInterval: Duration = .milliseconds(1500)

    /// Which groups the list shows. Groups whose copies the user kept leave
    /// the default list.
    private enum LabelFilter: String, CaseIterable {
        case duplicates
        case labelsDisagree
        case kept

        func includes(_ group: ScannedGroup) -> Bool {
            switch self {
            case .duplicates: group.labelReview?.keptBoth != true
            case .labelsDisagree: group.labelsDisagree
            case .kept: group.labelReview?.keptBoth == true
            }
        }
    }

    private struct BatchProgress: Equatable {
        var trashed: Int
        var total: Int

        static let idle = BatchProgress(trashed: 0, total: 0)

        var isActive: Bool {
            total > 0
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("Duplicate tracks", subtitle: "Choose one keeper per group. Review the other copies before moving them to Trash.")
                .padding(density.pagePadding)
            SeratoRunningBanner(message: SeratoGateMessages.quitBefore("resolving duplicates"))
            PlayCountStalenessNote(service: services.playCountService)
            modeBar.disabled(isScanning || isResolving)
            Divider()
            ResultListHeader(results: $results, enabled: !isScanning && !isResolving)
            groupListSection.disabled(isScanning || isResolving)
            Divider()
            footer
            if !groups.isEmpty {
                Divider()
                batchActionBar
            }
        }
        .fileOpenShortcut(services.fileOpener, fileID: focusedFileID)
        .task { await rescan() }
        .task { await rescanAsLibraryChanges() }
        .onDisappear {
            checkTask?.task.cancel()
            checkTask = nil
        }
        .onChange(of: services.syncState) { _, _ in refreshConflictSelection() }
        // Cache invalidation: when the group set changes (after a
        // rescan, or after a resolve removed files) or the user
        // taps a different keeper radio, rebuild every group's
        // cached keeper id. The picker is non-trivial — running it
        // hundreds of times from a row body on every redraw was
        // the dominant cost of clicking through groups.
        .onChange(of: groups) { _, _ in rebuildKeeperCache() }
        .onChange(of: keeperOverrides) { _, _ in rebuildKeeperCache() }
        .alert(
            "Resolve duplicates?",
            isPresented: Binding(
                get: { pendingResolveGroup != nil },
                set: {
                    isPresented in if !isPresented {
                        pendingResolveGroup = nil
                    }
                }
            ),
            presenting: pendingResolveGroup
        ) { group in
            let count = trashCount(for: group)
            Button("Move \(count) file\(count == 1 ? "" : "s") to Trash", role: .destructive) {
                Task { await resolve(group: group) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            let count = trashCount(for: group)
            Text("This moves \(count) file\(count == 1 ? "" : "s") to your Trash, removes their entries from Serato's database, and strips them from any Serato crate that referenced them. The file in Trash stays restorable from Finder until you empty Trash. This action can't be undone from History.")
        }
        .alert(
            "Resolve selected duplicate groups?",
            isPresented: $pendingResolveAll
        ) {
            Button("Move \(totalNonKeeperCount) file\(totalNonKeeperCount == 1 ? "" : "s") to Trash", role: .destructive) {
                Task { await resolveAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves \(totalNonKeeperCount) file\(totalNonKeeperCount == 1 ? "" : "s") across \(results.selectedIDs.count) group\(groups.count == 1 ? "" : "s") to your Trash, removes their entries from Serato's database, and strips them from any Serato crate that referenced them. Files in Trash stay restorable from Finder until you empty Trash. This action can't be undone from History. The keeper for each group is the one currently selected — change keepers before resolving if needed.")
        }
    }

    /// Global action affordance for the panel. Sits between the
    /// mode picker and the grouped List so the user sees an
    /// unambiguous "Resolve selected" before any sticky per-group
    /// section header. Hidden when there are no groups (the
    /// list section renders its own empty state).
    private var batchActionBar: some View {
        ActionBar {
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                Text("\(groups.count) duplicate group\(groups.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.medium))
                if batchProgress.isActive {
                    Text("Resolving… \(batchProgress.trashed) of \(batchProgress.total) files trashed")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(totalNonKeeperCount) file\(totalNonKeeperCount == 1 ? "" : "s") will move to Trash")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } actions: {
            ResultListControls(results: $results, enabled: !isScanning && !isResolving)
            Button(role: .destructive) {
                pendingResolveAll = true
            } label: {
                Label("Move \(totalNonKeeperCount) duplicate files to Trash", systemImage: "trash")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(isScanning || isResolving || totalNonKeeperCount == 0)
            .seratoWriteGated(help: "Trash every non-keeper across selected groups in one undoable-as-an-audit-log batch.",
                              runningHelp: SeratoGateMessages.duplicateResolveBlocked)
        }
        .background(Color.secondary.opacity(0.06))
    }

    private var modeBar: some View {
        HStack(spacing: density.spacing) {
            Picker("Mode", selection: $mode) {
                ForEach(DuplicateFinder.Mode.allCases, id: \.rawValue) { entry in
                    Text(entry.displayName).tag(entry)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .onChange(of: mode) { _, _ in
                Task { await rescan() }
            }
            let disagreeing = scannedGroups.count(where: LabelFilter.labelsDisagree.includes)
            let kept = scannedGroups.count(where: LabelFilter.kept.includes)
            if disagreeing > 0 || kept > 0 || labelFilter != .duplicates {
                Picker("Show", selection: $labelFilter) {
                    Text("Duplicates").tag(LabelFilter.duplicates)
                    Text("Labels disagree (\(disagreeing))").tag(LabelFilter.labelsDisagree)
                    Text("Kept copies (\(kept))").tag(LabelFilter.kept)
                }
                .fixedSize()
                .help("Copies with identical audio whose titles name different versions, such as Clean and Dirty, need you to choose the keeper.")
                .onChange(of: labelFilter) { _, _ in showFilteredGroups() }
            }
            Spacer()
            if uncheckedFileCount > 0 {
                Text("Checking \(uncheckedFileCount) file\(uncheckedFileCount == 1 ? "" : "s")")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(mode == .byteLevel
                        ? "Files sharing a size and partial hash are read in full to confirm every byte matches before any can be moved to Trash."
                        : "Files that share a fingerprint are decoded to confirm their audio is the same before any can be moved to Trash.")
            }
            if mode == .perceptual {
                Text("\(fingerprintCoverage.done) of \(fingerprintCoverage.total) fingerprinted")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Perceptual matching needs Chromaprint fingerprints. Files still being fingerprinted in the background can't be matched yet — results improve as the fingerprint worker progresses.")
            }
        }
        .padding(.horizontal, density.pagePadding)
        .padding(.vertical, density.spacing)
    }

    @ViewBuilder
    private var groupListSection: some View {
        if isScanning, groups.isEmpty {
            ProgressView("Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let actionError, groups.isEmpty {
            ActionErrorMessage(message: actionError)
        } else if groups.isEmpty, labelFilter != .duplicates {
            hygienePlaceholder(
                icon: "checkmark.seal",
                color: .green,
                headline: labelFilter == .labelsDisagree ? "No labels disagree" : "No kept copies",
                detail: labelFilter == .labelsDisagree
                    ? "Every group of identical copies names the same versions."
                    : "Copies you keep from a group whose labels disagree appear here."
            )
        } else if groups.isEmpty {
            hygienePlaceholder(
                icon: "checkmark.seal",
                color: .green,
                headline: "No duplicates found",
                detail: modeEmptyDetail
            )
        } else {
            // ScrollView + LazyVStack rather than a sectioned List
            // because sectioned Lists on macOS get sticky section
            // headers — when the first section's header scrolls to
            // the top it reads as a global "apply all" affordance.
            // Per-group cards avoid the stickiness entirely and
            // make the per-group scope visually obvious.
            ScrollView {
                LazyVStack(spacing: density.spacing) {
                    ForEach(results.visibleRows) { group in
                        groupCard(group)
                    }
                }
                .padding(.horizontal, density.pagePadding)
                .padding(.vertical, density.spacing)
            }
        }
    }

    private func conflictReason(_ group: ScannedGroup) -> String? {
        group.files.compactMap { file in services.readiness.conflictPath(for: .file(file)) }.first.map(SeratoConflictMessages.blocked)
    }

    private func refreshConflictSelection() {
        results.setBlockedIDs(Set(groups.filter { group in !group.preselectsCleanup || conflictReason(group) != nil }.map(\.id)))
    }

    /// Files a resolve of `group` would move to Trash: every non-keeper,
    /// or in a group needing listening only the ones the user checked.
    private func trashCount(for group: ScannedGroup) -> Int {
        group.check == .needsListening ? explicitSelection(for: group).count : max(0, group.size - 1)
    }

    private func explicitSelection(for group: ScannedGroup) -> Set<Int64> {
        guard let keeper = group.files.first(where: { file in file.id == effectiveKeeperId(for: group) }) else { return [] }
        return (listeningSelections[group.id] ?? []).filter { identifier in
            guard identifier != keeper.id, let file = group.files.first(where: { file in file.id == identifier }) else { return false }
            let relation = group.relation(of: file, toKeeper: keeper)
            return relation == .identical || relation == .fingerprintMatch
        }
    }

    private var uncheckedFileCount: Int {
        scannedGroups.reduce(0) { total, group in total + group.uncheckedFileCount }
    }

    private func groupCard(_ group: ScannedGroup) -> some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            HStack(spacing: density.spacing) {
                if group.preselectsCleanup {
                    Toggle("Select group", isOn: Binding(get: { results.selectedIDs.contains(group.id) }, set: { results.setSelected($0, id: group.id) }))
                        .toggleStyle(.checkbox)
                        .disabled(conflictReason(group) != nil)
                }
                Text(groupHeader(for: group))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if group.offersCleanup {
                    Button {
                        pendingResolveGroup = group
                    } label: {
                        Label(group.check == .needsListening ? "Trash \(trashCount(for: group)) selected" : "Trash \(trashCount(for: group)) copies",
                              systemImage: "trash")
                            .labelStyle(.titleAndIcon)
                    }
                    .controlSize(density.controlSize)
                    .disabled(isResolving || conflictReason(group) != nil || trashCount(for: group) == 0 || effectiveKeeperId(for: group) == nil)
                    .seratoWriteGated(help: "Move non-keepers in this group to Trash and remove their Serato references in one batch.",
                                      runningHelp: SeratoGateMessages.duplicateResolveBlocked)
                }
            }
            if let reason = conflictReason(group) {
                Text(reason).font(.callout).foregroundStyle(.orange)
            }
            if group.check == .needsListening {
                Text("These files sound alike but their audio isn't identical. Listen before removing. Nothing here is selected for Trash until you check it.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if group.labelsDisagree {
                labelReviewSection(group)
            } else if group.labelReview?.keptBoth == true {
                Text("You kept every copy because their labels disagree. Undo it from History to review them again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if group.check == .checking {
                HStack(spacing: density.spacing) {
                    ProgressView().controlSize(.small)
                    Text(group.mode == .byteLevel
                        ? "Checking contents. These files can't be moved to Trash until every byte is confirmed the same."
                        : "Checking audio. These files can't be moved to Trash until their decoded audio is confirmed the same.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !group.files.isEmpty {
                VStack(spacing: density.detailSpacing) {
                    ForEach(group.files, id: \.id) { file in
                        duplicateRow(file: file, group: group)
                    }
                }
            }
            if !group.keptFiles.isEmpty {
                keptSection(group.keptFiles, mode: group.mode)
            }
        }
        .padding(.horizontal, density.pagePadding)
        .padding(.vertical, density.spacing)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private var modeEmptyDetail: String {
        switch mode {
        case .byteLevel:
            "No two files share the same content hash. (Byte-level duplicates would be the same file copied to two locations.)"
        case .perceptual:
            "No two fingerprinted files match each other. (Perceptual duplicates would be the same recording at different bitrates or in different formats.)"
        }
    }

    /// Copies with identical audio whose titles name different versions.
    /// Nothing is chosen for the user: they pick the keeper, may give it
    /// another copy's title, or keep every copy.
    private func labelReviewSection(_ group: ScannedGroup) -> some View {
        let keeper = group.files.first { file in file.id == effectiveKeeperId(for: group) }
        let otherTitles = keeper.map { keeper in
            group.files.filter { file in file.title != nil && file.title != keeper.title }
                .reduce(into: [DuplicateFileRow]()) { distinct, file in
                    if !distinct.contains(where: { existing in existing.title == file.title }) {
                        distinct.append(file)
                    }
                }
        } ?? []
        return VStack(alignment: .leading, spacing: density.detailSpacing) {
            Text(keeper == nil
                ? "Labels disagree, but the audio is identical, so at least one label is wrong. Choose the copy to keep, or keep every copy."
                : "Labels disagree, but the audio is identical, so at least one label is wrong. You can give the keeper another copy's title.")
                .font(.callout)
                .foregroundStyle(.orange)
            HStack(spacing: density.spacing) {
                if let keeper {
                    ForEach(otherTitles, id: \.id) { source in
                        Button("Use \u{201C}\(source.title ?? "")\u{201D} as the kept file's title") {
                            Task { await useTitle(of: source, forKeeper: keeper, in: group) }
                        }
                        .controlSize(density.controlSize)
                        .disabled(isResolving)
                        .seratoWriteGated(help: "Write this title to the kept file's tags and Serato's library. You can undo it from History.",
                                          runningHelp: SeratoGateMessages.cleanupApplyBlocked)
                    }
                }
                Button(group.size == 2 ? "Keep both" : "Keep all \(group.size) copies") {
                    Task { await keepAll(group) }
                }
                .controlSize(density.controlSize)
                .disabled(isResolving)
                .help("Keep every copy and stop offering this group for cleanup until one of them changes. You can undo it from History.")
            }
        }
    }

    private func useTitle(of source: DuplicateFileRow, forKeeper keeper: DuplicateFileRow, in group: ScannedGroup) async {
        await runLabelReview(success: "Gave the kept file the title \u{201C}\(source.title ?? "")\u{201D}") { reviewer in
            try await reviewer.useTitle(of: source, forKeeper: keeper, in: group)
        }
    }

    private func keepAll(_ group: ScannedGroup) async {
        await runLabelReview(success: "Kept all \(group.size) copies") { reviewer in
            try await reviewer.keepAll(group)
        }
    }

    private func runLabelReview(success: String, _ action: (DuplicateLabelReviewer) async throws -> Void) async {
        isResolving = true
        defer { isResolving = false }
        actionError = nil
        lastResolution = nil
        do {
            try await action(DuplicateLabelReviewer(operationEngine: services.operationEngine, database: services.database))
            lastResolution = success
        } catch {
            actionError = error.localizedDescription
        }
        await rescan(showingProgress: false)
    }

    private func groupHeader(for group: ScannedGroup) -> String {
        let match = group.mode == .byteLevel
            ? "byte-level, \(group.files.first.map { file in Self.byteCountFormatter.string(fromByteCount: file.fileSize) } ?? "") each"
            : "perceptual match"
        switch group.check {
        case .checking:
            return "\(group.size) files · \(match) · checking \(group.mode == .byteLevel ? "contents" : "audio")"
        case .confirmed:
            let labels = group.labelReview == nil ? "" : group.labelsDisagree ? " · labels disagree" : " · kept"
            return "\(group.size) copies · \(match) · identical \(group.mode == .byteLevel ? "contents" : "audio")\(labels)"
        case .needsListening:
            return "\(group.size) files · \(match) · listen before removing"
        case .differs:
            return "\(group.keptFiles.count) files · \(match) · \(group.mode == .byteLevel ? "contents" : "audio") differ"
        }
    }

    private func keptSection(_ kept: [DuplicateFinder.KeptFile<DuplicateFileRow>], mode: DuplicateFinder.Mode) -> some View {
        let differing = kept.filter { entry in entry.reason == .differs }.count
        let shared = mode == .byteLevel ? "a size and partial hash" : "a fingerprint"
        let content = mode == .byteLevel ? "contents differ" : "audio differs"
        let unreadable = kept.count - differing
        return VStack(alignment: .leading, spacing: density.detailSpacing) {
            if differing > 0 {
                Text("\(differing) file\(differing == 1 ? "" : "s") share\(differing == 1 ? "s" : "") \(shared) but \(differing == 1 ? "its" : "their") \(content), so \(differing == 1 ? "it's" : "they're") kept")
                    .font(.callout.weight(.medium))
            }
            if unreadable > 0 {
                Text("\(unreadable) file\(unreadable == 1 ? "" : "s") couldn't be checked, so \(unreadable == 1 ? "it's" : "they're") kept")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
            }
            ForEach(kept, id: \.file.id) { entry in
                HStack(alignment: .top, spacing: density.spacing) {
                    if let identifier = entry.file.id {
                        TrackPlayButton(player: services.trackPlayer, track: PlayerTrack(fileID: identifier, path: entry.file.path, title: entry.file.title, artist: entry.file.artist))
                    }
                    VStack(alignment: .leading, spacing: density.detailSpacing) {
                        TrackHeading(artist: entry.file.artist, title: entry.file.title, filename: (entry.file.path as NSString).lastPathComponent)
                        Text(entry.file.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.file.path)
                        Text(keptReason(entry.reason, mode: mode))
                            .font(.callout)
                            .foregroundStyle(entry.reason == .differs ? Color.secondary : Color.orange)
                    }
                    Spacer()
                }
            }
        }
    }

    private func keptReason(_ reason: DuplicateFinder.KeptReason, mode: DuplicateFinder.Mode) -> String {
        switch reason {
        case .differs: mode == .byteLevel ? "Kept: its contents match no other file here." : "Kept: its decoded audio matches no other file here."
        case let .unreadable(message): "Kept: \(message)"
        }
    }

    @ViewBuilder
    private func duplicateRow(
        file: DuplicateFileRow,
        group: ScannedGroup
    ) -> some View {
        let keeperId = effectiveKeeperId(for: group)
        let isKeeper = file.id == keeperId
        HStack(alignment: .top, spacing: density.spacing) {
            Button {
                if let identifier = file.id {
                    keeperOverrides[group.id] = identifier
                }
            } label: {
                Image(systemName: isKeeper ? "largecircle.fill.circle" : "circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isKeeper ? Color.accentColor : Color.secondary)
            .accessibilityLabel("Keep \((file.path as NSString).lastPathComponent)")
            .accessibilityValue(isKeeper ? "Selected keeper" : "Not selected")
            .help("Set as the keeper for this group.")
            if let identifier = file.id {
                TrackPlayButton(player: services.trackPlayer, track: PlayerTrack(fileID: identifier, path: file.path, title: file.title, artist: file.artist))
            }
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                TrackHeading(artist: file.artist, title: file.title, filename: (file.path as NSString).lastPathComponent)
                Text(file.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(density == .comfortable ? 2 : 1)
                    .truncationMode(.middle)
                    .help(file.path)
                if group.labelReview != nil {
                    Text("Labels: \(VersionLabel.describe(VersionLabel.labels(in: file.title ?? "")))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if isKeeper {
                    StatusBadge(title: "Keeper", systemImage: "checkmark.circle", tint: .accentColor)
                } else if group.check == .needsListening, let identifier = file.id {
                    listeningChoice(file: file, fileID: identifier, group: group)
                }
                HStack(spacing: density.spacing) {
                    Text(Self.byteCountFormatter.string(fromByteCount: file.fileSize))
                        .foregroundStyle(.secondary)
                    Text((file.path as NSString).pathExtension.uppercased())
                        .foregroundStyle(.secondary)
                    if let bitrate = file.bitrateKbps {
                        Text("\(bitrate) kbps")
                            .foregroundStyle(.secondary)
                    }
                    if file.seratoPlayCount > 0 {
                        Text(SeratoPlayCountMessages.plays(file.seratoPlayCount))
                            .foregroundStyle(.secondary)
                            .help(SeratoPlayCountMessages.explanation)
                    }
                    if group.mode == .perceptual {
                        statusBadge(file.fingerprintStatus)
                    }
                }
                .font(.callout.monospacedDigit())
            }
            Spacer()
            Button {
                if let identifier = file.id {
                    Task { await services.fileOpener.reveal(fileID: identifier) }
                }
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Show this file in Finder so you can review or delete it manually.")
        }
        .padding(.vertical, density.rowPadding)
        .background(file.id == focusedFileID ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { focusedFileID = file.id })
        .contextMenu {
            if let identifier = file.id {
                FileOpenMenuItems(opener: services.fileOpener, fileID: identifier, path: file.path)
            }
        }
    }

    @ViewBuilder
    private func listeningChoice(file: DuplicateFileRow, fileID: Int64, group: ScannedGroup) -> some View {
        let keeper = group.files.first { candidate in candidate.id == effectiveKeeperId(for: group) }
        let relation = keeper.flatMap { keeper in group.relation(of: file, toKeeper: keeper) } ?? .different
        if relation == .different {
            Text("Audio differs from the keeper, so it's kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let note = listeningNote(relation: relation, fileID: fileID, keeperID: keeper?.id, group: group)
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(relation == .identical ? Color.secondary : Color.orange)
                Toggle("Move to Trash", isOn: Binding(
                    get: { listeningSelections[group.id]?.contains(fileID) ?? false },
                    set: { isOn in
                        var selection = listeningSelections[group.id] ?? []
                        if isOn {
                            selection.insert(fileID)
                        } else {
                            selection.remove(fileID)
                        }
                        listeningSelections[group.id] = selection
                    }
                ))
                .toggleStyle(.checkbox)
                .help(note)
            }
        }
    }

    private func listeningNote(relation: DuplicateEvidence.Relation, fileID: Int64, keeperID: Int64?, group: ScannedGroup) -> String {
        if relation == .identical {
            return "Identical audio to the keeper."
        }
        let sameFormat = keeperID.flatMap { identifier in group.evidence[identifier]?.decodedFormat } == group.evidence[fileID]?.decodedFormat
        return sameFormat
            ? "Different encoding: audio isn't identical. Listen before removing."
            : "Different formats: audio can't be compared exactly. Listen before removing."
    }

    @ViewBuilder
    private func statusBadge(_ status: FingerprintStatus) -> some View {
        switch status {
        case .done:
            EmptyView()
        case .pending:
            Text("pending fingerprint")
                .foregroundStyle(.orange)
        case .failed:
            Text("fingerprint failed")
                .foregroundStyle(.red)
        }
    }

    private var footer: some View {
        ActionBar {
            if let actionError {
                ActionErrorMessage(message: actionError)
            } else if let lastResolution {
                Label(lastResolution, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Text("\(groups.count) duplicate group\(groups.count == 1 ? "" : "s") · \(totalDuplicateFiles) file\(totalDuplicateFiles == 1 ? "" : "s")")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button {
                Task { await rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning || isResolving)
        }
    }

    private var totalDuplicateFiles: Int {
        groups.reduce(0) { total, group in total + group.size }
    }

    /// Files that would be trashed if the user resolved every group
    /// with the current keeper selections. (One keeper survives per
    /// group; everything else goes to Trash.) Counts only groups
    /// that have a determinable keeper — groups with no keeper are
    /// skipped here and also skipped at apply time, so the count and
    /// the actual outcome stay aligned.
    private var totalNonKeeperCount: Int {
        results.selectedRows.reduce(0) { accumulator, group in
            guard group.preselectsCleanup, effectiveKeeperId(for: group) != nil else { return accumulator }
            return accumulator + (group.size - 1)
        }
    }

    /// Rescans while the panel is visible whenever fingerprints land or
    /// files change, at most once per `liveRescanInterval`. Resolving
    /// rescans on completion, so changes during a resolve are covered.
    private func rescanAsLibraryChanges() async {
        let changes = AsyncStream<Error?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = DuplicateScanObservation.start(in: services.database, onChange: {
            changes.continuation.yield(nil)
        }, onError: { error in
            changes.continuation.yield(error)
            changes.continuation.finish()
        })
        defer { observation.cancel() }
        for await failure in changes.stream {
            if let failure {
                actionError = "Live duplicate updates stopped: \(failure.localizedDescription). Use Rescan to refresh."
                return
            }
            do {
                try await Task.sleep(for: Self.liveRescanInterval)
            } catch {
                return
            }
            if !isResolving {
                await rescan(showingProgress: false)
            }
        }
    }

    /// `showingProgress` is false for live updates, which must neither
    /// flash the scanning state nor clear a resolve error on screen.
    private func rescan(showingProgress: Bool = true) async {
        scanGeneration += 1
        let generation = scanGeneration
        if showingProgress {
            isScanning = true
            actionError = nil
        }
        defer {
            if showingProgress {
                isScanning = false
            }
        }
        let mode = mode
        do {
            let scan = try await services.database.writer.read { database in
                try (groups: DuplicateFinder.findDuplicates(in: database, mode: mode), coverage: DuplicateFinder.fingerprintCoverage(in: database))
            }
            guard generation == scanGeneration else { return }
            scannedGroups = scan.groups
            showFilteredGroups()
            fingerprintCoverage = scan.coverage
            // Drop overrides for groups that no longer exist after
            // the rescan — preserves the user's per-group picks for
            // surviving groups while pruning stale ones.
            let currentIds = Set(scannedGroups.map(\.id))
            keeperOverrides = keeperOverrides.filter { entry in currentIds.contains(entry.key) }
            listeningSelections = listeningSelections.filter { entry in currentIds.contains(entry.key) }
            if showingProgress || scannedGroups.contains(where: { group in group.check == .checking }) {
                startCheck(mode: mode)
            }
        } catch {
            actionError = "Couldn't scan library: \(error.localizedDescription)"
        }
    }

    private func showFilteredGroups() {
        let filtered = scannedGroups.filter(labelFilter.includes)
        if filtered != groups {
            groups = filtered
        }
    }

    /// Checks the shown mode's pending cluster members in the background,
    /// joining a pass already running; each saved batch reaches the panel
    /// through the live rescan. An explicit rescan with no pass running starts
    /// a fresh one, which revalidates cached digests and retries transient
    /// failures.
    private func startCheck(mode: DuplicateFinder.Mode) {
        if let checkTask, checkTask.mode == mode {
            return
        }
        checkTask?.task.cancel()
        let verifier = services.duplicateEvidenceVerifier
        let checkID = UUID()
        let task = Task(priority: .utility) {
            let failure: Error?
            do {
                try await verifier.verifyPendingFiles(mode: mode)
                failure = nil
            } catch {
                failure = error
            }
            if checkTask?.id == checkID {
                checkTask = nil
            }
            if let failure, !(failure is CancellationError) {
                actionError = "Duplicate check stopped: \(failure.localizedDescription). Use Rescan to try again."
            }
        }
        checkTask = (mode, checkID, task)
    }

    /// The id of the file we'd keep for this group — user's override
    /// if set, otherwise the keeper picker's default. Returns nil
    /// only for impossibly empty groups, which DuplicateFinder
    /// already excludes. Reads from the precomputed cache; callers
    /// must have called `rebuildKeeperCache()` after any mutation
    /// to `groups` or `keeperOverrides`.
    private func effectiveKeeperId(for group: ScannedGroup) -> Int64? {
        keeperIdByGroup[group.id]
    }

    /// Refresh the keeper cache for every current group. Runs the
    /// picker once per group, on demand — not in `body`.
    private func rebuildKeeperCache() {
        var refreshed: [String: Int64] = [:]
        refreshed.reserveCapacity(groups.count)
        let musicFolder = services.watchedMusicFolder
        for group in groups {
            if let override = keeperOverrides[group.id], group.files.contains(where: { $0.id == override }) {
                refreshed[group.id] = override
                continue
            }
            // At least one disagreeing label is wrong, so only the user can
            // say which copy to keep.
            if group.labelsDisagree {
                continue
            }
            if let keeperId = DuplicateKeeperPicker.chooseDefaultKeeper(
                for: group,
                musicFolder: musicFolder
            ) {
                refreshed[group.id] = keeperId
            }
        }
        keeperIdByGroup = refreshed
    }

    private func resolve(group: ScannedGroup) async {
        guard let keeperId = effectiveKeeperId(for: group) else {
            actionError = "No keeper could be determined for this group."
            return
        }
        isResolving = true
        services.trackPlayer.stop()
        defer { isResolving = false }
        actionError = nil
        lastResolution = nil

        let resolver = DuplicateResolver(operationEngine: services.operationEngine, database: services.database, activityLog: services.activityLog)
        do {
            let outcome = try await resolver.resolve(group: group, keeperId: keeperId, explicitlySelectedFileIDs: explicitSelection(for: group))
            if outcome.failureCount == 0 {
                lastResolution = "Moved \(outcome.trashedCount) duplicate\(outcome.trashedCount == 1 ? "" : "s") to Trash; \(outcome.pendingCount) pending until Serato closes"
            } else {
                actionError = "Moved \(outcome.trashedCount); \(outcome.pendingCount) pending; \(outcome.failureCount) stopped: \(outcome.errors.first ?? "see activity log")"
            }
            await rescan()
            await reportCleanupFailure()
        } catch {
            actionError = "Resolve failed: \(error.localizedDescription)"
        }
    }

    /// Resolve every group with its current keeper selection. Shares
    /// one `batch_id` across selected groups so History shows a single
    /// audit entry. If a group fails mid-stream, the failure stops
    /// the loop and we report partial progress — groups already
    /// resolved stay resolved (Finder's Trash is the recovery path
    /// per group), and the user can rescan to see what's left.
    private func resolveAll() async {
        let resolvable: [(group: ScannedGroup, keeperId: Int64)] =
            results.selectedRows.compactMap { group in
                guard group.preselectsCleanup, let keeperId = effectiveKeeperId(for: group) else { return nil }
                return (group, keeperId)
            }
        guard !resolvable.isEmpty else {
            actionError = "No groups have a determinable keeper to resolve."
            return
        }

        isResolving = true
        services.trackPlayer.stop()
        defer {
            isResolving = false
            batchProgress = .idle
        }
        actionError = nil
        lastResolution = nil

        let plannedTotal = resolvable.reduce(0) { total, entry in total + (entry.group.size - 1) }
        batchProgress = BatchProgress(trashed: 0, total: plannedTotal)

        let sharedBatchId = "duplicate-resolve-all-\(UUID().uuidString)"
        let resolver = DuplicateResolver(operationEngine: services.operationEngine, database: services.database, activityLog: services.activityLog)

        var trashedSoFar = 0
        var pendingSoFar = 0
        var skippedSoFar = 0
        var groupsResolved = 0
        for entry in resolvable {
            do {
                let outcome = try await resolver.resolve(
                    group: entry.group,
                    keeperId: entry.keeperId,
                    batchId: sharedBatchId
                )
                trashedSoFar += outcome.trashedCount
                pendingSoFar += outcome.pendingCount
                skippedSoFar += outcome.failureCount
                groupsResolved += 1
                // Throttle: every progress mutation fires a full
                // redraw of the visible group cards, which is the
                // expensive bit (each card runs an Equatable diff
                // against its data). One update per 5 groups gives
                // the user a meaningful "still moving" signal
                // without paying N redraws for N resolutions.
                if groupsResolved.isMultiple(of: 5) || groupsResolved == resolvable.count {
                    batchProgress = BatchProgress(trashed: trashedSoFar, total: plannedTotal)
                }
            } catch {
                // Group-level failure (rare — `resolve` now
                // tolerates per-file errors internally; this
                // catches structural problems like
                // `keeperNotInGroup`).
                actionError = "Stopped after \(groupsResolved) group\(groupsResolved == 1 ? "" : "s"): \(error.localizedDescription)"
                break
            }
        }

        if actionError == nil {
            if skippedSoFar == 0 {
                lastResolution = "Moved \(trashedSoFar) file\(trashedSoFar == 1 ? "" : "s") across \(groupsResolved) group\(groupsResolved == 1 ? "" : "s") to Trash; \(pendingSoFar) pending until Serato closes"
            } else {
                lastResolution = "Moved \(trashedSoFar) file\(trashedSoFar == 1 ? "" : "s"); \(pendingSoFar) pending; \(skippedSoFar) stopped (see activity log)"
            }
        }
        await rescan()
        await reportCleanupFailure()
    }

    private func reportCleanupFailure() async {
        do {
            if let message = try await services.operationEngine.failedDuplicateCleanupMessage {
                services.syncSession.reportFailure(message)
            }
        } catch {
            services.syncSession.reportFailure(error.localizedDescription)
        }
    }
}

/// Keeper suggestions rank by plays, so a failed History read is shown
/// where those suggestions are made, not only in Workers.
private struct PlayCountStalenessNote: View {
    @ObservedObject var service: SeratoPlayCountService

    var body: some View {
        if case let .failed(reason) = service.status {
            Label(SeratoPlayCountMessages.stale(reason), systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }
}
