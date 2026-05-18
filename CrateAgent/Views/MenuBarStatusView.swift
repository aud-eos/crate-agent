import SwiftUI

struct MenuBarStatusView: View {
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("crate-agent")
                .font(.headline)
            HStack(spacing: 6) {
                Circle()
                    .fill(seratoWatchdog.isSeratoRunning ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(seratoWatchdog.isSeratoRunning
                    ? "Serato is running — writes are deferred"
                    : "Idle — ready to sync")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button("Open Main Window") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            Button("Quit crate-agent") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

#Preview {
    MenuBarStatusView()
        .environmentObject(SeratoWatchdog(runningBundleIdentifiersProvider: { [] }))
}
