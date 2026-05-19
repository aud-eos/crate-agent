import SwiftUI

@main
struct CrateAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices.bootstrap()

    var body: some Scene {
        WindowGroup {
            LibraryBrowserView()
                .environmentObject(services)
                .environmentObject(services.seratoWatchdog)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("crate-agent", systemImage: "music.note.list") {
            MenuBarStatusView()
                .environmentObject(services)
                .environmentObject(services.seratoWatchdog)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(services)
        }
    }
}
