import GRDB
import SwiftUI

struct LibraryBrowserView: View {
    @EnvironmentObject private var services: AppServices
    @State private var indexedFileCount: Int = 0

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("crate-agent")
                .font(.title)
            Text("Library browser will live here.")
                .foregroundStyle(.secondary)

            Divider().padding(.horizontal, 80)

            VStack(spacing: 4) {
                Text("Files indexed: \(indexedFileCount)")
                    .font(.headline.monospacedDigit())
                Text("Watching: \(services.watchedMusicFolder.path)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text("Rust core v\(coreVersion())")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 800, minHeight: 600)
        .padding()
        .task {
            await observeIndexedFileCount()
        }
    }

    /// Live count of rows in the `files` table via GRDB's
    /// ValueObservation. Re-fires whenever the table changes — when
    /// FilesystemSyncCoordinator inserts a new row in response to an
    /// FSEvents create, the UI updates without manual polling.
    private func observeIndexedFileCount() async {
        let observation = ValueObservation.tracking { db in
            try FileRecord.fetchCount(db)
        }
        do {
            for try await count in observation.values(in: services.database.writer) {
                indexedFileCount = count
            }
        } catch {
            // Transient DB unavailability is tolerable; the next
            // observation cycle picks up automatically.
        }
    }
}
