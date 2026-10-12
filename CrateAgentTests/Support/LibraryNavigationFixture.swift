@testable import CrateAgent
import SwiftUI

@MainActor
final class LibraryNavigationSelection: ObservableObject {
    @Published var section = MainWindowView.Section.library
}

struct LibraryNavigationFixture: View {
    @ObservedObject var selection: LibraryNavigationSelection
    let model: LibraryBrowserModel
    let readiness: LibrarySyncReadiness
    var body: some View {
        MainWindowNavigation(selection: $selection.section, hasConflicts: false) {
            VStack {
                Text(selection.section.displayName)
                LibraryPagedContent(model: model, density: .comfortable, showsFilenames: false, readiness: readiness, onAction: { _, _ in })
            }
        }
    }
}
