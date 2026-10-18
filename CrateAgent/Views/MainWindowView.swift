import SwiftUI

/// Top-level shell for the ready state. Hosts a `NavigationSplitView`
/// with a sidebar that switches between the three feature surfaces
/// (Library, Cleanup, History) inside a single window — the
/// Mail/Music/Finder pattern for utility apps. New sub-projects'
/// surfaces add a sidebar entry rather than a new window.
struct MainWindowView: View {
    enum Section: String, Hashable, CaseIterable, Identifiable {
        case library
        case organize
        case cleanup
        case autoTag
        case history
        case workers
        case conflicts

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .library: "Library"
            case .organize: "Organize"
            case .cleanup: "Library Cleanup"
            case .autoTag: "Auto-Tag"
            case .history: "History"
            case .workers: WorkerMessages.sectionTitle
            case .conflicts: SeratoConflictMessages.review
            }
        }

        var iconName: String {
            switch self {
            case .library: "music.note.list"
            case .organize: "folder.badge.gearshape"
            case .cleanup: "sparkles"
            case .autoTag: "wand.and.stars"
            case .history: "clock.arrow.circlepath"
            case .workers: "gearshape.2"
            case .conflicts: "exclamationmark.triangle"
            }
        }
    }

    @EnvironmentObject private var services: AppServices
    @State private var selection: Section = .library

    var body: some View {
        VStack(spacing: 0) {
            if services.syncState != .idle {
                LibrarySyncStatusView(state: services.syncState, retry: services.retrySync, phase: services.syncPhase, fileInfoFailures: services.syncFileInfoFailures, progress: services.scanProgress, hasConflicts: !services.syncSession.conflicts.isEmpty, review: services.reviewConflicts)
            }
            MainWindowNavigation(selection: $selection, hasConflicts: !services.syncSession.conflicts.isEmpty) {
                detailView
            }
            Divider()
            NowPlayingBar(player: services.trackPlayer)
            AutoTagActivityView(session: services.autoTagSession) { selection = .autoTag }
            ActivityStrip()
                .environmentObject(services.activityLog)
        }
        // Sidebar (180–260) + Library Browser's 920 detail minimum
        // = ~1100 min content width. Round to 1120 for a small
        // safety margin so the browser table never compresses.
        .frame(minWidth: 1120, minHeight: 640)
        .appPresentation()
        .onAppear { handleConflictNavigation() }
        .onChange(of: services.conflictNavigationRequest) { _, _ in handleConflictNavigation() }
        .onChange(of: services.sectionRequest) { _, request in
            guard let request else { return }
            selection = request
            services.consumeSectionRequest()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                DensityPicker()
                    .pickerStyle(.menu)
                    .frame(width: 170)
            }
        }
    }

    private func handleConflictNavigation() {
        guard services.conflictNavigationRequest != nil else { return }
        selection = .conflicts
        services.consumeConflictNavigation()
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .library:
            LibraryBrowserView()
        case .organize:
            OrganizeView()
        case .cleanup:
            LibraryHygieneView()
        case .autoTag:
            AutoTaggerView(session: services.autoTagSession, player: services.trackPlayer, readiness: services.readiness, conflictRevision: services.readiness.scopeRevision)
        case .history:
            HistoryView()
        case .workers:
            WorkersView(model: services.workersModel)
        case .conflicts:
            SeratoConflictReviewView(model: services.conflictReviewModel)
        }
    }
}

private struct AutoTagActivityView: View {
    @ObservedObject var session: AutoTagSession
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let openAutoTag: () -> Void

    var body: some View {
        if session.isScanning || session.isApplying || session.pendingResyncBatchId != nil {
            HStack(spacing: density.spacing) {
                if session.isScanning || session.isApplying {
                    ProgressView().controlSize(density.controlSize)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(status)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: density.spacing)
                Button("Open Auto-Tag", action: openAutoTag)
            }
            .padding(.horizontal, density.pagePadding)
            .padding(.vertical, density.rowPadding)
            .background(Color.accentColor.opacity(0.06))
            Divider()
        }
    }

    private var status: String {
        if session.isApplying {
            return "Auto-Tag is applying approved tracks…"
        }
        if session.pendingResyncBatchId != nil {
            return "Auto-Tag has an applied batch awaiting Re-sync."
        }
        return "Auto-Tag scan: \(session.completedCount) of \(session.totalCount) tracks finished. You can keep working."
    }
}

/// Always-on one-line strip at the bottom of the main window. Reads
/// `ActivityLog.latest` and renders it with a category badge + a
/// relative timestamp. Goes blank with a hint message when nothing's
/// been logged yet — never absent, so the user has a fixed place to
/// look for "is crate-agent doing anything right now?".
///
/// Clickable: opens a popover that shows the full rolling buffer
/// (`activityLog.recent`) so the user can scroll through entries the
/// one-line strip already replaced. Critical for debugging fast
/// operations that fly past faster than anyone can read.
private struct ActivityStrip: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var activityLog: ActivityLog
    @State private var showHistory: Bool = false

    var body: some View {
        Button {
            showHistory.toggle()
        } label: {
            HStack(spacing: density.spacing) {
                ActivityEntrySummary(entry: activityLog.latest)
                Text(showHistory ? "Hide log" : "Show log")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, density.pagePadding)
            .padding(.vertical, density.rowPadding)
            .frame(minHeight: 26)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.06))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to see the full activity log (last \(ActivityLog.bufferLimit) entries).")
        .popover(isPresented: $showHistory, arrowEdge: .bottom) {
            ActivityHistoryPopover()
                .environmentObject(activityLog)
        }
    }
}

/// Scrollable history of every `ActivityLog` entry currently in the
/// rolling buffer. Shown as a popover from the strip — gives the
/// user a way to read entries that flew past too fast (per-file
/// progress, ⚠️ sync warnings, partial-failure reports during a
/// batch operation).
///
/// Filter buttons across the top narrow to a single category — the
/// expected workflow during a debug session is "I want to see only
/// the Sync entries from the resync I just ran." Newest-first order
/// matches the strip's behavior.
private struct ActivityHistoryPopover: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var activityLog: ActivityLog
    @State private var filter: Filter = .all

    private enum Filter: Hashable {
        case all
        case category(ActivityLog.Category)

        var displayName: String {
            switch self {
            case .all: "All"
            case let .category(cat): cat.displayName
            }
        }
    }

    private var filterOptions: [Filter] {
        [.all] + ActivityLog.Category.allCases.map(Filter.category)
    }

    private var filteredEntries: [ActivityLog.Entry] {
        switch filter {
        case .all:
            activityLog.recent
        case let .category(cat):
            activityLog.recent.filter { entry in entry.category == cat }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 680, height: 480)
        .appPresentation()
    }

    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: density.spacing) {
                ForEach(filterOptions, id: \.self) { option in
                    Button {
                        filter = option
                    } label: {
                        Text(option.displayName)
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            filter == option
                                ? Color.accentColor.opacity(0.18)
                                : Color.secondary.opacity(0.10)
                        )
                    )
                    .foregroundStyle(filter == option ? Color.accentColor : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, density.rowPadding)
        }
    }

    @ViewBuilder
    private var content: some View {
        if filteredEntries.isEmpty {
            VStack(spacing: density.spacing) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(filter == .all
                    ? "Nothing logged yet."
                    : "No \(filter.displayName) entries.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: density.detailSpacing) {
                    ForEach(filteredEntries) { entry in
                        entryRow(entry)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, density.rowPadding)
            }
        }
    }

    private func entryRow(_ entry: ActivityLog.Entry) -> some View {
        HStack(alignment: .top, spacing: density.spacing) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(entry.category.displayName)
                .font(.callout)
                .frame(width: 98, alignment: .leading)
                .foregroundStyle(entry.category.tint)
            Text(entry.message)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(density == .comfortable ? 5 : 2)
                .truncationMode(.middle)
                .help(entry.message)
            Spacer(minLength: 0)
        }
        .padding(.vertical, density.rowPadding)
    }

    private var footer: some View {
        HStack {
            Text("\(filteredEntries.count) of \(activityLog.recent.count) entries · buffer holds last \(ActivityLog.bufferLimit)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear") {
                activityLog.clear()
            }
            .controlSize(density.controlSize)
            .disabled(activityLog.recent.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, density.rowPadding)
    }
}
