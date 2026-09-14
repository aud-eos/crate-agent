import GRDB
import SwiftUI

struct LibraryBrowserView: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices

    /// Hard cap on rows the table renders. SwiftUI Table doesn't scale
    /// past ~10k items even with virtualization — diffing + accessibility
    /// + Sendable copies of the array all touch every element. For DJ
    /// libraries the user reaches into via search anyway; showing 1000
    /// rows by default plus a search-to-narrow affordance gives smooth
    /// scrolling without losing functionality.
    nonisolated static let visibleRowCap = 1000

    @State private var rows: [BrowserRow] = []
    @State private var totalRowCount: Int = 0
    @State private var sortOrder: [KeyPathComparator<BrowserRow>] = [
        KeyPathComparator(\BrowserRow.path, order: .forward),
    ]
    @State private var searchText: String = ""
    /// Debounced copy of `searchText` — drives the actual SQL query.
    /// Updated 150 ms after the user stops typing so fast typing
    /// doesn't trigger a query per keystroke.
    @State private var debouncedSearch: String = ""
    @State private var showRestartAlert: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var lastImportSummary: String?
    @State private var renameTarget: FileRecord?
    @State private var selectedFileIds: Set<BrowserRow.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("Library", subtitle: "Search your indexed Serato tracks. Select a track to rename it or show it in Finder.")
                .padding(density.pagePadding)
            statusHeader
            Divider()
            tableSection
            Divider()
            footer
        }
        .frame(minWidth: 920, minHeight: 600)
        .appPresentation()
        .task { await observeRowCount() }
        // Debounce: 150 ms after typing settles, copy searchText to
        // debouncedSearch which is the actual query input.
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            if debouncedSearch != searchText {
                debouncedSearch = searchText
            }
        }
        // Re-fetch when search, sort, or underlying data changes.
        // sortOrder isn't Hashable; key by its String description.
        .task(id: FetchTrigger(search: debouncedSearch,
                               sortOrderKey: sortOrderKey,
                               totalRowCount: totalRowCount))
        {
            await refetch()
        }
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
                lastImportSummary = result.filesImported == 0
                    ? "Nothing imported (\(result.filesSkipped) skipped)"
                    : "Imported \(result.filesImported) track\(result.filesImported == 1 ? "" : "s")"
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
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
            if let progress = services.scanProgress, !services.initialScanComplete {
                ProgressView().controlSize(density.controlSize)
                Text("Syncing from Serato… \(progress.filesIndexed) new, \(progress.filesMetadataUpdated) updated, of \(progress.seratoReferenceCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if let fingerprintProgress = services.fingerprintProgress,
                      fingerprintProgress.totalPending > 0
            {
                ProgressView().controlSize(density.controlSize)
                Text("Fingerprinting… \(fingerprintProgress.totalDone) done, \(fingerprintProgress.totalPending) pending")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if services.initialScanComplete {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("Library in sync with Serato")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

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

    private var tableSection: some View {
        Table(rows, selection: $selectedFileIds, sortOrder: $sortOrder) {
            TableColumn("Artist", value: \.artistOrEmpty) { file in
                Text(file.artist ?? "—")
                    .padding(.vertical, density.rowPadding / 2)
                    .foregroundStyle(file.artist == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Title", value: \.titleOrEmpty) { file in
                Text(file.title ?? file.filenameOnly)
                    .foregroundStyle(file.title == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 180, ideal: 280)

            TableColumn("BPM", value: \.bpmOrEmpty) { file in
                Text(file.bpm ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)

            TableColumn("Key", value: \.musicalKeyOrEmpty) { file in
                Text(file.musicalKey ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 50)

            TableColumn("Album", value: \.albumOrEmpty) { file in
                Text(file.album ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 140, ideal: 200)

            TableColumn("Folder", value: \.folderPath) { file in
                Text(file.folderPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(file.path)
            }
            .width(min: 140, ideal: 240)
        }
        .searchable(text: $searchText, prompt: "Filter by artist, title, album, or path…")
        .contextMenu(forSelectionType: BrowserRow.ID.self) { selectedIds in
            if let singleId = selectedIds.first, selectedIds.count == 1,
               let row = rows.first(where: { $0.id == singleId })
            {
                Button("Rename…") {
                    Task { await openRenameDialog(forRowId: row.id) }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: row.path)]
                    )
                }
            }
        }
    }

    private func openRenameDialog(forRowId rowId: Int64) async {
        do {
            let record = try await services.database.writer.read { db in
                try FileRecord.fetchOne(db, key: rowId)
            }
            if let record {
                renameTarget = record
            }
            // record == nil is the common case (row vanished
            // between menu open and fetch) — no UI action, no log.
        } catch {
            // CLAUDE.md no-silent-failures: surface the DB read
            // error to the activity strip so the user sees that
            // the Rename… click didn't no-op for a mysterious
            // reason. The strip is the always-on diagnostic
            // surface; the rename dialog itself doesn't get to
            // open here, so this is the only path the user can
            // observe.
            services.activityLog.log(
                "Rename… couldn't load file id \(rowId): \(error.localizedDescription)",
                category: .general
            )
        }
    }

    private var footer: some View {
        HStack(spacing: density.spacing) {
            Text("\(rows.count.formatted()) of \(totalRowCount.formatted()) file\(totalRowCount == 1 ? "" : "s")")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            if rows.count >= Self.visibleRowCap, totalRowCount > Self.visibleRowCap {
                Text("· capped at \(Self.visibleRowCap.formatted()), search to narrow")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
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

    // MARK: - Data loading

    /// Observe the total row count and tick the FetchTrigger when
    /// it changes. We trigger refetch on counter changes (rather
    /// than on every files-table write) because most writes don't
    /// affect the visible row set under the current search/sort.
    /// A count change is a strong signal that the visible set
    /// might have changed; for metadata edits the user can
    /// refresh by toggling the search (or we add explicit refresh
    /// in a follow-up).
    private func observeRowCount() async {
        let observation = ValueObservation
            .tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? 0
            }
            .removeDuplicates()
        do {
            for try await count in observation.values(in: services.database.writer) {
                totalRowCount = count
            }
        } catch {
            // ValueObservation errors are transient; next emission
            // resumes.
        }
    }

    private func refetch() async {
        let needle = debouncedSearch
        let order = sortOrder
        do {
            let fetched: [BrowserRow] = try await services.database.writer.read { db in
                try Self.fetchBrowserRows(
                    db, search: needle, sortOrder: order, limit: Self.visibleRowCap
                )
            }
            rows = fetched
        } catch {
            // Defensive — keep showing the previous rows on transient errors.
        }
    }

    /// Stringly key for sort-order in FetchTrigger. KeyPathComparator
    /// itself isn't Hashable, but PartialKeyPath is — combine with
    /// the SortOrder for a stable key.
    private var sortOrderKey: String {
        sortOrder.map { comparator in
            let column = Self.sqlColumn(for: comparator.keyPath)
            let direction = comparator.order == .forward ? "asc" : "desc"
            return "\(column):\(direction)"
        }.joined(separator: "|")
    }

    /// Build and run the projection query. SELECT projects away the
    /// BLOBs; WHERE applies user search with LIKE COLLATE NOCASE;
    /// ORDER BY honors the user's column-tap; LIMIT caps the result
    /// at `Self.visibleRowCap` so the SwiftUI Table never sees a
    /// 32k array.
    nonisolated static func fetchBrowserRows(
        _ db: GRDB.Database,
        search: String,
        sortOrder: [KeyPathComparator<BrowserRow>],
        limit: Int
    ) throws -> [BrowserRow] {
        var sql = """
        SELECT id, path, artist, title, album, bpm, musical_key
        FROM files
        """
        var arguments: [DatabaseValueConvertible] = []

        if !search.isEmpty {
            // SQLite LIKE with `COLLATE NOCASE` does case-insensitive
            // matching on ASCII. For Unicode case folding, GRDB
            // supports custom collations — out of scope for this
            // pass.
            sql += """
             WHERE (path LIKE ? COLLATE NOCASE)
                OR (COALESCE(artist, '') LIKE ? COLLATE NOCASE)
                OR (COALESCE(title, '') LIKE ? COLLATE NOCASE)
                OR (COALESCE(album, '') LIKE ? COLLATE NOCASE)
            """
            let pattern = "%\(search)%"
            arguments = [pattern, pattern, pattern, pattern]
        }

        let orderBy = orderByClause(for: sortOrder.first)
        sql += " ORDER BY \(orderBy)"
        sql += " LIMIT \(limit)"

        return try BrowserRow.fetchAll(
            db, sql: sql, arguments: StatementArguments(arguments)
        )
    }

    /// Translate the first sort comparator to a SQL ORDER BY clause.
    nonisolated static func orderByClause(for comparator: KeyPathComparator<BrowserRow>?) -> String {
        let direction = (comparator?.order ?? .forward) == .forward ? "ASC" : "DESC"
        let column = sqlColumn(for: comparator?.keyPath)
        return "\(column) \(direction)"
    }

    /// Map a `BrowserRow` keypath (used by SwiftUI Table's sort) to
    /// the matching SQL column expression. The empty-string
    /// projections (artistOrEmpty, etc.) map to `COALESCE(col, '')`
    /// so null values sort consistently regardless of SQLite's
    /// default null ordering.
    nonisolated static func sqlColumn(for keyPath: PartialKeyPath<BrowserRow>?) -> String {
        switch keyPath {
        case \BrowserRow.path: "path"
        case \BrowserRow.artistOrEmpty: "COALESCE(artist, '')"
        case \BrowserRow.titleOrEmpty: "COALESCE(title, '')"
        case \BrowserRow.albumOrEmpty: "COALESCE(album, '')"
        case \BrowserRow.bpmOrEmpty: "COALESCE(bpm, '')"
        case \BrowserRow.musicalKeyOrEmpty: "COALESCE(musical_key, '')"
        case \BrowserRow.folderPath: "path"
        default: "path"
        }
    }
}

/// Composite trigger for refetch — `.task(id:)` runs when any of
/// these change. Hashable so it works as a task id.
private struct FetchTrigger: Hashable {
    let search: String
    let sortOrderKey: String
    let totalRowCount: Int
}
