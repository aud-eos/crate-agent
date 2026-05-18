import SwiftUI

@main
struct CrateAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var seratoWatchdog = SeratoWatchdog()

    var body: some Scene {
        WindowGroup {
            LibraryBrowserView()
                .environmentObject(seratoWatchdog)
                .task { seratoWatchdog.startObservingWorkspace() }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("crate-agent", systemImage: "music.note.list") {
            MenuBarStatusView()
                .environmentObject(seratoWatchdog)
        }
        .menuBarExtraStyle(.window)
    }
}
