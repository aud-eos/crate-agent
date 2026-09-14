@testable import CrateAgent
import GRDB
import XCTest

final class LibraryStatusBrowseTests: XCTestCase {
    private func fixture() throws -> LibraryDatabase {
        let database = try LibraryDatabase.openInMemory()
        try database.writer.write { database in
            let states: [(LibraryMembership, FileAvailability)] = [
                (.active, .available), (.active, .missing), (.active, .offline),
                (.active, .inaccessible), (.active, .trashed), (.active, .unknown),
                (.pendingImport, .available), (.legacyUnverified, .unknown),
                (.retired, .available), (.retired, .missing), (.retired, .offline),
                (.retired, .inaccessible), (.retired, .trashed), (.retired, .unknown),
            ]
            for (index, state) in states.enumerated() {
                var file = FileRecord(id: Int64(index + 1), path: "/Synthetic/Track-\(index + 1).mp3",
                                      volumeUuid: "fixture", inode: Int64(index + 1), fileSize: 1, mtime: 0,
                                      chromaprintFingerprint: Data(repeating: 42, count: 512),
                                      artist: "Artist", title: "Track", album: index >= 8 ? "Removed collection" : "Current collection")
                file.libraryMembership = state.0
                file.fileAvailability = state.1
                try file.insert(database)
            }
        }
        return database
    }

    func testRemovedIncludesEveryAvailabilityAndKeepsNormalPath() throws {
        let database = try fixture()
        try database.writer.read { database in
            let result = try LibraryStatusBrowse.fetch(database, filter: .removedFromSerato)
            XCTAssertEqual(Set(result.rows.map(\.id)), Set((9 ... 14).map(Int64.init)))
            XCTAssertEqual(result.totalCount, 6)
            XCTAssertTrue(result.rows.allSatisfy { $0.path.hasPrefix("/Synthetic/Track-") })
        }
    }

    func testMissingIncludesActiveUnavailableButExcludesPendingLegacyAndRetired() throws {
        let database = try fixture()
        try database.writer.read { database in
            let result = try LibraryStatusBrowse.fetch(database, filter: .missing)
            XCTAssertEqual(Set(result.rows.map(\.id)), Set([2, 3, 4, 5, 6]))
            XCTAssertEqual(result.totalCount, 5)
            XCTAssertEqual(try LibraryStatusBrowse.fetch(database).totalCount, 8)
        }
    }

    func testSearchCountAndPaginationShareStableOrdering() throws {
        let database = try fixture()
        try database.writer.read { database in
            let order = [KeyPathComparator(\BrowserRow.artistOrEmpty)]
            let first = try LibraryStatusBrowse.fetch(database, filter: .removedFromSerato, search: "REMOVED", sortOrder: order, limit: 2)
            let second = try LibraryStatusBrowse.fetch(database, filter: .removedFromSerato, search: "REMOVED", sortOrder: order, limit: 2, offset: 2)
            XCTAssertEqual(first.totalCount, 6)
            XCTAssertEqual(first.rows.map(\.id), [9, 10])
            XCTAssertEqual(second.rows.map(\.id), [11, 12])
            XCTAssertTrue(try LibraryStatusBrowse.fetch(database, filter: .active, search: "Removed").rows.isEmpty)
            XCTAssertEqual(try LibraryStatusBrowse.fetch(database, filter: .removedFromSerato, search: "Track-14").rows.map(\.id), [14])
        }
    }

    func testLifecycleProjectionDisablesProcessingAndLabelsEveryState() throws {
        let database = try fixture()
        try database.writer.read { database in
            let rows = try BrowserRow.fetchAll(database, sql: BrowserRow.browserFetchSQL)
            XCTAssertEqual(rows.filter(\.canProcess).map(\.id), [1])
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            XCTAssertEqual(byID[3]?.statusText, "In Serato · Volume offline")
            XCTAssertEqual(byID[4]?.statusText, "In Serato · Access denied")
            XCTAssertEqual(byID[5]?.statusText, "In Serato · In Trash")
            XCTAssertEqual(byID[7]?.statusText, "Import pending")
            XCTAssertEqual(byID[8]?.statusText, "Membership unverified · Availability unknown")
            XCTAssertEqual(byID[9]?.statusText, "Removed from Serato")
            XCTAssertTrue(try AutoTagFileBrowse.browse(in: database).matches.contains { $0.id == 3 && $0.fileAvailability == .offline })
            XCTAssertEqual(try AutoTagFileSearch.search(query: "Track-3", in: database).matches.first?.fileAvailability, .offline)
        }
    }

    func testUnavailableErrorIdentifiesFilenameAndReason() throws {
        let database = try fixture()
        let file = try database.writer.read { try XCTUnwrap(FileRecord.fetchOne($0, key: 3)) }
        XCTAssertThrowsError(try FileProcessingEligibility.requireProcessable(file)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Track-3.mp3"))
            XCTAssertTrue(error.localizedDescription.contains("Volume offline"))
        }
    }

    @MainActor
    func testObservationPublishesAvailabilityChangeWithoutCountChange() async throws {
        let database = try fixture()
        let initial = expectation(description: "initial bounded rows")
        let changed = expectation(description: "same-count lifecycle update")
        let observation = LibraryStatusBrowse.observation(filter: .active, search: "Track-1.mp3", sortOrder: [], limit: 2)
        let observer = observation.start(in: database.writer, scheduling: .immediate, onError: { error in
            XCTFail(error.localizedDescription)
        }, onChange: { result in
            XCTAssertEqual(result.totalCount, 1)
            if result.rows.first?.fileAvailability == .available {
                initial.fulfill()
            }
            if result.rows.first?.fileAvailability == .offline {
                changed.fulfill()
            }
        })
        defer { observer.cancel() }
        await fulfillment(of: [initial], timeout: 3)
        let engine = OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }),
                                     seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")))
        _ = try await engine.apply(.setFileLibraryState(.init(fileId: 1, expectedRevision: 0,
                                                              state: FileLibraryState(membership: .active, availability: .offline, libraryID: nil, retiredAt: nil))))
        await fulfillment(of: [changed], timeout: 3)
    }

    @MainActor
    func testStableFileHistorySurvivesRetirementReactivationAndPagesWithTieBreaker() async throws {
        let database = try fixture()
        try await database.writer.write { database in
            for fileID: Int64 in [1, 9] {
                var event = EventRecord(batchId: "prior", timestamp: 1, fileId: fileID, eventType: .trackImported, payloadJson: "{}", inversePayloadJson: "{}")
                try event.insert(database)
            }
        }
        let engine = OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }),
                                     seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")))
        _ = try await engine.apply(.setFileLibraryState(.init(fileId: 1, expectedRevision: 0,
                                                              state: FileLibraryState(membership: .retired, availability: .available, libraryID: nil, retiredAt: 10))))
        let retired = try await database.writer.read { try EventHistoryQuery.loadFileHistory(fileID: 1, in: $0) }
        XCTAssertEqual(retired.count, 2)
        XCTAssertEqual(try EventHistoryQuery.fileEventDescription(retired[0]), "Removed from Serato · Available")
        _ = try await engine.apply(.setFileLibraryState(.init(fileId: 1, expectedRevision: 1,
                                                              state: FileLibraryState(membership: .active, availability: .available, libraryID: nil, retiredAt: nil))))
        try await database.writer.write { try $0.execute(sql: "UPDATE events SET timestamp = 1") }
        try await database.writer.read { database in
            let events = try EventHistoryQuery.loadFileHistory(fileID: 1, in: database)
            XCTAssertEqual(events.count, 3)
            XCTAssertTrue(events.allSatisfy { $0.fileId == 1 })
            XCTAssertEqual(events.compactMap(\.eventId), events.compactMap(\.eventId).sorted(by: >))
            XCTAssertEqual(try EventHistoryQuery.loadFileHistory(fileID: 1, in: database, limit: 1, offset: 1), [events[1]])
        }
    }

    func testInvalidPageFails() throws {
        let database = try fixture()
        try database.writer.read { database in
            XCTAssertThrowsError(try LibraryStatusBrowse.fetch(database, limit: 0))
            XCTAssertThrowsError(try LibraryStatusBrowse.fetch(database, offset: -1))
        }
    }
}
