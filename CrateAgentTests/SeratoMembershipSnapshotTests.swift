@testable import CrateAgent
import Foundation
import XCTest

@MainActor
final class SeratoMembershipSnapshotTests: XCTestCase {
    private func fixture(_ payload: Data? = nil) throws -> SeratoLibraryLocator {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        if let payload {
            try payload.write(to: directory.appendingPathComponent("database V2"))
        }
        return SeratoLibraryLocator(seratoDirectory: directory)
    }

    private var emptyLibrary: Data {
        let payload = "2.0/Serato Scratch LIVE Database".data(using: .utf16BigEndian)!
        var length = UInt32(payload.count).bigEndian
        return Data("vrsn".utf8) + withUnsafeBytes(of: &length) { Data($0) } + payload
    }

    func testValidMembershipComesFromEncodedTrack() async throws {
        let path = "Music/example.mp3"
        let payload = try XCTUnwrap(path.data(using: .utf16BigEndian))
        var pathLength = UInt32(payload.count).bigEndian
        let nested = Data("pfil".utf8) + withUnsafeBytes(of: &pathLength) { Data($0) } + payload
        var nestedLength = UInt32(nested.count).bigEndian
        let bytes = emptyLibrary + Data("otrk".utf8) + withUnsafeBytes(of: &nestedLength) { Data($0) } + nested
        let locator = try fixture(bytes)
        let snapshot = try await SeratoMembershipSnapshotReader(locator: locator, watchdog: SeratoWatchdog { [] }).read()
        XCTAssertEqual(snapshot.records.map(\.path), [path])
    }

    func testDirectoryCannotBeAuthoritativeSource() async throws {
        let locator = try fixture()
        try FileManager.default.createDirectory(at: locator.databaseV2Url, withIntermediateDirectories: false)
        await expectFailure(.unsupportedSource, reader: SeratoMembershipSnapshotReader(locator: locator, watchdog: SeratoWatchdog { [] }))
    }

    func testUnreadableSourceIsUnavailable() async throws {
        let locator = try fixture(emptyLibrary)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locator.databaseV2Url.path)
        await expectFailure(.sourceUnavailable, reader: SeratoMembershipSnapshotReader(locator: locator, watchdog: SeratoWatchdog { [] }))
    }

    private func expectFailure(_ expected: SeratoMembershipSnapshotError, reader: SeratoMembershipSnapshotReader) async {
        do {
            _ = try await reader.read()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? SeratoMembershipSnapshotError, expected)
        }
    }

    func testValidEmptyLibraryAndGeneration() async throws {
        let locator = try fixture(emptyLibrary)
        let reader = SeratoMembershipSnapshotReader(locator: locator, watchdog: SeratoWatchdog { [] })
        let first = try await reader.read()
        let second = try await reader.read()
        XCTAssertTrue(first.records.isEmpty)
        XCTAssertEqual(first.libraryID, second.libraryID)
        XCTAssertEqual(second.generation, first.generation + 1)
    }

    func testMissingEmptyAndCorruptSources() async throws {
        for (payload, expected) in [(nil, SeratoMembershipSnapshotError.sourceUnavailable), (Data(), .malformedSource), (Data("otrk".utf8), .malformedSource)] {
            let locator = try fixture(payload)
            await expectFailure(expected, reader: SeratoMembershipSnapshotReader(locator: locator, watchdog: SeratoWatchdog { [] }))
        }
    }

    func testReplacementWithSameBytesChangesSourceObject() async throws {
        let locator = try fixture(emptyLibrary)
        let bytes = emptyLibrary
        let reader = SeratoMembershipSnapshotReader(locator: locator, watchdog: SeratoWatchdog { [] }, afterParsing: {
            try bytes.write(to: locator.databaseV2Url, options: .atomic)
        })
        await expectFailure(.sourceChanged, reader: reader)
    }

    func testSameInodeRewriteWithinSecondIsDetected() async throws {
        let locator = try fixture(emptyLibrary)
        let reader = SeratoMembershipSnapshotReader(locator: locator, watchdog: SeratoWatchdog { [] }, afterParsing: {
            let handle = try FileHandle(forWritingTo: locator.databaseV2Url)
            try handle.seek(toOffset: 10)
            try handle.write(contentsOf: Data([0, 88]))
            try handle.close()
        })
        await expectFailure(.sourceChanged, reader: reader)
    }

    func testRunningSeratoPreventsRead() async throws {
        let locator = try fixture(emptyLibrary)
        await expectFailure(.seratoRunning, reader: SeratoMembershipSnapshotReader(locator: locator, watchdog: SeratoWatchdog { ["com.serato.dj"] }))
    }

    func testSeratoStartsAndStopsDuringRead() async throws {
        let locator = try fixture(emptyLibrary)
        var running = false
        let watchdog = SeratoWatchdog { running ? ["com.serato.dj"] : [] }
        let reader = SeratoMembershipSnapshotReader(locator: locator, watchdog: watchdog, afterParsing: {
            await MainActor.run {
                running = true
                watchdog.refresh()
                running = false
                watchdog.refresh()
            }
        })
        await expectFailure(.seratoRunning, reader: reader)
    }

    func testDifferentConfiguredLibrariesHaveDifferentOwners() async throws {
        let first = try fixture(emptyLibrary)
        let second = try fixture(emptyLibrary)
        let firstSnapshot = try await SeratoMembershipSnapshotReader(locator: first, watchdog: SeratoWatchdog { [] }).read()
        let secondSnapshot = try await SeratoMembershipSnapshotReader(locator: second, watchdog: SeratoWatchdog { [] }).read()
        XCTAssertNotEqual(firstSnapshot.libraryID, secondSnapshot.libraryID)
    }
}
