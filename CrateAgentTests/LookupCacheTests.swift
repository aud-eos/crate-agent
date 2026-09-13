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

    func testUnreadablePathReturnsNilWithoutThrowing() throws {
        let cache = LookupCache(directory: tempDirectory)
        cache.store(Data("placeholder".utf8), forKey: "fp:corrupt")

        // Replace the cache file that key hashed to with a directory —
        // reading a directory as Data always fails, regardless of
        // permissions or the user running the test, so this deterministically
        // exercises the "unreadable" path without touching file permissions.
        let cachedFileURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil).first
        )
        try FileManager.default.removeItem(at: cachedFileURL)
        try FileManager.default.createDirectory(at: cachedFileURL, withIntermediateDirectories: false)

        XCTAssertNil(cache.data(forKey: "fp:corrupt"))
    }

    func testDistinctKeysDoNotCollideOnDisk() {
        let cache = LookupCache(directory: tempDirectory)
        cache.store(Data("first".utf8), forKey: "fp:one")
        cache.store(Data("second".utf8), forKey: "fp:two")
        XCTAssertEqual(cache.data(forKey: "fp:one"), Data("first".utf8))
        XCTAssertEqual(cache.data(forKey: "fp:two"), Data("second".utf8))
    }

    func testRemoveDeletesAStoredEntry() {
        let cache = LookupCache(directory: tempDirectory)
        cache.store(Data("value".utf8), forKey: "fp:removable")

        cache.remove(forKey: "fp:removable")

        XCTAssertNil(cache.data(forKey: "fp:removable"))
    }

    func testRemoveOnMissingKeyDoesNotThrowOrAffectOtherEntries() {
        let cache = LookupCache(directory: tempDirectory)
        cache.store(Data("kept".utf8), forKey: "fp:kept")

        cache.remove(forKey: "fp:never-stored")

        XCTAssertEqual(cache.data(forKey: "fp:kept"), Data("kept".utf8))
    }

    func testCachedValueReturnsDecodedValueOnHealthyHit() {
        let cache = LookupCache.memory()
        cache.store(Data("42".utf8), forKey: "k")

        let value = cache.cachedValue(forKey: "k") { data in
            try XCTUnwrap(Int(String(decoding: data, as: UTF8.self)))
        }

        XCTAssertEqual(value, 42)
    }

    func testCachedValueReturnsNilOnMiss() {
        let cache = LookupCache.memory()

        let value = cache.cachedValue(forKey: "missing") { data in data }

        XCTAssertNil(value)
    }

    /// The corrupt-cache-hit case at the heart of G-cache: a decode
    /// failure on a hit must not surface as a thrown error — it must
    /// evict the bad entry and behave exactly like a miss, so the caller
    /// falls through to a fresh network fetch instead of failing on the
    /// same bytes forever.
    func testCachedValueEvictsAndReturnsNilOnDecodeFailure() {
        struct DecodeFailure: Error {}
        let cache = LookupCache.memory()
        cache.store(Data("not an int".utf8), forKey: "k")

        let value = cache.cachedValue(forKey: "k") { data -> Int in
            guard let decoded = Int(String(decoding: data, as: UTF8.self)) else { throw DecodeFailure() }
            return decoded
        }

        XCTAssertNil(value)
        XCTAssertNil(cache.data(forKey: "k"), "the corrupt entry must be evicted, not left to fail every future read")
    }
}
