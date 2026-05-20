import SwiftUI

/// Top-level shell for the ready state. Hosts a `NavigationSplitView`
/// with a sidebar that switches between the three feature surfaces
/// (Library, Cleanup, History) inside a single window — the
/// Mail/Music/Finder pattern for utility apps. New sub-projects'
/// surfaces add a sidebar entry rather than a new window.
struct MainWindowView: View {

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case library
        case cleanup
        case history

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .library:  return "Library"
            case .cleanup:  return "Library Cleanup"
            case .history:  return "History"
            }
        }

        var iconName: String {
            switch self {
            case .library:  return "music.note.list"
            case .cleanup:  return "sparkles"
            case .history:  return "clock.arrow.circlepath"
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
private struct ActivityStrip: View {
    @EnvironmentObject private var activityLog: ActivityLog

    var body: some View {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 26)
        .background(Color.secondary.opacity(0.06))
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
