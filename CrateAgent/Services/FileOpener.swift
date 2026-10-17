import AppKit
import Foundation

/// An application that can open a file.
struct OpenApplication: Equatable, Identifiable {
    let url: URL
    let name: String

    var id: URL {
        url
    }
}

/// Opens library files in other applications and reveals them in Finder.
/// It only hands files to the system; it never changes them, so it needs
/// no `OperationEngine` mutation and no Serato-running gate.
@MainActor
final class FileOpener: ObservableObject {
    @Published private(set) var failure: String?

    private let workspace: FileOpeningWorkspace

    init(workspace: FileOpeningWorkspace) {
        self.workspace = workspace
    }

    convenience init() {
        self.init(workspace: SystemFileOpeningWorkspace())
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

    /// Opens the file in `application`, or in its default application when nil.
    func open(_ path: String, with application: OpenApplication? = nil) async {
        let filename = (path as NSString).lastPathComponent
        guard FileManager.default.fileExists(atPath: path) else {
            failure = FileOpenerMessages.missing(filename)
            return
        }
        guard let target = application ?? defaultApplication(for: path) else {
            failure = FileOpenerMessages.noApplication(filename)
            return
        }
        failure = nil
        do {
            try await workspace.open(URL(fileURLWithPath: path), withApplicationAt: target.url)
        } catch {
            failure = FileOpenerMessages.openFailed(filename, application: target.name, reason: error.localizedDescription)
        }
    }

    func reveal(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            failure = FileOpenerMessages.missing((path as NSString).lastPathComponent)
            return
        }
        failure = nil
        workspace.reveal(URL(fileURLWithPath: path))
    }

    func dismissFailure() {
        failure = nil
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
}
