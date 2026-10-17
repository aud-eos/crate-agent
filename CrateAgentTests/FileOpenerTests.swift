import AppKit
@testable import CrateAgent
import SwiftUI
import XCTest

@MainActor
final class FileOpenerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileOpenerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testOpensInTheDefaultOrAChosenApplicationAndReportsFailures() async throws {
        let workspace = FakeFileOpeningWorkspace()
        workspace.defaultApplication = URL(fileURLWithPath: "/Applications/Music.app")
        workspace.applications = ["VLC", "Music", "Audacity", "VLC"].map { name in URL(fileURLWithPath: "/Applications/\(name).app") }
        let opener = FileOpener(workspace: workspace)
        let path = try audioFile("song.mp3")

        XCTAssertEqual(opener.defaultApplication(for: path)?.name, "Music")
        let others = opener.otherApplications(for: path)
        XCTAssertEqual(others.map(\.name), ["Audacity", "VLC"], "Open With lists each other application once, by name")
        await opener.open(path)
        XCTAssertEqual(workspace.opened.map(\.application.lastPathComponent), ["Music.app"])
        XCTAssertNil(opener.failure)

        workspace.openError = CocoaError(.fileReadNoPermission)
        await opener.open(path, with: others[1])
        let failure = try XCTUnwrap(opener.failure)
        XCTAssertTrue(failure.contains("song.mp3") && failure.contains("VLC"), failure)
    }

    func testMissingFilesAreNeverHandedToTheSystem() async {
        let workspace = FakeFileOpeningWorkspace()
        workspace.defaultApplication = URL(fileURLWithPath: "/Applications/Music.app")
        let opener = FileOpener(workspace: workspace)
        let missing = directory.appendingPathComponent("gone.mp3").path

        await opener.open(missing)
        XCTAssertEqual(opener.failure, "Can't open gone.mp3: the file is missing.")
        opener.dismissFailure()
        opener.reveal(missing)
        XCTAssertEqual(opener.failure, "Can't open gone.mp3: the file is missing.")
        XCTAssertTrue(workspace.opened.isEmpty)
        XCTAssertTrue(workspace.revealed.isEmpty)
    }

    func testCommandOOpensTheFocusedLibraryRowInItsDefaultApplication() async throws {
        let database = try LibraryDatabase.openWAL(at: directory.appendingPathComponent("library.sqlite"))
        let paths = try ["one.mp3", "two.mp3"].map(audioFile)
        try await database.writer.write { connection in
            for (index, path) in paths.enumerated() {
                var file = FileRecord(id: Int64(index + 1), path: path, volumeUuid: "open-fixture", inode: Int64(index + 1), fileSize: 16, mtime: 0, title: "Track \(index + 1)")
                file.libraryMembership = .active
                file.fileAvailability = .available
                try file.insert(connection)
            }
        }
        let model = try LibraryBrowserModel(database: database)
        await model.start()
        var actions: [(Int64, LibraryBrowserAction)] = []
        let opener = FileOpener(workspace: FakeFileOpeningWorkspace())
        let host = NSHostingView(rootView: LibraryPagedContent(model: model, density: .comfortable, showsFilenames: false, opener: opener,
                                                               onAction: { identifier, action in actions.append((identifier, action)) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { model.stop(); window.close() }
        func findTable(_ view: NSView) -> PagedNSTableView? {
            (view as? PagedNSTableView) ?? view.subviews.lazy.compactMap(findTable).first
        }
        await pagingEventually { findTable(host)?.numberOfRows == 2 && model.results.row(at: 1) != nil }
        let table = try XCTUnwrap(findTable(host))
        window.makeFirstResponder(table)
        table.focusRow(1, modifiers: [], selecting: false)
        let commandO = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31))

        XCTAssertTrue(table.performKeyEquivalent(with: commandO))
        XCTAssertEqual(actions.map(\.0), [2])
        XCTAssertEqual(actions.map(\.1), [.open(nil)])
    }

    private func audioFile(_ name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0, count: 16).write(to: url)
        return url.path
    }
}
