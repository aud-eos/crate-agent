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
            filtered = files.filter { $0.path.lowercased().contains(needle) }
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
                Text("Indexing Serato library… \(progress.filesIndexed) of \(progress.seratoReferenceCount)")
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
            TableColumn("Filename", value: \.filenameOnly)
                .width(min: 200, ideal: 320)

            TableColumn("Folder", value: \.folderPath) { file in
                Text(file.folderPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .width(min: 200, ideal: 360)

            TableColumn("Size", value: \.fileSize) { file in
                Text(byteFormatter.string(fromByteCount: file.fileSize))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Modified", value: \.mtime) { file in
                Text(Self.formatModified(file.mtime))
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 150)

            TableColumn("Status", value: \.fingerprintStatusRawValue) { file in
                fingerprintBadge(for: file.fingerprintStatus)
            }
            .width(min: 80, ideal: 100)
        }
        .searchable(text: $searchText, prompt: "Filter by path…")
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

    @ViewBuilder
    private func fingerprintBadge(for status: FingerprintStatus) -> some View {
        switch status {
        case .pending:
            Label("pending", systemImage: "circle.dashed")
                .labelStyle(.iconOnly)
                .foregroundStyle(.tertiary)
                .help("Fingerprinting pending")
        case .done:
            Label("done", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .help("Fingerprint complete")
        case .failed:
            Label("failed", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
                .help("Fingerprinting failed")
        }
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static func formatModified(_ mtimeSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(mtimeSeconds))
        return Self.dateFormatter.string(from: date)
    }
}
