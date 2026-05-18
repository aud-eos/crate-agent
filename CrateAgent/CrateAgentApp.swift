import SwiftUI

@main
struct CrateAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            LibraryBrowserView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("crate-agent", systemImage: "music.note.list") {
            MenuBarStatusView()
        }
        .menuBarExtraStyle(.window)
    }
}
