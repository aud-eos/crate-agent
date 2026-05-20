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
        case history

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .library:   return "Library"
            case .organize:  return "Organize"
            case .cleanup:   return "Library Cleanup"
            case .history:   return "History"
            }
        }

        var iconName: String {
            switch self {
            case .library:   return "music.note.list"
            case .organize:  return "folder.badge.gearshape"
            case .cleanup:   return "sparkles"
            case .history:   return "clock.arrow.circlepath"
            }
        }
    }

    @EnvironmentObject private var services: AppServices
    @State private var selection: Section = .library

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(Section.allCases, selection: $selection) { section in
                    Label(section.displayName, systemImage: section.iconName)
                        .tag(section)
                }
                .navigationTitle("crate-agent")
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            } detail: {
                detailView
            }
            Divider()
            ActivityStrip()
                .environmentObject(services.activityLog)
        }
        // Sidebar (180–260) + Library Browser's 920 detail minimum
        // = ~1100 min content width. Round to 1120 for a small
        // safety margin so the browser table never compresses.
        .frame(minWidth: 1120, minHeight: 640)
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
        case .history:
            HistoryView()
        }
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
    @EnvironmentObject private var activityLog: ActivityLog
    @State private var showHistory: Bool = false

    var body: some View {
        Button {
            showHistory.toggle()
        } label: {
            HStack(spacing: 10) {
                if let entry = activityLog.latest {
                    categoryBadge(entry.category)
                    Text(entry.message)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(entry.timestamp, style: .relative)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text("ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.tertiary)
                    Text("Idle — actions will log here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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

    @ViewBuilder
    private func categoryBadge(_ category: ActivityLog.Category) -> some View {
        Text(category.displayName)
            .font(.caption2.smallCaps())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(categoryTint(category).opacity(0.18))
            )
            .foregroundStyle(categoryTint(category))
    }

    private func categoryTint(_ category: ActivityLog.Category) -> Color {
        switch category {
        case .hygiene:      return .blue
        case .duplicate:    return .orange
        case .rename:       return .purple
        case .fingerprint:  return .pink
        case .sync:         return .teal
        case .scan:         return .green
        case .general:      return .gray
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
    @EnvironmentObject private var activityLog: ActivityLog
    @State private var filter: Filter = .all

    private enum Filter: Hashable {
        case all
        case category(ActivityLog.Category)

        var displayName: String {
            switch self {
            case .all:                  return "All"
            case .category(let cat):    return cat.displayName
            }
        }
    }

    private var filterOptions: [Filter] {
        [.all] + ActivityLog.Category.allCases.map(Filter.category)
    }

    private var filteredEntries: [ActivityLog.Entry] {
        switch filter {
        case .all:
            return activityLog.recent
        case .category(let cat):
            return activityLog.recent.filter { $0.category == cat }
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
        .frame(width: 540, height: 420)
    }

    @ViewBuilder
    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(filterOptions, id: \.self) { option in
                    Button {
                        filter = option
                    } label: {
                        Text(option.displayName)
                            .font(.caption.smallCaps())
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
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if filteredEntries.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(filter == .all
                     ? "Nothing logged yet."
                     : "No \(filter.displayName) entries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredEntries) { entry in
                        entryRow(entry)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: ActivityLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .leading)
            Text(entry.category.displayName)
                .font(.caption2.smallCaps())
                .frame(width: 78, alignment: .leading)
                .foregroundStyle(categoryTint(entry.category))
            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Text("\(filteredEntries.count) of \(activityLog.recent.count) entries · buffer holds last \(ActivityLog.bufferLimit)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Clear") {
                activityLog.clear()
            }
            .controlSize(.small)
            .disabled(activityLog.recent.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func categoryTint(_ category: ActivityLog.Category) -> Color {
        switch category {
        case .hygiene:      return .blue
        case .duplicate:    return .orange
        case .rename:       return .purple
        case .fingerprint:  return .pink
        case .sync:         return .teal
        case .scan:         return .green
        case .general:      return .gray
        }
    }
}
