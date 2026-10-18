import AppKit
@testable import CrateAgent
import SwiftUI
import XCTest

@MainActor
final class TrackPlayerTests: XCTestCase {
    private var fixture: LibraryFileFixture!
    private var output: FakeTrackPlayerOutput!
    private var player: TrackPlayer!

    override func setUp() async throws {
        fixture = try LibraryFileFixture()
        output = FakeTrackPlayerOutput()
        player = TrackPlayer(output: output, access: fixture.access)
    }

    override func tearDown() async throws {
        try fixture.remove()
    }

    func testOnlyOnePreviewPlaysAndAStaleEndNeverStopsTheNewerOne() async throws {
        let first = try await fixture.addFile("first.mp3", id: 1)
        let second = try await fixture.addFile("second.mp3", id: 2)

        await player.toggle(PlayerTrack(fileID: 1, path: first))
        await player.toggle(PlayerTrack(fileID: 2, path: second))
        XCTAssertEqual(player.track?.fileID, 2)
        XCTAssertEqual(output.activePlays, [URL(fileURLWithPath: second)], "Starting a preview stops the previous one")

        output.endPlayback(at: 0, reason: nil)
        XCTAssertEqual(player.track?.fileID, 2, "The first file's late end must not stop the second")
        XCTAssertTrue(player.isPlaying(fileID: 2))
    }

    func testRowPlayStartsPartWayInThenPausesResumesSeeksAndSkipsInPlace() async throws {
        let first = try await PlayerTrack(fileID: 1, path: fixture.addFile("first.mp3", id: 1), title: "First", artist: "Artist")
        let second = try await fixture.addFile("second.mp3", id: 2)

        await player.toggle(first)
        XCTAssertEqual(output.plays.map(\.startFraction), [0.3], "Row previews skip about 30% in, past DJ intros")
        output.report(elapsed: 60, duration: 200)
        await player.toggle(first)
        XCTAssertEqual(player.state, .paused(first), "A second press pauses without forgetting the track")
        await player.toggle(first)
        XCTAssertEqual(player.state, .playing(first))
        player.skip(by: 10)
        player.skip(by: -100)
        player.seek(toFraction: 0.75)
        player.skip(by: 100)
        XCTAssertEqual(output.commands, ["pause", "resume", "seek 70.0", "seek 0.0", "seek 150.0", "seek 200.0"],
                       "Skips are relative to the current position and stay within the track")
        XCTAssertEqual(output.plays.count, 1, "Resuming continues the same playback instead of restarting it")

        await player.play(PlayerTrack(fileID: 2, path: second), from: 0)
        XCTAssertEqual(output.activePlays.count, 1, "Only one track plays app-wide")
        XCTAssertEqual(output.plays.last?.startFraction, 0, "An explicit play starts where asked")
    }

    func testASecondPressWhileTheFileIsStillBeingCheckedCancelsThePlay() async throws {
        let track = try await PlayerTrack(fileID: 1, path: fixture.addFile("track.mp3", id: 1))

        let first = Task { await player.toggle(track) }
        let second = Task { await player.toggle(track) }
        await first.value
        await second.value

        XCTAssertTrue(output.plays.isEmpty, "The second press cancels the first instead of starting playback")
        XCTAssertNil(player.track)
    }

    func testUnavailableFilesAndPlaybackFailuresAreReportedByFilenameUntilDismissed() async throws {
        let gone = try await fixture.addFile("gone.mp3", id: 1)
        try FileManager.default.removeItem(atPath: gone)
        let corrupt = try await fixture.addFile("corrupt.mp3", id: 2)

        await player.toggle(PlayerTrack(fileID: 1, path: gone))
        XCTAssertNil(player.track)
        XCTAssertTrue(output.plays.isEmpty, "A missing file is never handed to the audio device")
        XCTAssertEqual(player.failure, "Can't play gone.mp3: the file is missing.")
        player.dismissFailure()
        XCTAssertNil(player.failure)

        await player.toggle(PlayerTrack(fileID: 2, path: corrupt))
        XCTAssertNil(player.failure)
        output.endPlayback(at: 0, reason: "Cannot decode")
        XCTAssertNil(player.track)
        XCTAssertEqual(player.failure, "Playback of corrupt.mp3 stopped: Cannot decode")
    }

    func testSpaceTogglesThePreviewOfTheFocusedLibraryRowAndShiftSpaceTogglesItsSelection() async throws {
        let paths = try await [fixture.addFile("one.mp3", id: 1, title: "Track 1"), fixture.addFile("two.mp3", id: 2, title: "Track 2")]
        let model = try LibraryBrowserModel(database: fixture.database)
        await model.start()
        let host = NSHostingView(rootView: LibraryPagedContent(model: model, density: .comfortable, showsFilenames: false, player: player, onAction: { _, _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { model.stop(); window.close() }
        func findTable(_ view: NSView) -> PagedNSTableView? {
            (view as? PagedNSTableView) ?? view.subviews.lazy.compactMap(findTable).first
        }
        await pagingEventually { findTable(host)?.numberOfRows == 2 && model.results.row(at: 1) != nil }
        let table = try XCTUnwrap(findTable(host))
        table.focusRow(1, modifiers: [], selecting: false)
        func space(_ modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                           characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeating, keyCode: 49))
        }

        try table.keyDown(with: space())
        await pagingEventually { !self.output.plays.isEmpty }
        try table.keyDown(with: space(repeating: true))
        XCTAssertEqual(output.plays.map(\.url), [URL(fileURLWithPath: paths[1])])
        XCTAssertEqual(model.selection.summary?.total ?? 0, 0, "In Library, Space previews instead of toggling selection")
        try table.keyDown(with: space())
        await pagingEventually { !self.player.isPlaying(fileID: 2) }
        XCTAssertEqual(output.commands, ["pause"], "Only the second, unrepeated Space toggled playback")

        try table.keyDown(with: space(.shift))
        await pagingEventually { model.selection.summary?.total == 1 }
        XCTAssertEqual(model.selection.summary?.total, 1, "Shift-Space selects the focused row")
        XCTAssertEqual(output.commands, ["pause"], "Shift-Space leaves playback alone")
    }
}
