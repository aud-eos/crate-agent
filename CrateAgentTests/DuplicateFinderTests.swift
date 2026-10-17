@testable import CrateAgent
import GRDB
import XCTest

final class DuplicateFinderTests: XCTestCase {
    private func insert(
        _ path: String,
        size: Int64 = 1024,
        hash: Data? = nil,
        fingerprint: Data? = nil,
        status: FingerprintStatus = .pending,
        membership: LibraryMembership = .active,
        availability: FileAvailability = .available,
        in database: Database
    ) throws {
        var file = try FileRecord(path: path, volumeUuid: "duplicate-fixture", inode: Int64(FileRecord.fetchCount(database)) + 1, fileSize: size, mtime: 1,
                                  lightweightHash: hash, chromaprintFingerprint: fingerprint, fingerprintStatus: status)
        file.libraryMembership = membership
        file.fileAvailability = availability
        try file.insert(database)
    }

    func testByteLevelGroupsOnlyProcessableFilesSharingSizeAndHash() async throws {
        let database = try LibraryDatabase.openInMemory()
        let shared = Data([0xAA, 0xBB])
        let triple = Data([0xCC])
        let groups = try await database.writer.write { connection in
            try self.insert("/Music/B/copy.mp3", hash: shared, in: connection)
            try self.insert("/Music/A/one.mp3", hash: shared, in: connection)
            try self.insert("/Music/A/other-size.mp3", size: 2048, hash: shared, in: connection)
            try self.insert("/Music/A/retired.mp3", hash: triple, membership: .retired, in: connection)
            try self.insert("/Music/A/offline.mp3", hash: triple, availability: .offline, in: connection)
            try self.insert("/Music/A/lonely.mp3", hash: triple, in: connection)
            try self.insert("/Music/A/no-hash.mp3", in: connection)
            try self.insert("/Music/B/no-hash.mp3", in: connection)
            for index in 1 ... 3 {
                try self.insert("/Music/C/triple-\(index).mp3", size: 4096, hash: triple, in: connection)
            }
            return try DuplicateFinder.findDuplicates(in: connection, mode: .byteLevel)
        }

        XCTAssertEqual(groups.map { group in group.files.map(\.path) }, [
            ["/Music/C/triple-1.mp3", "/Music/C/triple-2.mp3", "/Music/C/triple-3.mp3"],
            ["/Music/A/one.mp3", "/Music/B/copy.mp3"],
        ], "Biggest group first, members by path; other sizes, missing hashes, singletons and non-processable rows never match")
    }

    func testPerceptualGroupsFinishedFingerprintsWithAKeyThatSurvivesNewMembers() async throws {
        let database = try LibraryDatabase.openInMemory()
        let fingerprint = Data(repeating: 0xDE, count: 4096)
        let initial = try await database.writer.write { connection in
            try self.insert("/Music/A/track.mp3", fingerprint: fingerprint, status: .done, in: connection)
            try self.insert("/Music/A/track.flac", fingerprint: fingerprint, status: .done, in: connection)
            try self.insert("/Music/A/pending.mp3", fingerprint: fingerprint, status: .pending, in: connection)
            try self.insert("/Music/A/different.mp3", fingerprint: Data([0xFE]), status: .done, in: connection)
            return try DuplicateFinder.findDuplicates(in: connection, mode: .perceptual)
        }
        XCTAssertEqual(initial.map { group in group.files.map(\.path) }, [["/Music/A/track.flac", "/Music/A/track.mp3"]])

        let grown = try await database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET fingerprint_status = 'done' WHERE path = '/Music/A/pending.mp3'")
            return try DuplicateFinder.findDuplicates(in: connection, mode: .perceptual)
        }
        XCTAssertEqual(grown.first?.size, 3)
        XCTAssertEqual(grown.first?.id, initial.first?.id, "A fingerprint landing must not rename the group, or keeper picks are lost")
    }

    func testFingerprintCoverageCountsProcessableFinishedFingerprints() async throws {
        let database = try LibraryDatabase.openInMemory()
        let coverage = try await database.writer.write { connection in
            try self.insert("/a.mp3", fingerprint: Data([1]), status: .done, in: connection)
            try self.insert("/b.mp3", fingerprint: Data([2]), status: .done, in: connection)
            try self.insert("/c.mp3", status: .pending, in: connection)
            try self.insert("/d.mp3", status: .failed, in: connection)
            try self.insert("/e.mp3", fingerprint: Data([3]), status: .done, membership: .retired, in: connection)
            return try DuplicateFinder.fingerprintCoverage(in: connection)
        }
        XCTAssertEqual(coverage.done, 2)
        XCTAssertEqual(coverage.total, 4)
    }
}
