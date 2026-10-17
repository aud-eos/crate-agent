@testable import CrateAgent
import GRDB
import XCTest

final class DuplicateScanObservationTests: XCTestCase {
    func testObservationFiresForFingerprintAndAvailabilityWritesButNotUnrelatedMetadata() async throws {
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { connection in
            var file = FileRecord(path: "/Music/A/track.mp3", volumeUuid: "observation", inode: 1, fileSize: 1, mtime: 0)
            try file.insert(connection)
        }
        let changes = expectation(description: "fingerprint and availability changes")
        changes.expectedFulfillmentCount = 2
        changes.assertForOverFulfill = true
        let observation = DuplicateScanObservation.start(in: database, onChange: { changes.fulfill() }, onError: { error in XCTFail(error.localizedDescription) })
        defer { observation.cancel() }
        try await database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET genre = 'House', comment = 'cue' WHERE id = 1")
        }
        try await database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET chromaprint_fingerprint = X'010203', fingerprint_status = 'done' WHERE id = 1")
        }
        try await database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET file_availability = 'offline' WHERE id = 1")
        }
        await fulfillment(of: [changes], timeout: 3)
    }
}
