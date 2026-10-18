import AppKit
import Foundation
import UniformTypeIdentifiers

/// An application that can open a file.
struct OpenApplication: Equatable, Identifiable {
    let url: URL
    let name: String

    var id: URL {
        url
    }
}

/// Where to open a file.
enum OpenTarget: Equatable {
    case defaultApplication
    case application(OpenApplication)
    /// Ask for any application, like Finder's Open With, Other….
    case chooseApplication
}

/// Opens library files in other applications and reveals them in Finder.
/// It only hands files to the system; it never changes them, so it needs
/// no `OperationEngine` mutation and no Serato-running gate. A file is
/// handed over only after `LibraryFileAccess` confirms it is still the
/// row's recording.
@MainActor
final class FileOpener: ObservableObject {
    @Published private(set) var failure: String?

    private let workspace: FileOpeningWorkspace
    private let access: LibraryFileAccess

    init(workspace: FileOpeningWorkspace, access: LibraryFileAccess) {
        self.workspace = workspace
        self.access = access
    }

    convenience init(access: LibraryFileAccess) {
        self.init(workspace: SystemFileOpeningWorkspace(), access: access)
    }

    func defaultApplication(for path: String) -> OpenApplication? {
        workspace.defaultApplicationURL(toOpen: URL(fileURLWithPath: path)).map(Self.application(at:))
    }

    /// Every other application that can open the file, by name.
    func otherApplications(for path: String) -> [OpenApplication] {
        let defaultURL = workspace.defaultApplicationURL(toOpen: URL(fileURLWithPath: path))?.standardizedFileURL
        var seen = Set<URL>()
        return workspace.applicationURLs(toOpen: URL(fileURLWithPath: path))
            .map(\.standardizedFileURL)
            .filter { url in url != defaultURL && seen.insert(url).inserted }
            .map(Self.application(at:))
            .sorted { first, second in first.name.localizedStandardCompare(second.name) == .orderedAscending }
    }

    func open(fileID: Int64, with target: OpenTarget = .defaultApplication) async {
        failure = nil
        var chosen: OpenApplication?
        if target == .chooseApplication {
            guard let url = await workspace.chooseApplication() else { return }
            chosen = Self.application(at: url)
        }
        guard let record = await verifiedRecord(fileID: fileID, verb: FileOpenerMessages.openVerb) else { return }
        let filename = (record.path as NSString).lastPathComponent
        let application: OpenApplication? = switch target {
        case .defaultApplication: defaultApplication(for: record.path)
        case let .application(application): application
        case .chooseApplication: chosen
        }
        guard let application else {
            failure = FileOpenerMessages.noApplication(filename)
            return
        }
        do {
            try await workspace.open(URL(fileURLWithPath: record.path), withApplicationAt: application.url)
        } catch {
            failure = FileOpenerMessages.openFailed(filename, application: application.name, reason: error.localizedDescription)
        }
    }

    func reveal(fileID: Int64) async {
        failure = nil
        guard let record = await verifiedRecord(fileID: fileID, verb: FileOpenerMessages.revealVerb) else { return }
        workspace.reveal(URL(fileURLWithPath: record.path))
    }

    /// Reveals a path whose identity the caller has already verified, such
    /// as a Serato library entry that is not a library row.
    func reveal(verifiedPath path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            failure = FileOpenerMessages.cannot(FileOpenerMessages.revealVerb, (path as NSString).lastPathComponent, LibraryFileAccessMessages.missing)
            return
        }
        failure = nil
        workspace.reveal(URL(fileURLWithPath: path))
    }

    func dismissFailure() {
        failure = nil
    }

    private func verifiedRecord(fileID: Int64, verb: String) async -> FileRecord? {
        do {
            return try await access.verifiedRecord(fileID: fileID)
        } catch let error as LibraryFileAccessError {
            failure = FileOpenerMessages.cannot(verb, error.filename, error.detail)
        } catch {
            failure = FileOpenerMessages.cannot(verb, FileOpenerMessages.theFile, error.localizedDescription)
        }
        return nil
    }

    private static func application(at url: URL) -> OpenApplication {
        OpenApplication(url: url, name: (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension)
    }
}

/// The system boundary for opening and revealing files.
@MainActor
protocol FileOpeningWorkspace {
    func defaultApplicationURL(toOpen url: URL) -> URL?
    func applicationURLs(toOpen url: URL) -> [URL]
    func open(_ url: URL, withApplicationAt application: URL) async throws
    func reveal(_ url: URL)
    /// Asks the user for an application; nil when they cancel.
    func chooseApplication() async -> URL?
}

@MainActor
struct SystemFileOpeningWorkspace: FileOpeningWorkspace {
    func defaultApplicationURL(toOpen url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    func applicationURLs(toOpen url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    func open(_ url: URL, withApplicationAt application: URL) async throws {
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func chooseApplication() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = FileOpenerMessages.chooseApplication
        panel.prompt = FileOpenerMessages.openVerb.capitalized
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        return await panel.begin() == .OK ? panel.url : nil
    }
}
