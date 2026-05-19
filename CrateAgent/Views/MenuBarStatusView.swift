import GRDB
import SwiftUI

struct MenuBarStatusView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog
    @State private var indexedFileCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("crate-agent")
                .font(.headline)

            HStack(spacing: 6) {
                Circle()
                    .fill(seratoWatchdog.isSeratoRunning ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(seratoWatchdog.isSeratoRunning
                    ? "Serato is running — writes deferred"
                    : "Idle — ready to sync")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(indexedFileCount) files indexed")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if services.pendingSeratoQueueDepth > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.orange)
                    Text("\(services.pendingSeratoQueueDepth) change\(services.pendingSeratoQueueDepth == 1 ? "" : "s") pending sync")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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
        .task {
            await observeIndexedFileCount()
        }
    }

    private func observeIndexedFileCount() async {
        let observation = ValueObservation.tracking { db in
            try FileRecord.fetchCount(db)
        }
        do {
            for try await count in observation.values(in: services.database.writer) {
                indexedFileCount = count
            }
        } catch {
            // Tolerable
        }
    }
}
