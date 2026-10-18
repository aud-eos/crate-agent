import AppKit
@testable import CrateAgent
import SwiftUI
import XCTest

@MainActor
final class FileOpenerTests: XCTestCase {
    private var fixture: LibraryFileFixture!

    override func setUp() async throws {
        fixture = try LibraryFileFixture()
    }

    override func tearDown() async throws {
        try fixture.remove()
    }

    func testOpensInTheDefaultAChosenOrAPickedApplicationAndReportsFailures() async throws {
        let workspace = FakeFileOpeningWorkspace()
        workspace.defaultApplication = URL(fileURLWithPath: "/Applications/Music.app")
        workspace.applications = ["VLC", "Music", "Audacity", "VLC"].map { name in URL(fileURLWithPath: "/Applications/\(name).app") }
        let opener = FileOpener(workspace: workspace, access: fixture.access)
        let path = try await fixture.addFile("song.mp3", id: 1)

        XCTAssertEqual(opener.defaultApplication(for: path)?.name, "Music")
        let others = opener.otherApplications(for: path)
        XCTAssertEqual(others.map(\.name), ["Audacity", "VLC"], "Open With lists each other application once, by name")
        await opener.open(fileID: 1)
        await opener.open(fileID: 1, with: .chooseApplication)
        workspace.chosenApplication = URL(fileURLWithPath: "/Applications/Swinsian.app")
        await opener.open(fileID: 1, with: .chooseApplication)
        XCTAssertEqual(workspace.opened.map(\.application.lastPathComponent), ["Music.app", "Swinsian.app"], "Cancelling Other… opens nothing")
        XCTAssertNil(opener.failure)

        workspace.defaultApplication = nil
        await opener.open(fileID: 1)
        XCTAssertEqual(opener.failure, FileOpenerMessages.noApplication("song.mp3"))
        workspace.openError = CocoaError(.fileReadNoPermission)
        await opener.open(fileID: 1, with: .application(others[1]))
        let failure = try XCTUnwrap(opener.failure)
        XCTAssertTrue(failure.contains("song.mp3") && failure.contains("VLC"), failure)
    }

    func testMissingFilesAreNeverHandedToTheSystem() async throws {
        let workspace = FakeFileOpeningWorkspace()
        workspace.defaultApplication = URL(fileURLWithPath: "/Applications/Music.app")
        let opener = FileOpener(workspace: workspace, access: fixture.access)
        let gone = try await fixture.addFile("gone.mp3", id: 1)
        try FileManager.default.removeItem(atPath: gone)
        try await fixture.addFile("flagged.mp3", id: 2, availability: .missing)

        await opener.open(fileID: 1)
        XCTAssertEqual(opener.failure, "Can't open gone.mp3: the file is missing.")
        opener.dismissFailure()
        await opener.reveal(fileID: 1)
        XCTAssertEqual(opener.failure, "Can't reveal gone.mp3: the file is missing.")
        await opener.open(fileID: 2)
        XCTAssertEqual(opener.failure, "Can't open flagged.mp3: the file is missing.", "A Missing row is refused even when its path holds a file")
        opener.reveal(verifiedPath: gone)
        XCTAssertEqual(opener.failure, "Can't reveal gone.mp3: the file is missing.")
        XCTAssertTrue(workspace.opened.isEmpty)
        XCTAssertTrue(workspace.revealed.isEmpty)
    }

    func testAFileReplacedAtTheRowsPathIsNeverOpenedRevealedOrPlayed() async throws {
        let workspace = FakeFileOpeningWorkspace()
        workspace.defaultApplication = URL(fileURLWithPath: "/Applications/Music.app")
        let opener = FileOpener(workspace: workspace, access: fixture.access)
        let output = FakeTrackPlayerOutput()
        let player = TrackPlayer(output: output, access: fixture.access)
        let path = try await fixture.addFile("track.mp3", id: 1)
        _ = try fixture.writeAudio("track.mp3", byte: 0xFF)

        await opener.open(fileID: 1)
        XCTAssertEqual(opener.failure, FileOpenerMessages.cannot(FileOpenerMessages.openVerb, "track.mp3", LibraryFileAccessMessages.replaced))
        await opener.reveal(fileID: 1)
        await player.toggle(PlayerTrack(fileID: 1, path: path))
        XCTAssertTrue(workspace.opened.isEmpty)
        XCTAssertTrue(workspace.revealed.isEmpty)
        XCTAssertTrue(output.plays.isEmpty)
        XCTAssertEqual(player.failure, TrackPlayerMessages.cannotPlay("track.mp3", detail: LibraryFileAccessMessages.replaced))
    }

    func testATagEditThatKeepsTheAudioIsStillOpenedButNewAudioAtThePathIsNot() async throws {
        let workspace = FakeFileOpeningWorkspace()
        workspace.defaultApplication = URL(fileURLWithPath: "/Applications/Music.app")
        let opener = FileOpener(workspace: workspace, access: fixture.access)
        let path = try await fixture.addFile("track.wav", id: 1, bytes: TestAudio.wav(frequency: 440, title: "Before"))
        await opener.reveal(fileID: 1)
        let database = fixture.database
        await pagingEventually {
            await (try? database.writer.read { connection in
                try Bool.fetchOne(connection, sql: "SELECT EXISTS(SELECT 1 FROM file_audio_digests WHERE file_id = 1 AND pcm_sha256 IS NOT NULL)")
            }) == true
        }

        _ = try fixture.writeAudio("track.wav", bytes: TestAudio.wav(frequency: 440, title: "Retagged by Serato"))
        await opener.open(fileID: 1)
        XCTAssertNil(opener.failure, "Serato writing tags into the file leaves its audio, so it is still the row's recording")
        XCTAssertEqual(workspace.opened.map(\.file.path), [path])

        _ = try fixture.writeAudio("track.wav", bytes: TestAudio.wav(frequency: 660, title: "Before"))
        await opener.open(fileID: 1)
        XCTAssertEqual(opener.failure, FileOpenerMessages.cannot(FileOpenerMessages.openVerb, "track.wav", LibraryFileAccessMessages.replaced))
        XCTAssertEqual(workspace.opened.count, 1, "Different audio at the path is never handed over")
    }

    func testCommandOOpensTheFocusedLibraryRowInItsDefaultApplication() async throws {
        for (index, name) in ["one.mp3", "two.mp3"].enumerated() {
            try await fixture.addFile(name, id: Int64(index + 1), title: "Track \(index + 1)")
        }
        let database = fixture.database
        let model = try LibraryBrowserModel(database: database)
        await model.start()
        var actions: [(Int64, LibraryBrowserAction)] = []
        let opener = FileOpener(workspace: FakeFileOpeningWorkspace(), access: fixture.access)
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

        let commandOWithCapsLock = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .capsLock], timestamp: 0, windowNumber: window.windowNumber,
                                                                  context: nil, characters: "O", charactersIgnoringModifiers: "O", isARepeat: false, keyCode: 31))

        XCTAssertTrue(table.performKeyEquivalent(with: commandO))
        XCTAssertTrue(table.performKeyEquivalent(with: commandOWithCapsLock), "Caps Lock does not change the shortcut")
        XCTAssertEqual(actions.map(\.0), [2, 2])
        XCTAssertEqual(actions.map(\.1), [.open(.defaultApplication), .open(.defaultApplication)])
    }
}
