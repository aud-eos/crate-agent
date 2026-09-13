@testable import CrateAgent
import XCTest

final class LookupCacheTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LookupCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    func testCacheRoundTrips() {
        let cache = LookupCache(directory: tempDirectory)
        cache.store(Data("x".utf8), forKey: "fp:abc")
        XCTAssertEqual(cache.data(forKey: "fp:abc"), Data("x".utf8))
        XCTAssertNil(cache.data(forKey: "fp:missing"))
    }

    func testDiskCachePersistsAcrossInstances() {
        let firstInstance = LookupCache(directory: tempDirectory)
        firstInstance.store(Data("persisted".utf8), forKey: "mb:xyz")

        let secondInstance = LookupCache(directory: tempDirectory)
        XCTAssertEqual(secondInstance.data(forKey: "mb:xyz"), Data("persisted".utf8))
    }

    func testDiskCacheCreatesMissingDirectory() {
        let nestedDirectory = tempDirectory.appendingPathComponent("nested/does/not/exist", isDirectory: true)
        let cache = LookupCache(directory: nestedDirectory)
        cache.store(Data("value".utf8), forKey: "key")
        XCTAssertEqual(cache.data(forKey: "key"), Data("value".utf8))
    }

    func testMemoryCacheRoundTripsAndDoesNotTouchDisk() {
        let cache = LookupCache.memory()
        cache.store(Data("y".utf8), forKey: "acoustid:def")
        XCTAssertEqual(cache.data(forKey: "acoustid:def"), Data("y".utf8))
        XCTAssertNil(cache.data(forKey: "acoustid:missing"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path))
    }

    func testDistinctKeysDoNotCollideOnDisk() {
        let cache = LookupCache(directory: tempDirectory)
        cache.store(Data("first".utf8), forKey: "fp:one")
        cache.store(Data("second".utf8), forKey: "fp:two")
        XCTAssertEqual(cache.data(forKey: "fp:one"), Data("first".utf8))
        XCTAssertEqual(cache.data(forKey: "fp:two"), Data("second".utf8))
    }
}
