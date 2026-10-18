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
    /// Makes this row a Command-O target while it has keyboard focus.
    /// Clicking or tabbing to the row focuses it; typing in a search field
    /// takes focus away, so Command-O then opens nothing. VoiceOver gets an
    /// Open action on the row. Nil `fileID` leaves the row as it is.
    func fileOpenTarget(_ fileID: Int64?, focus: FocusState<Int64?>.Binding, opener: FileOpener) -> some View {
        modifier(FileOpenTarget(fileID: fileID, focus: focus, opener: opener))
    }

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

private struct FileOpenTarget: ViewModifier {
    let fileID: Int64?
    let focus: FocusState<Int64?>.Binding
    let opener: FileOpener

    func body(content: Content) -> some View {
        if let fileID {
            content
                .background(focus.wrappedValue == fileID ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .focusable()
                .focused(focus, equals: fileID)
                .simultaneousGesture(TapGesture().onEnded { focus.wrappedValue = fileID })
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: FileOpenerMessages.openAction) { Task { await opener.open(fileID: fileID) } }
        } else {
            content
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
                Button(CommonLabels.dismiss, action: opener.dismissFailure)
                    .accessibilityLabel(FileOpenerMessages.dismissFailure)
            }
            .padding(.horizontal, density.pagePadding)
            .padding(.vertical, density.rowPadding)
            Divider()
        }
    }
}
