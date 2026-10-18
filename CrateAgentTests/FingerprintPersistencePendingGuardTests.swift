@testable import CrateAgent
import GRDB
import XCTest

/// `FingerprintPersistence.write(requirePendingStatus:)` — the guard that keeps
/// the background worker's flush from clobbering a newer on-demand fingerprint
/// the auto-tagger already wrote (finding #4000806487).
final class FingerprintPersistencePendingGuardTests: XCTestCase {
    private func makeDatabase() throws -> LibraryDatabase {
        try LibraryDatabase.openInMemory()
    }

    private func insertPendingFile(_ database: LibraryDatabase) throws -> Int64 {
        try database.writer.write { db -> Int64 in
            var file = FileRecord(
                path: "/Music/A/x.mp3", volumeUuid: "v1", inode: 1,
                fileSize: 1, mtime: 1, fingerprintStatus: .pending
            )
            try file.insert(db)
            return file.id!
        }
    }

    func testPendingGuardBlocksOverwriteOfADoneRow() async throws {
        let database = try makeDatabase()
        let fileID = try insertPendingFile(database)

        // Auto-tagger writes a fresh .done fingerprint (unconditional).
        try await database.writer.write { db in
            _ = try FingerprintPersistence.write(
                fileID: fileID, fingerprint: Data([0xAA]), status: .done,
                freshnessBasis: FileFreshnessSnapshot(fileSize: 2000, inode: 1, mtime: 999, mtimeNanoseconds: 0), in: db
            )
        }

        // Worker flush arrives late with older bytes — pending-guarded, so it
        // must NOT overwrite the newer .done result or its basis.
        try await database.writer.write { db in
            _ = try FingerprintPersistence.write(
                fileID: fileID, fingerprint: Data([0xBB]), status: .done,
                requirePendingStatus: true, in: db
            )
        }

        let file = try await database.writer.read { db in try FileRecord.fetchOne(db, key: fileID)! }
        XCTAssertEqual(file.chromaprintFingerprint, Data([0xAA]), "the newer on-demand fingerprint must survive the worker flush")
        XCTAssertEqual(file.fingerprintedSize, 2000, "and its freshness basis must survive too")
    }

    func testPendingGuardAllowsWriteWhileStillPending() async throws {
        let database = try makeDatabase()
        let fileID = try insertPendingFile(database)

        // A pending row is still the worker's to fill.
        try await database.writer.write { db in
            _ = try FingerprintPersistence.write(
                fileID: fileID, fingerprint: Data([0xCC]), status: .done,
                requirePendingStatus: true, in: db
            )
        }

        let file = try await database.writer.read { db in try FileRecord.fetchOne(db, key: fileID)! }
        XCTAssertEqual(file.chromaprintFingerprint, Data([0xCC]))
        XCTAssertEqual(file.fingerprintStatus, .done)
    }
}
