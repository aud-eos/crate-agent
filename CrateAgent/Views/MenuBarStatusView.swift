import SwiftUI

struct MenuBarStatusView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("crate-agent")
                .font(.headline)
            Text("Watcher status will live here.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .frame(width: 260)
    }
}

#Preview {
    MenuBarStatusView()
}
