import SwiftUI

@main
struct CrateAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var launcher = AppLauncher()

    var body: some Scene {
        WindowGroup {
            rootView
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Cleanup and History are first-class windows rather than
        // modal sheets so the user can resize, leave them open
        // beside the browser, and treat them as long-lived tools.
        // `Window` (not `WindowGroup`) gives us a singleton per
        // identifier — repeated `openWindow(id:)` calls focus the
        // existing window instead of spawning duplicates.
        Window("Library Cleanup", id: "cleanup") {
            cleanupContent
        }
        .defaultSize(width: 900, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("History", id: "history") {
            historyContent
        }
        .defaultSize(width: 720, height: 520)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("crate-agent", systemImage: "music.note.list") {
            menuBarContent
        }
        .menuBarExtraStyle(.window)

        Settings {
            settingsContent
        }
    }

    @ViewBuilder
    private var rootView: some View {
        switch launcher.state {
        case .needsOnboarding:
            OnboardingView { pickedFolder in
                launcher.completeOnboarding(withFolder: pickedFolder)
            }
        case .ready(let services):
            LibraryBrowserView()
                .environmentObject(services)
                .environmentObject(services.seratoWatchdog)
        }
    }

    /// MenuBarExtra and Settings can't be conditional scenes here —
    /// SwiftUI's SceneBuilder type-checking breaks on a mix of
    /// `WindowGroup` (with modifiers) and `if case`-guarded
    /// `MenuBarExtra` / `Settings`. Putting the conditional inside
    /// the View body sidesteps that.
    @ViewBuilder
    private var menuBarContent: some View {
        switch launcher.state {
        case .needsOnboarding:
            VStack(alignment: .leading, spacing: 6) {
                Text("crate-agent")
                    .font(.headline)
                Text("Finish setup to start watching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 220)
        case .ready(let services):
            MenuBarStatusView()
                .environmentObject(services)
                .environmentObject(services.seratoWatchdog)
        }
    }

    @ViewBuilder
    private var cleanupContent: some View {
        switch launcher.state {
        case .needsOnboarding:
            unavailablePlaceholder(
                message: "Finish setup to use Library Cleanup."
            )
        case .ready(let services):
            LibraryHygieneView()
                .environmentObject(services)
                .environmentObject(services.seratoWatchdog)
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        switch launcher.state {
        case .needsOnboarding:
            unavailablePlaceholder(
                message: "Finish setup to view History."
            )
        case .ready(let services):
            HistoryView()
                .environmentObject(services)
        }
    }

    @ViewBuilder
    private func unavailablePlaceholder(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "gear.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 360, minHeight: 200)
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch launcher.state {
        case .needsOnboarding:
            VStack(spacing: 8) {
                Image(systemName: "gear.badge.questionmark")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Finish setup to configure crate-agent.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 360, height: 200)
        case .ready(let services):
            SettingsView()
                .environmentObject(services)
        }
    }
}
