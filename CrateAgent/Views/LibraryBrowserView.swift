import GRDB
import SwiftUI

struct LibraryBrowserView: View {
    @EnvironmentObject private var services: AppServices
    @State private var files: [FileRecord] = []
    @State private var sortOrder: [KeyPathComparator<FileRecord>] = [
        KeyPathComparator(\.path, order: .forward)
    ]
    @State private var searchText: String = ""
    @State private var showRestartAlert: Bool = false

    private var filteredSortedFiles: [FileRecord] {
        let filtered: [FileRecord]
        if searchText.isEmpty {
            filtered = files
        } else {
            let needle = searchText.lowercased()
            filtered = files.filter { record in
                record.path.lowercased().contains(needle)
                    || (record.artist?.lowercased().contains(needle) ?? false)
                    || (record.title?.lowercased().contains(needle) ?? false)
                    || (record.album?.lowercased().contains(needle) ?? false)
            }
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            tableSection
            Divider()
            footer
        }
        .frame(minWidth: 920, minHeight: 600)
        .task { await observeFiles() }
        .alert("Restart required", isPresented: $showRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("crate-agent will start watching the new folder the next time it launches.")
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        HStack(spacing: 12) {
            if let progress = services.scanProgress, !services.initialScanComplete {
                ProgressView().controlSize(.small)
                Text("Syncing from Serato… \(progress.filesIndexed) new, \(progress.filesMetadataUpdated) updated, of \(progress.seratoReferenceCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if services.initialScanComplete {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("Library in sync with Serato")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Watching: \(services.watchedMusicFolder.path)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            FolderPickerButton(
                title: "Change…",
                message: "Choose the folder crate-agent should watch."
            ) { pickedUrl in
                UserPreferences.watchedMusicFolder = pickedUrl
                showRestartAlert = true
            }
            .controlSize(.small)
            .help("Watched folder for rename detection. crate-agent indexes only files Serato references; add tracks via Serato or drag-drop onto this window.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var tableSection: some View {
        Table(filteredSortedFiles, sortOrder: $sortOrder) {
            TableColumn("Artist", value: \.artistOrEmpty) { file in
                Text(file.artist ?? "—")
                    .foregroundStyle(file.artist == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Title", value: \.titleOrEmpty) { file in
                Text(file.title ?? file.filenameOnly)
                    .foregroundStyle(file.title == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 180, ideal: 280)

            TableColumn("BPM", value: \.bpmOrEmpty) { file in
                Text(file.bpm ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)

            TableColumn("Key", value: \.musicalKeyOrEmpty) { file in
                Text(file.musicalKey ?? "")
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 50)

            TableColumn("Album", value: \.albumOrEmpty) { file in
                Text(file.album ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 140, ideal: 200)

            TableColumn("Folder", value: \.folderPath) { file in
                Text(file.folderPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.tertiary)
            }
            .width(min: 140, ideal: 240)
        }
        .searchable(text: $searchText, prompt: "Filter by artist, title, album, or path…")
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Text("\(filteredSortedFiles.count.formatted()) of \(files.count.formatted()) files")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Text("Rust core v\(coreVersion())")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func observeFiles() async {
        let observation = ValueObservation.tracking { db in
            try FileRecord.fetchAll(db)
        }
        do {
            for try await freshFiles in observation.values(in: services.database.writer) {
                files = freshFiles
            }
        } catch {
            // ValueObservation errors are transient; the next emission
            // takes over. Surfacing them in UI is a polish item.
        }
    }

    // MARK: - Formatters

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}
