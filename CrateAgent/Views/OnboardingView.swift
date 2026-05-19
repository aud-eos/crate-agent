import SwiftUI

/// First-launch flow: welcome → pick music folder → start.
///
/// Single-screen design (no multi-step wizard) — the actual decisions
/// fit on one panel and a wizard would be overkill for SP-1. The
/// folder picker defaults to `~/Music`; the Start button is gated on
/// the user having confirmed (or changed) the folder so the user
/// can't blow past the choice with a stray return key.
struct OnboardingView: View {
    let onComplete: (URL) -> Void

    @State private var chosenFolder: URL = OnboardingView.defaultMusicFolder
    @State private var hasConfirmed: Bool = false

    static var defaultMusicFolder: URL {
        (try? FileManager.default.url(
            for: .musicDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            Divider()
            folderSection
            Divider()
            scopeSection
            Spacer(minLength: 0)
            footer
        }
        .padding(32)
        .frame(width: 640, height: 560)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text("Welcome to crate-agent")
                    .font(.title)
                    .fontWeight(.semibold)
            }
            Text("crate-agent watches a folder of music files and keeps Serato's library in sync with the changes you make outside of Serato.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Watched folder", systemImage: "folder")
            Text(chosenFolder.path)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                FolderPickerButton(
                    title: "Change…",
                    message: "Choose the folder crate-agent should watch."
                ) { pickedUrl in
                    chosenFolder = pickedUrl
                    hasConfirmed = true
                }
                Button("Use Default") {
                    chosenFolder = OnboardingView.defaultMusicFolder
                    hasConfirmed = true
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("What happens next", systemImage: "info.circle")
            VStack(alignment: .leading, spacing: 6) {
                bullet("crate-agent reads your Serato library and indexes the files Serato references inside the watched folder. Your files are not moved.")
                bullet("Renames in Finder are mirrored into Serato so the library doesn't lose track of moved or renamed files.")
                bullet("Drop a file or folder onto the library window to register new tracks with Serato.")
                bullet("Audio files are fingerprinted in the background for future track-identity features.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            Button("Start") {
                onComplete(chosenFolder)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(!hasConfirmed)
            .help(hasConfirmed
                  ? "Bootstrap the library and start watching."
                  : "Confirm the watched folder above (Change… or Use Default) to enable Start.")
        }
    }

    @ViewBuilder
    private func sectionHeading(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
        }
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .foregroundStyle(.tertiary)
            Text(text)
        }
    }
}
