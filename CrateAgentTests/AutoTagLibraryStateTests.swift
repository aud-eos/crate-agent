@testable import CrateAgent
import Combine
import GRDB
import XCTest

@MainActor
final class AutoTagLibraryStateTests: XCTestCase {
    func testProcessableCountTracksChangesWhileUnavailableAndUnverifiedRowsStayBrowsable() async throws {
        let database = try LibraryDatabase.openInMemory()
        let state = AutoTagLibraryState()
        let loaded = expectation(description: "initial empty read")
        let inserted = expectation(description: "first later scan")
        let insertedAgain = expectation(description: "second later scan")
        let emptied = expectation(description: "library removal")
        let loadingSubscription = state.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        let countSubscription = state.$fileCount.removeDuplicates().dropFirst().sink { count in
            switch count {
            case 1: inserted.fulfill()
            case 2: insertedAgain.fulfill()
            case 0: emptied.fulfill()
            default: XCTFail("unexpected count: \(count)")
            }
        }
        let observation = Task { await state.observe(in: database) }
        defer {
            observation.cancel()
            loadingSubscription.cancel()
            countSubscription.cancel()
        }
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(state.fileCount, 0)
        try await database.writer.write { db in
            var first = FileRecord(path: "/first.mp3", volumeUuid: "test", inode: 1, fileSize: 1, mtime: 1)
            first.libraryMembership = .active
            first.fileAvailability = .available
            try first.insert(db)
            let states: [(LibraryMembership, FileAvailability)] = [
                (.pendingImport, .available), (.legacyUnverified, .available),
                (.retired, .available), (.active, .offline),
            ]
            for (index, state) in states.enumerated() {
                var file = FileRecord(path: "/excluded-\(index).mp3", volumeUuid: "test", inode: Int64(index + 10), fileSize: 1, mtime: 1)
                file.libraryMembership = state.0
                file.fileAvailability = state.1
                try file.insert(db)
            }
        }
        await fulfillment(of: [inserted], timeout: 2)
        XCTAssertEqual(state.fileCount, 1)
        let visibleCount = try await database.writer.read { try LibraryStatusBrowse.fetch($0).totalCount }
        XCTAssertEqual(visibleCount, 4)
        try await database.writer.write { db in
            var second = FileRecord(path: "/second.mp3", volumeUuid: "test", inode: 2, fileSize: 1, mtime: 1)
            second.libraryMembership = .active
            second.fileAvailability = .available
            try second.insert(db)
        }
        await fulfillment(of: [insertedAgain], timeout: 2)
        try await database.writer.write { db in _ = try FileRecord.deleteAll(db) }
        await fulfillment(of: [emptied], timeout: 2)
        XCTAssertEqual(state.fileCount, 0)
        XCTAssertNil(state.error)
    }
}
