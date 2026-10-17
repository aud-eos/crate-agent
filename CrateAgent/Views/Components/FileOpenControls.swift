import SwiftUI

/// "Open in <default app>", the other apps that can open the file, and
/// Reveal in Finder, for SwiftUI context menus.
struct FileOpenMenuItems: View {
    @ObservedObject var opener: FileOpener
    let path: String

    var body: some View {
        let defaultApplication = opener.defaultApplication(for: path)
        Button(FileOpenerMessages.open(in: defaultApplication?.name ?? FileOpenerMessages.defaultApplication)) {
            Task { await opener.open(path) }
        }
        .disabled(defaultApplication == nil)
        let others = opener.otherApplications(for: path)
        if !others.isEmpty {
            Section(FileOpenerMessages.openWith) {
                ForEach(others) { application in
                    Button(application.name) { Task { await opener.open(path, with: application) } }
                }
            }
        }
        Divider()
        Button(FileOpenerMessages.reveal) { opener.reveal(path) }
    }
}

/// Shows why the last open or reveal failed, window-wide.
struct FileOpenFailureBanner: View {
    @ObservedObject var opener: FileOpener
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable

    var body: some View {
        if let failure = opener.failure {
            HStack(spacing: density.spacing) {
                ActionErrorMessage(message: failure)
                Spacer(minLength: density.spacing)
                Button(FileOpenerMessages.dismiss, action: opener.dismissFailure)
            }
            .padding(.horizontal, density.pagePadding)
            .padding(.vertical, density.rowPadding)
            Divider()
        }
    }
}
