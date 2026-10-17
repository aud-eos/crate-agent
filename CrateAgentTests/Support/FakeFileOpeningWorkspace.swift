@testable import CrateAgent
import Foundation

/// Records what the opener asks of the system; opens and reveals nothing.
@MainActor
final class FakeFileOpeningWorkspace: FileOpeningWorkspace {
    var defaultApplication: URL?
    var applications: [URL] = []
    var openError: Error?
    private(set) var opened: [(file: URL, application: URL)] = []
    private(set) var revealed: [URL] = []

    func defaultApplicationURL(toOpen _: URL) -> URL? {
        defaultApplication
    }

    func applicationURLs(toOpen _: URL) -> [URL] {
        applications
    }

    func open(_ url: URL, withApplicationAt application: URL) async throws {
        if let openError {
            throw openError
        }
        opened.append((url, application))
    }

    func reveal(_ url: URL) {
        revealed.append(url)
    }
}
