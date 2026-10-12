@testable import CrateAgent
import GRDB
import XCTest

final class LibraryPagingTests: XCTestCase {
    private static var fixtureResult: Result<PagedLibraryFixture, Error>!
    var fixture: PagedLibraryFixture {
        get throws { try Self.fixtureResult.get() }
    }

    override class func setUp() {
        super.setUp()
        fixtureResult = Result { try PagedLibraryFixture() }
    }

    override class func tearDown() {
        do { try fixtureResult.get().close() } catch { XCTFail("Fixture cleanup: \(error)") }
        fixtureResult = nil
        super.tearDown()
    }

    override func tearDownWithError() throws {
        try fixture.reset()
    }

    func testSnapshotCountPagesAndFullQuerySearchRemainConsistentAcrossWrites() async throws {
        let fixture = try fixture
        let snapshot = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: fixture.query)
        let count = try await snapshot.count()
        XCTAssertEqual(count, 30000)
        try await fixture.pool.write { connection in
            var added = PagedLibraryFixture.file(30001)
            try added.insert(connection)
            try connection.execute(sql: "UPDATE files SET title = 'Changed' WHERE id = 30000")
        }
        let oldLast = try await snapshot.rows(in: 29800 ..< 30000)
        XCTAssertEqual(oldLast.last?.title, "Final Needle")
        XCTAssertEqual(oldLast.last?.id, 30000)
        let oldCount = try await snapshot.count()
        XCTAssertEqual(oldCount, 30000)
        let current = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: fixture.query)
        let newCount = try await current.count()
        XCTAssertEqual(newCount, 30001)
        let search = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: .init(search: "Changed"))
        let found = try await search.rows(in: 0 ..< 1)
        XCTAssertEqual(found.map(\.id), [30000])
        try await fixture.pool.write { connection in try connection.execute(sql: "DELETE FROM files WHERE id = 1") }
        let stillFirst = try await snapshot.rows(in: 0 ..< 1)
        XCTAssertEqual(stillFirst.first?.id, 1)
        let latest = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: fixture.query)
        let latestFirst = try await latest.rows(in: 0 ..< 1)
        XCTAssertEqual(latestFirst.first?.id, 2)
    }

    func testDatabaseSortUsesStableTieBreaksAcrossPageBoundaries() async throws {
        let fixture = try fixture
        for ascending in [true, false] {
            let query = LibraryBrowseQuery(sort: .init(column: .artist, ascending: ascending))
            let snapshot = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: query)
            let first = try await snapshot.rows(in: 0 ..< 200)
            let second = try await snapshot.rows(in: 200 ..< 400)
            XCTAssertEqual(first.first?.id, ascending ? 1 : 15001)
            XCTAssertEqual(second.first?.id, ascending ? 201 : 15201)
            XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
            let index = try await snapshot.index(of: ascending ? 201 : 15201)
            XCTAssertEqual(index, 200)
        }
    }

    func testObservationIncludesOffscreenMetadataAndAvailabilityButNotFingerprintWrites() async throws {
        let fixture = try fixture
        let changes = expectation(description: "metadata and availability changes")
        changes.expectedFulfillmentCount = 2
        changes.assertForOverFulfill = true
        let observation = LibraryBrowseObservation.start(in: fixture.database, onChange: { changes.fulfill() }, onError: { error in XCTFail(error.localizedDescription) })
        defer { observation.cancel() }
        try await fixture.pool.write { connection in
            try connection.execute(sql: "UPDATE files SET title = 'Changed' WHERE id = 30000")
        }
        try await fixture.pool.write { connection in
            try connection.execute(sql: "UPDATE files SET chromaprint_fingerprint = X'010203' WHERE id = 30000")
        }
        try await fixture.pool.write { connection in
            try connection.execute(sql: "UPDATE files SET file_availability = 'offline' WHERE id = 30000")
        }
        await fulfillment(of: [changes], timeout: 3)
    }
}
