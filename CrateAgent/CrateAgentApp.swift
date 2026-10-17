import SwiftUI

@main
struct CrateAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var launcher = AppLauncher()

    var body: some Scene {
        WindowGroup(id: AppPresentation.mainWindowID) {
            rootView
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("crate-agent", systemImage: "music.note.list", isInserted: .constant(!ApplicationRuntime.isTesting)) {
            menuBarContent
        }
        .menuBarExtraStyle(.window)

        Settings {
            settingsContent
        }
        .windowResizability(.contentMinSize)
    }

    @ViewBuilder
    private var rootView: some View {
        switch launcher.state {
        case .inactive:
            EmptyView()
        case .needsOnboarding:
            OnboardingView { pickedFolder in
                launcher.completeOnboarding(withFolder: pickedFolder)
            }
        case let .ready(services):
            MainWindowView()
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
        case .inactive:
            EmptyView()
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
        case let .ready(services):
            MenuBarStatusView()
                .environmentObject(services)
                .environmentObject(services.seratoWatchdog)
                .environmentObject(services.activityLog)
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch launcher.state {
        case .inactive:
            EmptyView()
        case .needsOnboarding:
            VStack(spacing: 8) {
                Image(systemName: "gear.badge.questionmark")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Finish setup to configure crate-agent.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 360, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        case let .ready(services):
            SettingsView()
                .environmentObject(services)
        }
    }
}
