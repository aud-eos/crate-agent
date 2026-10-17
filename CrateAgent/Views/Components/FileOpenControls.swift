import SwiftUI

/// "Open in <default app>", the other apps that can open the file, Other…,
/// and Reveal in Finder, for SwiftUI context menus.
struct FileOpenMenuItems: View {
    @ObservedObject var opener: FileOpener
    let fileID: Int64
    let path: String

    var body: some View {
        let defaultApplication = opener.defaultApplication(for: path)
        Button(FileOpenerMessages.open(in: defaultApplication?.name ?? FileOpenerMessages.defaultApplication)) {
            Task { await opener.open(fileID: fileID) }
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(defaultApplication == nil)
        Section(FileOpenerMessages.openWith) {
            ForEach(opener.otherApplications(for: path)) { application in
                Button(application.name) { Task { await opener.open(fileID: fileID, with: .application(application)) } }
            }
            Button(FileOpenerMessages.otherApplication) { Task { await opener.open(fileID: fileID, with: .chooseApplication) } }
        }
        Divider()
        Button(FileOpenerMessages.reveal) { Task { await opener.reveal(fileID: fileID) } }
    }
}

extension View {
    /// Command-O opens `fileID`, the panel's focused file, in its default application.
    func fileOpenShortcut(_ opener: FileOpener, fileID: Int64?) -> some View {
        background {
            Button(FileOpenerMessages.openVerb) {
                if let fileID {
                    Task { await opener.open(fileID: fileID) }
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(fileID == nil)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
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
