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
}
