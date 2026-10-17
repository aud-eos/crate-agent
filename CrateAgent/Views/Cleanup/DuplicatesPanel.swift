import GRDB
import SwiftUI

struct DuplicatesPanel: View {
    private typealias ScannedGroup = DuplicateFinder.DuplicateGroup<DuplicateFileRow>

    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    @State private var mode: DuplicateFinder.Mode = .byteLevel
    @State private var results = ListResultSelection<ScannedGroup>()
    private var groups: [ScannedGroup] {
        get { results.rows }
        nonmutating set {
            results.replace(newValue, context: mode.rawValue, searchText: { group in
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
            if seratoWatchdog.isSeratoRunning {
                SeratoRunningBanner(message: "Serato is running — quit it before resolving duplicates.")
                Divider()
            }
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
        .task { await rescan() }
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
            Button("Move \(group.size - 1) file\(group.size - 1 == 1 ? "" : "s") to Trash", role: .destructive) {
                Task { await resolve(group: group) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text("This moves \(group.size - 1) file\(group.size - 1 == 1 ? "" : "s") to your Trash, removes their entries from Serato's database, and strips them from any Serato crate that referenced them. The file in Trash stays restorable from Finder until you empty Trash. This action can't be undone from History.")
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
            .disabled(isScanning || isResolving || seratoWatchdog.isSeratoRunning || totalNonKeeperCount == 0)
            .help(seratoWatchdog.isSeratoRunning
                ? "Quit Serato before resolving — Serato can clobber the database V2 changes from its in-memory cache."
                : "Trash every non-keeper across selected groups in one undoable-as-an-audit-log batch.")
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
            Spacer()
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
        results.setBlockedIDs(Set(groups.filter { group in conflictReason(group) != nil }.map(\.id)))
    }

    private func groupCard(_ group: ScannedGroup) -> some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            HStack(spacing: density.spacing) {
                Toggle("Select group", isOn: Binding(get: { results.selectedIDs.contains(group.id) }, set: { results.setSelected($0, id: group.id) }))
                    .toggleStyle(.checkbox)
                    .disabled(conflictReason(group) != nil)
                Text("\(group.size) copies · \(modeHeader(for: group))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    pendingResolveGroup = group
                } label: {
                    Label("Trash \(group.size - 1) copies", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(density.controlSize)
                .disabled(isResolving || seratoWatchdog.isSeratoRunning || conflictReason(group) != nil)
                .help(seratoWatchdog.isSeratoRunning
                    ? "Quit Serato before resolving — Serato can clobber the database V2 changes from its in-memory cache."
                    : "Move non-keepers in this group to Trash and remove their Serato references in one batch.")
            }
            if let reason = conflictReason(group) {
                Text(reason).font(.callout).foregroundStyle(.orange)
            }
            VStack(spacing: density.detailSpacing) {
                ForEach(group.files, id: \.id) { file in
                    duplicateRow(file: file, group: group)
                }
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

    private func modeHeader(for group: ScannedGroup) -> String {
        switch group.mode {
        case .byteLevel:
            let first = group.files.first
            let size = first.map { Self.byteCountFormatter.string(fromByteCount: $0.fileSize) } ?? ""
            return "byte-level, \(size) each"
        case .perceptual:
            return "perceptual match"
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
            VStack(alignment: .leading, spacing: density.detailSpacing) {
                TrackHeading(artist: file.artist, title: file.title, filename: (file.path as NSString).lastPathComponent)
                Text(file.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(density == .comfortable ? 2 : 1)
                    .truncationMode(.middle)
                    .help(file.path)
                if isKeeper {
                    StatusBadge(title: "Keeper", systemImage: "checkmark.circle", tint: .accentColor)
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
                    if group.mode == .perceptual {
                        statusBadge(file.fingerprintStatus)
                    }
                }
                .font(.callout.monospacedDigit())
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: file.path)]
                )
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Show this file in Finder so you can review or delete it manually.")
        }
        .padding(.vertical, density.rowPadding)
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
            guard effectiveKeeperId(for: group) != nil else { return accumulator }
            return accumulator + (group.size - 1)
        }
    }

    private func rescan() async {
        isScanning = true
        defer { isScanning = false }
        actionError = nil
        let mode = mode
        do {
            let scan = try await services.database.writer.read { database in
                try (groups: DuplicateFinder.findDuplicates(in: database, mode: mode), coverage: DuplicateFinder.fingerprintCoverage(in: database))
            }
            groups = scan.groups
            fingerprintCoverage = scan.coverage
            // Drop overrides for groups that no longer exist after
            // the rescan — preserves the user's per-group picks for
            // surviving groups while pruning stale ones.
            let currentIds = Set(groups.map(\.id))
            keeperOverrides = keeperOverrides.filter { entry in currentIds.contains(entry.key) }
        } catch {
            actionError = "Couldn't scan library: \(error.localizedDescription)"
        }
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
        defer { isResolving = false }
        actionError = nil
        lastResolution = nil

        let resolver = DuplicateResolver(operationEngine: services.operationEngine, database: services.database, activityLog: services.activityLog)
        do {
            let outcome = try await resolver.resolve(group: group, keeperId: keeperId)
            if outcome.failureCount == 0 {
                lastResolution = "Moved \(outcome.trashedCount) duplicate\(outcome.trashedCount == 1 ? "" : "s") to Trash; \(outcome.pendingCount) pending until Serato closes"
            } else {
                actionError = "Moved \(outcome.trashedCount); \(outcome.pendingCount) pending; \(outcome.failureCount) stopped (see activity log)"
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
                guard let keeperId = effectiveKeeperId(for: group) else { return nil }
                return (group, keeperId)
            }
        guard !resolvable.isEmpty else {
            actionError = "No groups have a determinable keeper to resolve."
            return
        }

        isResolving = true
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
        if let message = await services.operationEngine.failedDuplicateCleanupMessage {
            services.syncSession.reportFailure(message)
        }
    }
}
