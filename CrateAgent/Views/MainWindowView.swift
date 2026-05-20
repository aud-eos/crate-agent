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

    @State private var selection: Section = .library

    var body: some View {
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
