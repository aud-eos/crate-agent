@testable import CrateAgent
import XCTest

/// Each test uses a unique Keychain service string so runs are isolated
/// from each other and from the real `com.crateagent.acoustid` service,
/// and `tearDown` deletes whatever it created so nothing lingers in the
/// login keychain across test runs.
final class AcoustIDKeyStoreTests: XCTestCase {
    private var store: AcoustIDKeyStore!

    override func setUp() {
        super.setUp()
        store = AcoustIDKeyStore(service: "com.crateagent.acoustid.test.\(UUID())")
    }

    override func tearDown() {
        try? store.delete()
        store = nil
        super.tearDown()
    }

    func testSaveLoadDelete() throws {
        try store.save("secret-key")
        XCTAssertEqual(try store.load(), "secret-key")
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testLoadWithNothingSavedReturnsNil() throws {
        XCTAssertNil(try store.load())
    }

    func testSaveTwiceUpsertsToLatestValue() throws {
        try store.save("first-key")
        try store.save("second-key")
        XCTAssertEqual(try store.load(), "second-key")
    }

    func testDeleteWithNothingSavedDoesNotThrow() throws {
        try store.delete()
        XCTAssertNil(try store.load())
    }
}
