import AppKit
import SwiftUI

/// SwiftUI button that opens an NSOpenPanel folder picker. AppKit
/// rather than SwiftUI's `.fileImporter` because the latter is
/// fileExporter-flavored and quirky around directory selection on
/// macOS; `NSOpenPanel.runModal` is the established native pattern.
struct FolderPickerButton: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let title: String
    let message: String
    let onPick: (URL) -> Void

    var body: some View {
        Button(title) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.message = message
            panel.prompt = "Choose"
            if panel.runModal() == .OK, let pickedUrl = panel.url {
                onPick(pickedUrl)
            }
        }
        .controlSize(density.controlSize)
    }
}
