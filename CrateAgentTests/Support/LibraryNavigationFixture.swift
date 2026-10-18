import AppKit
@testable import CrateAgent
import SwiftUI

/// Selection lives in @State, as in MainWindowView. Binding the sidebar List to a
/// @Published property publishes inside SwiftUI's selection update; XCTest records that
/// runtime warning by symbolicating on the main thread, stalling the next measured
/// interaction (#217).
@MainActor
final class LibraryNavigationSelection {
    fileprivate(set) var section = MainWindowView.Section.library
}

struct LibraryNavigationFixture: View {
    let selection: LibraryNavigationSelection
    let model: LibraryBrowserModel
    let readiness: LibrarySyncReadiness
    @State private var section = MainWindowView.Section.library

    var body: some View {
        MainWindowNavigation(selection: $section, hasConflicts: false) {
            VStack {
                Text(section.displayName)
                LibraryPagedContent(model: model, density: .comfortable, showsFilenames: false, readiness: readiness, onAction: { _, _ in })
            }
        }
        .onChange(of: section) { _, current in selection.section = current }
    }

    /// The first split-view window in a process pays one-time, library-independent AppKit and
    /// SwiftUI setup (toolbar, split view, sidebar). Content-render budgets measure a window
    /// opened after it, so they don't depend on which test runs first (#224).
    static func prepareWindowChrome() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let host = NSHostingView(rootView: MainWindowNavigation(selection: .constant(.library), hasConflicts: false) { EmptyView() })
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.close()
    }
}
