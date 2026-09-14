import SwiftUI

/// Manual single-file rename UI. The user opens this from the
/// library browser's row context menu, edits a Beets-style template,
/// sees a live preview of the destination path, and confirms.
///
/// Rename flow: validate → move on disk → fire `renameFile` mutation.
/// We *don't* rely on FSEvents alone — the explicit mutation updates
/// the UI immediately rather than after FSEvents's ~1s latency. The
/// FSEvents-driven callback that follows is harmless: it reads the
/// just-updated DB row, sees `existing.path == newPath`, and no-ops.
///
/// The dialog itself doesn't do path computation — that lives in
/// `RenameDestinationPlanner` as a testable pure function so the
/// behavior (folder = bucket letter, filename = templated) is pinned
/// without instantiating SwiftUI.
struct RenameDialogView: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let file: FileRecord
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var template: String = UserPreferences.filenameTemplate
    @State private var saveAsDefault: Bool = false
    @State private var actionError: String?
    @State private var isRenaming: Bool = false

    private var sourceUrl: URL {
        URL(fileURLWithPath: file.path)
    }

    private var destinationUrl: URL {
        RenameDestinationPlanner.destination(
            forFile: file,
            musicFolder: services.watchedMusicFolder,
            template: template
        )
    }

    private var canRename: Bool {
        let destination = destinationUrl
        return destination.path != file.path
            && destination.lastPathComponent.hasSuffix("." + sourceExtension) == true
            && !destination.lastPathComponent.hasPrefix(".")
    }

    private var sourceExtension: String {
        (file.path as NSString).pathExtension
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            PageHeading("Rename track", subtitle: "Preview the filename and folder before moving this file.")

            sourceSection
            templateSection
            previewSection

            Toggle("Save as default template", isOn: $saveAsDefault)
                .font(.callout)

            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            ActionBar {
                if isRenaming {
                    ProgressView("Renaming…")
                }
            } actions: {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    Task { await performRename() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRename || isRenaming)
            }
        }
        .padding(density.pagePadding)
        .frame(width: 680)
        .appPresentation()
    }

    private var sourceSection: some View {
        TrackHeading(artist: file.artist, title: file.title, filename: sourceUrl.lastPathComponent)
    }

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            HStack {
                Text("Filename template")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("$artist · $title · $album · $bpm · $key · $genre · $ext")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            TextField(
                UserPreferences.defaultFilenameTemplate,
                text: $template
            )
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: density.detailSpacing) {
            MetadataComparison(current: file.path, proposed: destinationUrl.path, field: "Location")
            if !canRename {
                StatusBadge(title: "No valid rename to apply", systemImage: "info.circle")
            }
        }
    }

    private func performRename() async {
        isRenaming = true
        defer { isRenaming = false }
        actionError = nil

        let source = sourceUrl
        let destination = destinationUrl

        guard let fileId = file.id else {
            actionError = "File has no database id — refresh the library and try again."
            return
        }

        guard FileManager.default.fileExists(atPath: source.path) else {
            actionError = "Source file no longer exists at \(source.path)"
            return
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            actionError = "A file already exists at the destination."
            return
        }

        let parentDirectory = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            actionError = "Rename failed: \(error.localizedDescription)"
            return
        }

        // FSEvents will see the move within ~1s and might fire its
        // own renameFile mutation. To avoid a duplicate journal entry,
        // re-read the row before issuing ours — if FSEvents already
        // updated it, we're done.
        let currentPath: String?
        do {
            currentPath = try await services.database.writer.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT path FROM files WHERE id = ?",
                    arguments: [fileId]
                )
            }
        } catch {
            actionError = "Rename succeeded on disk but DB read failed: \(error.localizedDescription)"
            return
        }

        if currentPath == destination.path {
            // FSEvents beat us to it. Nothing else to do.
            if saveAsDefault {
                UserPreferences.filenameTemplate = template
            }
            dismiss()
            return
        }

        do {
            _ = try await services.operationEngine.apply(.renameFile(RenameFilePayload(
                fileId: fileId,
                newPath: destination.path
            )))
        } catch {
            actionError = "Disk move succeeded but Serato/DB update failed: \(error.localizedDescription)"
            return
        }

        if saveAsDefault {
            UserPreferences.filenameTemplate = template
        }
        dismiss()
    }
}

/// Pure path-computation for the rename dialog — pulled out of the
/// view so the bucket-letter + template behavior is unit-testable
/// without SwiftUI plumbing.
///
/// Generic over `HygieneFileSource` so it works against the full
/// `FileRecord` (used by the rename dialog) and the lightweight
/// `HygieneFileRow` projection (used by the bulk Organize view —
/// the BLOB columns aren't needed for path computation).
public enum RenameDestinationPlanner {
    public static func destination(
        forFile file: some HygieneFileSource,
        musicFolder: URL,
        template: String
    ) -> URL {
        let metadata = SeratoMetadata(
            artist: file.artist,
            title: file.title,
            album: file.album,
            genre: file.genre,
            bpm: file.bpm,
            musicalKey: file.musicalKey,
            comment: file.comment,
            length: file.length,
            label: file.label
        )
        let fileExtension = (file.path as NSString).pathExtension
        let filename = FilenameTemplateEngine.render(
            template: template,
            metadata: metadata,
            fileExtension: fileExtension
        )
        let bucket = String(ArtistLetterNormalizer.bucketLetter(forArtist: file.artist))
        return musicFolder
            .appendingPathComponent(bucket, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }
}
