import AppKit
@testable import CrateAgent
import Foundation
import XCTest

@MainActor
final class SeratoMembershipSnapshotTests: XCTestCase {
    func testCachedAuthorizationDoesNotParseAndExpiresAfterSourceOrLifecycleChange() async throws {
        let center = NotificationCenter()
        let watchdog = observingWatchdog(center)
        let locator = try fixture(emptyLibrary)
        let initial = try await SeratoMembershipSnapshotReader(locator: locator, watchdog: watchdog).read()
        let reader = SeratoMembershipSnapshotReader(locator: locator, watchdog: watchdog, parse: { _ in
            XCTFail("Cached authorization parsed V2")
            return []
        })
        let authorization = try await reader.authorizeCachedSource(libraryID: initial.libraryID, source: initial.source)
        try authorization.check()
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil, userInfo: [Self.notificationBundleIdentifierKey: "com.serato.dj"])
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil, userInfo: [Self.notificationBundleIdentifierKey: "com.serato.dj"])
        XCTAssertThrowsError(try authorization.check())
        let next = try await reader.authorizeCachedSource(libraryID: initial.libraryID, source: initial.source)
        try SeratoTestEncoding.library(paths: ["/different.wav"]).write(to: locator.databaseV2Url)
        XCTAssertThrowsError(try next.check())
    }

    private static let notificationBundleIdentifierKey = "testBundleIdentifier"

    private func observingWatchdog(_ center: NotificationCenter) -> SeratoWatchdog {
        let watchdog = SeratoWatchdog(
            workspaceNotificationCenter: center,
            notificationApplicationProvider: { notification in
                guard let bundleIdentifier = notification.userInfo?[Self.notificationBundleIdentifierKey] as? String else { return nil }
                return SeratoWatchdog.ApplicationIdentity(bundleIdentifier: bundleIdentifier, processIdentifier: 1)
            },
            runningBundleIdentifiersProvider: { [] }
        )
        watchdog.startObservingWorkspace()
        return watchdog
    }

    func testDelayedSeratoLifecycleNotificationsInvalidateSnapshot() async throws {
        let center = NotificationCenter()
        let watchdog = observingWatchdog(center)
        let locator = try fixture(emptyLibrary)
        let reader = SeratoMembershipSnapshotReader(locator: locator, watchdog: watchdog, afterParsing: {
            await MainActor.run {
                center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil, userInfo: [Self.notificationBundleIdentifierKey: "com.serato.dj"])
                center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil, userInfo: [Self.notificationBundleIdentifierKey: "com.serato.dj"])
            }
        })
        await expectFailure(.seratoRunning, reader: reader)
        XCTAssertFalse(watchdog.isSeratoRunning)
        XCTAssertEqual(watchdog.stateRevision, 2)
    }

    func testUnrelatedLifecycleNotificationsDoNotInvalidateSnapshot() async throws {
        let center = NotificationCenter()
        let watchdog = observingWatchdog(center)
        let locator = try fixture(emptyLibrary)
        let reader = SeratoMembershipSnapshotReader(locator: locator, watchdog: watchdog, afterParsing: {
            await MainActor.run {
                center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil, userInfo: [Self.notificationBundleIdentifierKey: "com.example.other"])
                center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil, userInfo: [Self.notificationBundleIdentifierKey: "com.example.other"])
            }
        })
        _ = try await reader.read()
        XCTAssertEqual(watchdog.stateRevision, 0)
    }

    func testDatabaseFileSymlinkIsUnsupported() async throws {
        let target = try fixture(emptyLibrary)
        let locator = try fixture()
        try FileManager.default.createSymbolicLink(at: locator.databaseV2Url, withDestinationURL: target.databaseV2Url)
        await expectFailure(.unsupportedSource, reader: SeratoMembershipSnapshotReader(locator: locator, watchdog: SeratoWatchdog { [] }))
    }

    func testDatabaseReplacedWithSymlinkDuringReadIsUnsupported() async throws {
        let target = try fixture(emptyLibrary)
        let locator = try fixture(emptyLibrary)
        let reader = SeratoMembershipSnapshotReader(locator: locator, watchdog: SeratoWatchdog { [] }, afterParsing: {
            try FileManager.default.removeItem(at: locator.databaseV2Url)
            try FileManager.default.createSymbolicLink(at: locator.databaseV2Url, withDestinationURL: target.databaseV2Url)
        })
        await expectFailure(.unsupportedSource, reader: reader)
    }

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
        SeratoTestEncoding.library(paths: [])
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
        for (payload, expected) in [(nil, SeratoMembershipSnapshotError.sourceMissing), (Data(), .malformedSource), (Data("otrk".utf8), .malformedSource)] {
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
