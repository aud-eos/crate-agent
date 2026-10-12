import GRDB
import SwiftUI

struct MenuBarStatusView: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var seratoWatchdog: SeratoWatchdog
    @State private var indexedFileCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            PageHeading("crate-agent", subtitle: "Library status")

            LibrarySyncStatusView(state: services.syncState, retry: services.retrySync, phase: services.syncPhase, fileInfoFailures: services.syncFileInfoFailures, progress: services.scanProgress, hasConflicts: !services.syncSession.conflicts.isEmpty, review: {
                openWindow(id: AppPresentation.mainWindowID)
                services.reviewConflicts()
            })

            Text("\(indexedFileCount) files indexed")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            if services.pendingSeratoQueueDepth > 0 {
                HStack(spacing: density.spacing) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.orange)
                    Text("\(services.pendingSeratoQueueDepth) change\(services.pendingSeratoQueueDepth == 1 ? "" : "s") pending sync")
                        .font(.callout.monospacedDigit())
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
        .padding(density.pagePadding)
        .frame(width: 340)
        .appPresentation()
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
