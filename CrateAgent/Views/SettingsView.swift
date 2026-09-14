import SwiftUI

/// macOS Settings window content (Cmd+, opens this). Three tabs:
/// General, Filename Template, About. Lets the user reach config
/// surface area outside the library browser's status header.
///
/// Each tab is a thin form wrapping existing services + UserPreferences;
/// no business logic lives in the view itself. The template preview
/// uses `SettingsTemplatePreviewer.preview(...)` so the rendering rule
/// (sample SeratoMetadata + extension) is unit-testable.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            FilenameTemplateSettingsView()
                .tabItem { Label("Filename Template", systemImage: "textformat") }
            AutoTagSettingsView()
                .tabItem { Label("Auto-Tag", systemImage: "wand.and.stars") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 360)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @State private var showRestartAlert: Bool = false
    @State private var showMigrationSheet: Bool = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Library folder") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(services.watchedMusicFolder.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            Button("Move Library…") {
                                showMigrationSheet = true
                            }
                            .controlSize(.small)
                            .help("Move every tracked file under this folder into a new location. The DB and Serato library follow in one undoable batch.")

                            FolderPickerButton(
                                title: "Change Without Moving…",
                                message: "Point crate-agent at a different folder. Files stay where they are — use this if you've moved them manually."
                            ) { pickedUrl in
                                UserPreferences.watchedMusicFolder = pickedUrl
                                showRestartAlert = true
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } footer: {
                Text("crate-agent watches this folder for renames and indexes the files Serato references inside it. The recommended location is `~/Music/_DJ_Library_/` — a dedicated managed folder that sorts alongside Serato's own `_Serato_/`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Restart required", isPresented: $showRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("crate-agent will start watching the new folder the next time it launches.")
        }
        .sheet(isPresented: $showMigrationSheet) {
            MigrateLibrarySheet()
                .environmentObject(services)
                .environmentObject(services.seratoWatchdog)
        }
    }
}

// MARK: - Filename Template

struct FilenameTemplateSettingsView: View {
    @State private var template: String = UserPreferences.filenameTemplate
    @State private var saveConfirmation: String?

    var body: some View {
        Form {
            Section {
                TextField(
                    UserPreferences.defaultFilenameTemplate,
                    text: $template
                )
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            } header: {
                Text("Template")
            } footer: {
                Text("Beets-style $field syntax. Supported fields: $artist · $title · $album · $genre · $bpm · $key · $comment · $length · $label · $ext.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                LabeledContent("Sample") {
                    Text(SettingsTemplatePreviewer.preview(template: template))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Section {
                HStack {
                    Button("Reset to Default") {
                        template = UserPreferences.defaultFilenameTemplate
                    }
                    Spacer()
                    Button("Save") {
                        UserPreferences.filenameTemplate = template
                        saveConfirmation = "Saved at \(Date().formatted(date: .omitted, time: .standard))"
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(template == UserPreferences.filenameTemplate)
                }
                if let saveConfirmation {
                    Text(saveConfirmation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Auto-Tag

/// AcoustID API key entry, backed by `AcoustIDKeyStore` (Keychain-only —
/// never written to UserDefaults, SQLite, or logs). The key itself never
/// appears in any `Text` or log statement outside the `SecureField`
/// binding itself.
struct AutoTagSettingsView: View {
    @State private var apiKey: String = ""
    @State private var loadError: String?
    @State private var saveConfirmation: String?
    private let keyStore = AcoustIDKeyStore()

    var body: some View {
        Form {
            Section {
                SecureField("AcoustID API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("AcoustID API Key")
            } footer: {
                footerContent
            }

            Section {
                HStack {
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let saveConfirmation {
                        Text(saveConfirmation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
    }

    @ViewBuilder
    private var footerContent: some View {
        if apiKey.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-Tag needs a free AcoustID API key to look up matches.")
                Link("Get a key at acoustid.org", destination: URL(string: "https://acoustid.org")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text("Stored securely in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func load() {
        loadError = nil
        do {
            apiKey = try keyStore.load() ?? ""
        } catch {
            loadError = "Couldn't read the API key from the Keychain: \(error.localizedDescription)"
        }
    }

    private func save() {
        loadError = nil
        saveConfirmation = nil
        do {
            try keyStore.save(apiKey)
            saveConfirmation = "Saved at \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            loadError = "Couldn't save the API key: \(error.localizedDescription)"
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @State private var coreVersionString: String = "—"

    var body: some View {
        Form {
            Section {
                LabeledContent("Application") {
                    Text(Bundle.main.shortVersion)
                }
                LabeledContent("Rust core") {
                    Text(coreVersionString)
                        .monospaced()
                }
            } header: {
                Text("Version")
            }

            Section("Library") {
                LabeledContent("Watched folder") {
                    Text(services.watchedMusicFolder.lastPathComponent)
                        .monospaced()
                }
                if let progress = services.fingerprintProgress {
                    LabeledContent("Fingerprinting") {
                        Text("\(progress.totalDone) done · \(progress.totalPending) pending · \(progress.totalFailed) failed")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            coreVersionString = coreVersion()
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        let version = (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let build = (infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        return "\(version) (\(build))"
    }
}

/// Pure preview renderer used by the template settings tab. Kept
/// as a separate type so the rendering can be tested without
/// instantiating the view.
public enum SettingsTemplatePreviewer {

    /// Demo metadata used to populate the preview row.
    public static let sampleMetadata = SeratoMetadata(
        artist: "Aphex Twin",
        title: "Windowlicker",
        album: "Windowlicker EP",
        genre: "IDM",
        bpm: "126.000",
        musicalKey: "Am",
        comment: "demo preview",
        length: "06:07",
        label: "Warp"
    )

    public static let sampleExtension = "mp3"

    public static func preview(template: String) -> String {
        let filename = FilenameTemplateEngine.render(
            template: template,
            metadata: sampleMetadata,
            fileExtension: sampleExtension
        )
        let bucket = String(ArtistLetterNormalizer.bucketLetter(forArtist: sampleMetadata.artist))
        return "<Music>/\(bucket)/\(filename)"
    }
}
