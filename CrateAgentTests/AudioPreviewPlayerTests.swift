@testable import CrateAgent
import XCTest

@MainActor
final class AudioPreviewPlayerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudioPreviewPlayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testOnlyOnePreviewPlaysAndAStaleEndNeverStopsTheNewerOne() throws {
        let output = FakePreviewOutput()
        let player = AudioPreviewPlayer(output: output)
        let first = try audioFile("first.mp3")
        let second = try audioFile("second.mp3")

        player.toggle(fileID: 1, path: first)
        player.toggle(fileID: 2, path: second)
        XCTAssertEqual(player.playingFileID, 2)
        XCTAssertEqual(output.activePlays, [URL(fileURLWithPath: second)], "Starting a preview stops the previous one")

        output.endPlayback(at: 0, reason: nil)
        XCTAssertEqual(player.playingFileID, 2, "The first file's late end must not stop the second")
        player.toggle(fileID: 2, path: second)
        XCTAssertNil(player.playingFileID)
        XCTAssertTrue(output.activePlays.isEmpty)
    }

    func testUnreadableFilesAndPlaybackFailuresAreReportedByFilename() throws {
        let output = FakePreviewOutput()
        let player = AudioPreviewPlayer(output: output)

        player.toggle(fileID: 1, path: directory.appendingPathComponent("gone.mp3").path)
        XCTAssertNil(player.playingFileID)
        XCTAssertTrue(output.plays.isEmpty, "A missing file is never handed to the audio device")
        XCTAssertTrue(player.failure?.contains("gone.mp3") == true)

        try player.toggle(fileID: 2, path: audioFile("corrupt.mp3"))
        XCTAssertNil(player.failure)
        output.endPlayback(at: 0, reason: "Cannot decode")
        XCTAssertNil(player.playingFileID)
        XCTAssertEqual(player.failure, "Preview of corrupt.mp3 stopped: Cannot decode")
    }

    private func audioFile(_ name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0, count: 16).write(to: url)
        return url.path
    }
}

@MainActor
private final class FakePreviewOutput: AudioPreviewOutput {
    private(set) var plays: [(url: URL, onEnd: @MainActor (String?) -> Void)] = []
    private var stoppedThrough = 0

    var activePlays: [URL] {
        plays[stoppedThrough...].map(\.url)
    }

    func play(_ url: URL, onEnd: @escaping @MainActor (String?) -> Void) {
        plays.append((url, onEnd))
    }

    func stop() {
        stoppedThrough = plays.count
    }

    func endPlayback(at index: Int, reason: String?) {
        plays[index].onEnd(reason)
    }
}
