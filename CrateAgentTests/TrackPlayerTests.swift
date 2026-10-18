import AppKit
@testable import CrateAgent
import SwiftUI
import XCTest

@MainActor
final class TrackPlayerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TrackPlayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testOnlyOnePreviewPlaysAndAStaleEndNeverStopsTheNewerOne() throws {
        let output = FakeTrackPlayerOutput()
        let player = TrackPlayer(output: output)
        let first = try audioFile("first.mp3")
        let second = try audioFile("second.mp3")

        player.toggle(PlayerTrack(fileID: 1, path: first))
        player.toggle(PlayerTrack(fileID: 2, path: second))
        XCTAssertEqual(player.track?.fileID, 2)
        XCTAssertEqual(output.activePlays, [URL(fileURLWithPath: second)], "Starting a preview stops the previous one")

        output.endPlayback(at: 0, reason: nil)
        XCTAssertEqual(player.track?.fileID, 2, "The first file's late end must not stop the second")
        XCTAssertTrue(player.isPlaying(fileID: 2))
    }

    func testRowPlayStartsPartWayInThenPausesResumesSeeksAndSkipsInPlace() throws {
        let output = FakeTrackPlayerOutput()
        let player = TrackPlayer(output: output)
        let first = try PlayerTrack(fileID: 1, path: audioFile("first.mp3"), title: "First", artist: "Artist")

        player.toggle(first)
        XCTAssertEqual(output.plays.map(\.startFraction), [0.3], "Row previews skip about 30% in, past DJ intros")
        output.report(elapsed: 60, duration: 200)
        player.toggle(first)
        XCTAssertEqual(player.state, .paused(first), "A second press pauses without forgetting the track")
        player.toggle(first)
        XCTAssertEqual(player.state, .playing(first))
        player.skip(by: 10)
        player.skip(by: -100)
        player.seek(toFraction: 0.75)
        player.skip(by: 100)
        XCTAssertEqual(output.commands, ["pause", "resume", "seek 70.0", "seek 0.0", "seek 150.0", "seek 200.0"],
                       "Skips are relative to the current position and stay within the track")
        XCTAssertEqual(output.plays.count, 1, "Resuming continues the same playback instead of restarting it")

        try player.play(PlayerTrack(fileID: 2, path: audioFile("second.mp3")), from: 0)
        XCTAssertEqual(output.activePlays.count, 1, "Only one track plays app-wide")
        XCTAssertEqual(output.plays.last?.startFraction, 0, "An explicit play starts where asked")
    }

    func testUnreadableFilesAndPlaybackFailuresAreReportedByFilename() throws {
        let output = FakeTrackPlayerOutput()
        let player = TrackPlayer(output: output)

        player.toggle(PlayerTrack(fileID: 1, path: directory.appendingPathComponent("gone.mp3").path))
        XCTAssertNil(player.track)
        XCTAssertTrue(output.plays.isEmpty, "A missing file is never handed to the audio device")
        XCTAssertTrue(player.failure?.contains("gone.mp3") == true)

        try player.toggle(PlayerTrack(fileID: 2, path: audioFile("corrupt.mp3")))
        XCTAssertNil(player.failure)
        output.endPlayback(at: 0, reason: "Cannot decode")
        XCTAssertNil(player.track)
        XCTAssertEqual(player.failure, "Playback of corrupt.mp3 stopped: Cannot decode")
    }

    func testSpaceTogglesThePreviewOfTheFocusedLibraryRow() async throws {
        let database = try LibraryDatabase.openWAL(at: directory.appendingPathComponent("library.sqlite"))
        let paths = try ["one.mp3", "two.mp3"].map(audioFile)
        try await database.writer.write { connection in
            for (index, path) in paths.enumerated() {
                var file = FileRecord(id: Int64(index + 1), path: path, volumeUuid: "preview-fixture", inode: Int64(index + 1), fileSize: 16, mtime: 0, title: "Track \(index + 1)")
                file.libraryMembership = .active
                file.fileAvailability = .available
                try file.insert(connection)
            }
        }
        let model = try LibraryBrowserModel(database: database)
        await model.start()
        let output = FakeTrackPlayerOutput()
        let player = TrackPlayer(output: output)
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
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))

        table.keyDown(with: space)
        XCTAssertEqual(output.plays.map(\.url), [URL(fileURLWithPath: paths[1])])
        XCTAssertTrue(player.isPlaying(fileID: 2))
        XCTAssertEqual(model.selection.summary?.total ?? 0, 0, "In Library, Space previews instead of toggling selection")
        table.keyDown(with: space)
        XCTAssertFalse(player.isPlaying(fileID: 2))
        XCTAssertEqual(output.commands, ["pause"])
    }

    private func audioFile(_ name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0, count: 16).write(to: url)
        return url.path
    }
}
