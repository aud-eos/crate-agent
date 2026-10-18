import GRDB
import SwiftUI

/// SP-1.5's library cleanup surface. TabView containing per-feature
/// panels — Whitespace (trim leading/trailing), Find & Replace
/// (substring rewrite), Case (collapse inconsistent capitalizations
/// onto a canonical spelling). All panels share the scan → preview
/// → apply skeleton: an analyzer in `LibraryHygiene` derives a
/// structured issue list, the sheet renders a preview, and
/// `LibraryHygieneRunner` batches every fix under a single `batch_id`
/// so a single Undo on History reverts the entire cleanup.
struct LibraryHygieneView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        TabView {
            WhitespacePanel()
                .tabItem { Label("Whitespace", systemImage: "scissors") }

            FindReplacePanel()
                .tabItem { Label("Find & Replace", systemImage: "text.magnifyingglass") }

            CaseConsistencyPanel()
                .tabItem { Label("Case", systemImage: "textformat") }

            MissingFieldsPanel()
                .tabItem { Label("Missing", systemImage: "exclamationmark.bubble") }

            DuplicatesPanel()
                .tabItem { Label("Duplicates", systemImage: "square.on.square") }

            SharedOpeningsPanel()
                .tabItem { Label("Shared Openings", systemImage: "waveform.path.ecg") }
        }
        .navigationTitle("Library Cleanup")
        .appPresentation()
        .frame(minWidth: 680, minHeight: 480)
    }
}
