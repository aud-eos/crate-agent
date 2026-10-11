import CoreServices
@testable import CrateAgent
import XCTest

final class UserPreferencesTests: XCTestCase {
    private static let testPathA = "/test/path/A-\(UUID().uuidString)"
    private static let testPathB = "/test/path/B-\(UUID().uuidString)"

    private var fixture: IsolatedPreferences!

    override func setUpWithError() throws {
        fixture = try IsolatedPreferences()
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    func testFSEventIdStorageRoundTripsForOneWatchedPath() {
        fixture.preferences.setLastFSEventId(
            FSEventStreamEventId(42_424_242),
            forWatchedPath: Self.testPathA
        )
        let readBack = fixture.preferences.lastFSEventId(forWatchedPath: Self.testPathA)
        XCTAssertEqual(readBack, FSEventStreamEventId(42_424_242))
    }

    func testFSEventIdStorageIsKeyedSeparatelyPerPath() {
        fixture.preferences.setLastFSEventId(
            FSEventStreamEventId(111),
            forWatchedPath: Self.testPathA
        )
        fixture.preferences.setLastFSEventId(
            FSEventStreamEventId(222),
            forWatchedPath: Self.testPathB
        )
        XCTAssertEqual(
            fixture.preferences.lastFSEventId(forWatchedPath: Self.testPathA),
            FSEventStreamEventId(111),
            "writing path B must not clobber path A"
        )
        XCTAssertEqual(
            fixture.preferences.lastFSEventId(forWatchedPath: Self.testPathB),
            FSEventStreamEventId(222)
        )
    }

    func testFSEventIdReturnsNilForUnseenPath() {
        XCTAssertNil(
            fixture.preferences.lastFSEventId(forWatchedPath: "/never-stored-\(UUID().uuidString)")
        )
    }
}

final class UserPreferencesFilenameTemplateTests: XCTestCase {
    private var fixture: IsolatedPreferences!

    override func setUpWithError() throws {
        fixture = try IsolatedPreferences()
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    func testFilenameTemplateDefaultsWhenUnset() {
        XCTAssertEqual(
            fixture.preferences.filenameTemplate,
            UserPreferences.defaultFilenameTemplate
        )
    }

    func testFilenameTemplateRoundTripsSavedValue() {
        fixture.preferences.filenameTemplate = "$artist · $title.$ext"
        XCTAssertEqual(fixture.preferences.filenameTemplate, "$artist · $title.$ext")
    }
}
