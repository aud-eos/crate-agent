@testable import CrateAgent
import GRDB
import XCTest

final class WorkerCoverageTests: XCTestCase {
    func testCoverageCountsOnlyUsableFingerprintsAndSeparatesInvalidAndIneligibleFiles() async throws {
        let fixture = try await CoverageFixture()
        let coverage = try await fixture.database.writer.read { db in try WorkerCoverageQuery.fetch(in: db) }
        XCTAssertEqual(coverage.fingerprint, FingerprintCoverage(eligible: 6, done: 1, pending: 1, failed: 1, invalid: 3,
                                                                 unavailable: 1, awaitingMembership: 0, removedFromSerato: 1))
        XCTAssertEqual(coverage.fileInfo, FileInfoCoverage(indexed: 7, available: 6, missing: 1, removedFromSerato: 1))
        let invalid = try await fixture.database.writer.read { db in try WorkerCoverageQuery.files(in: .invalid, database: db) }
        XCTAssertEqual(Set(invalid.map(\.id)), Set(fixture.invalidIDs))
    }

    func testRetryRequeuesOnlyFailedAndInvalidFilesThatCanBeProcessed() async throws {
        let fixture = try await CoverageFixture()
        let selectedInvalid = fixture.invalidIDs[0]
        let selected = try await fixture.database.writer.write { db in
            try FingerprintPersistence.requeueForRetry(fileIDs: [selectedInvalid, fixture.validDoneID], in: db)
        }
        XCTAssertEqual(selected, 1)
        let all = try await fixture.database.writer.write { db in try FingerprintPersistence.requeueForRetry(fileIDs: nil, in: db) }
        XCTAssertEqual(all, 3, "the failed row and the two remaining invalid rows")
        let rows = try await fixture.database.writer.read { db in try FileRecord.fetchAll(db) }
        let statusByID = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.id.map { identifier in (identifier, row.fingerprintStatus) } })
        for identifier in fixture.invalidIDs + [fixture.failedID] {
            XCTAssertEqual(statusByID[identifier], .pending)
        }
        XCTAssertEqual(statusByID[fixture.validDoneID], .done)
        XCTAssertEqual(statusByID[fixture.unavailableFailedID], .failed, "a missing file cannot be fingerprinted, so it is not requeued")
    }

    func testCoverageForThirtyThousandFilesStaysWithinBudget() async throws {
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { db in
            for index in 0 ..< 30000 {
                let status = index.isMultiple(of: 10) ? "failed" : (index.isMultiple(of: 3) ? "pending" : "done")
                try db.execute(sql: """
                INSERT INTO files (path, volume_uuid, inode, file_size, mtime, fingerprint_status, chromaprint_fingerprint,
                                   library_membership, file_availability)
                VALUES (?, 'VOL', ?, 1000, 0, ?, ?, 'active', ?)
                """, arguments: ["/fixture/\(index).mp3", index, status, status == "done" ? Data(count: 4096) : nil,
                                 index.isMultiple(of: 97) ? "missing" : "available"])
            }
        }
        let start = ContinuousClock.now
        let coverage = try await database.writer.read { db in try WorkerCoverageQuery.fetch(in: db) }
        let elapsed = start.duration(to: .now)
        print("WORKER_COVERAGE files=30000 elapsed=\(elapsed)")
        XCTAssertEqual(coverage.fileInfo.indexed, 30000)
        XCTAssertLessThan(elapsed, .milliseconds(250))
    }
}

private struct CoverageFixture {
    let database: LibraryDatabase
    let validDoneID: Int64
    let invalidIDs: [Int64]
    let failedID: Int64
    let unavailableFailedID: Int64

    init() async throws {
        database = try LibraryDatabase.openInMemory()
        (validDoneID, invalidIDs, failedID, unavailableFailedID) = try await database.writer.write { db in
            var inode: Int64 = 0
            func insert(_ status: FingerprintStatus, fingerprint: Data?, membership: LibraryMembership = .active,
                        availability: FileAvailability = .available, in db: Database) throws -> Int64
            {
                inode += 1
                var file = FileRecord(path: "/fixture/\(inode).mp3", volumeUuid: "VOL", inode: inode, fileSize: 1000, mtime: 0,
                                      chromaprintFingerprint: fingerprint, fingerprintStatus: status)
                file.libraryMembership = membership
                file.fileAvailability = availability
                try file.insert(db)
                return try XCTUnwrap(file.id)
            }
            let valid = try insert(.done, fingerprint: FingerprintEncoder.serialize([7]), in: db)
            let invalid = try [
                insert(.done, fingerprint: nil, in: db),
                insert(.done, fingerprint: Data(), in: db),
                insert(.done, fingerprint: Data([1, 2, 3]), in: db),
            ]
            _ = try insert(.pending, fingerprint: nil, in: db)
            let failed = try insert(.failed, fingerprint: nil, in: db)
            let unavailable = try insert(.failed, fingerprint: nil, availability: .missing, in: db)
            _ = try insert(.done, fingerprint: FingerprintEncoder.serialize([8]), membership: .retired, in: db)
            return (valid, invalid, failed, unavailable)
        }
    }
}
