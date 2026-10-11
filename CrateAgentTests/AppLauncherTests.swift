@testable import CrateAgent
import Foundation
import XCTest

@MainActor
final class AppLauncherTests: XCTestCase {
    private struct Services {
        let folder: URL
    }

    func testInitialStateNeedsOnboardingWithoutStartingServices() throws {
        let fixture = try IsolatedPreferences()
        let launcher = ApplicationLauncher<Services>(preferences: fixture.preferences) { folder in
            XCTFail("Services must wait for a folder choice")
            return Services(folder: folder)
        }
        guard case .needsOnboarding = launcher.state else {
            return XCTFail("Expected onboarding")
        }
    }

    func testConfiguredLaunchUsesInjectedFolderAndServices() throws {
        let fixture = try IsolatedPreferences()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        fixture.preferences.watchedMusicFolder = folder
        let launcher = ApplicationLauncher(preferences: fixture.preferences, makeServices: Services.init)
        guard case let .ready(services) = launcher.state else {
            return XCTFail("Expected configured launch to be ready")
        }
        XCTAssertEqual(services.folder, folder)
    }

    func testOnboardingPersistsFolderBeforeStartingServices() throws {
        let fixture = try IsolatedPreferences()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let launcher = ApplicationLauncher(preferences: fixture.preferences) { selectedFolder in
            XCTAssertEqual(fixture.preferences.watchedMusicFolder, selectedFolder)
            return Services(folder: selectedFolder)
        }
        launcher.completeOnboarding(withFolder: folder)
        guard case let .ready(services) = launcher.state else {
            return XCTFail("Expected completed onboarding to be ready")
        }
        XCTAssertEqual(services.folder, folder)
        XCTAssertEqual(fixture.preferences.watchedMusicFolder, folder)
    }

    func testHostedLauncherIsInactiveAndRejectsProductionResources() throws {
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, "com.crateagent.CrateAgent",
                          "Run hosted tests with the Test configuration to isolate AppKit preferences")
        let launcher = AppLauncher()
        guard case .inactive = launcher.state else {
            return XCTFail("XCTest host must not enter onboarding or start live services")
        }
        XCTAssertThrowsError(try LibraryDatabase.openDefault())
        XCTAssertThrowsError(try SeratoLibraryLocator.defaultLocation())
        XCTAssertThrowsError(try PreferencesStore.live())
        XCTAssertThrowsError(try AppServices(
            watchedMusicFolder: FileManager.default.temporaryDirectory,
            database: LibraryDatabase.openInMemory()
        ))
    }
}
