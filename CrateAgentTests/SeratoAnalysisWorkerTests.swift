@testable import CrateAgent
import Foundation
import GRDB
import os
import XCTest

/// Cue points and beatgrid markers read from each file's Serato tags, cached
/// against the file basis they were read from.
@MainActor
final class SeratoAnalysisWorkerTests: XCTestCase {
    private struct StoredAnalysis {
        let cueCount: Int?
        let failure: String?
    }

    func testWorkerRecordsCuesAndReadsAFileAgainAfterItChangesOrAfterAnIOFailure() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("cued.mp3")
        let locked = try await fixture.add("locked.mp3")
        let cueCount = OSAllocatedUnfairLock(initialState: UInt32(3))
        let lockedReads = OSAllocatedUnfairLock(initialState: 0)
        let worker = try makeWorker(fixture) { path in
            if path == locked.path, lockedReads.withLock({ reads in reads += 1; return reads }) == 1 {
                throw SeratoAnalysisError.Io(message: "Permission denied")
            }
            return SeratoAnalysis(cueCount: cueCount.withLock { count in count }, beatgridMarkerCount: 1)
        }

        _ = try await worker.processAllPendingOnce()
        let first = try await analysis(of: file, in: fixture)
        XCTAssertEqual(first?.cueCount, 3)
        let lockedFirst = try await analysis(of: locked, in: fixture)
        XCTAssertNil(lockedFirst?.cueCount)
        XCTAssertEqual(lockedReads.withLock { reads in reads }, 1, "A pass reads a failing file once")

        let edited = file.mtime + 60
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(edited))], ofItemAtPath: file.path)
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET mtime = ?, mtime_nanoseconds = 0 WHERE id = ?", arguments: [edited, file.id])
        }
        cueCount.withLock { count in count = 5 }
        _ = try await worker.processAllPendingOnce()
        let second = try await analysis(of: file, in: fixture)
        XCTAssertEqual(second?.cueCount, 5)
        let lockedSecond = try await analysis(of: locked, in: fixture)
        XCTAssertEqual(lockedSecond?.cueCount, 5, "An I/O failure is read again on the next pass, though the file is unchanged")
    }

    func testUnreadableFileIsRecordedAsAFailureNotAsNoCues() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let malformed = try await fixture.add("malformed.mp3")
        let unsupported = try await fixture.add("a-unsupported.ogg")
        let worker = try makeWorker(fixture) { path in
            throw path.hasSuffix(".ogg") ? SeratoAnalysisError.UnsupportedFormat(format: "Vorbis")
                : SeratoAnalysisError.Malformed(field: "Serato Markers2", reason: "truncated cue")
        }

        let coverage = try await worker.processAllPendingOnce()

        let stored = try await analysis(of: malformed, in: fixture)
        XCTAssertNil(stored?.cueCount)
        XCTAssertNotNil(stored?.failure)
        XCTAssertEqual(coverage, SeratoAnalysisCoverage(read: 0, pending: 0, failed: 1, unsupported: 1))
        let libraryCoverage = try await fixture.database.writer.read { connection in try SeratoAnalysisStore.coverage(in: connection) }
        XCTAssertEqual(libraryCoverage, coverage)
        let failures = try await fixture.database.writer.read { connection in try SeratoAnalysisStore.failures(limit: 10, in: connection) }
        XCTAssertEqual(failures.map(\.id), [malformed.id, unsupported.id], "Faults come before unsupported formats")
        XCTAssertEqual(failures.map { failure in failure.detail?.hasPrefix(SeratoAnalysisMessages.malformedDetailPrefix) },
                       [true, false], "The list says which file's Serato data is malformed")
        XCTAssertEqual(failures.map { failure in failure.detail?.hasPrefix(SeratoAnalysisMessages.unsupportedDetailPrefix) },
                       [false, true], "and which file's format can't carry readable cues")
    }

    private func makeWorker(_ fixture: SeratoRemovalFixture,
                            readAnalysis: @escaping @Sendable (String) throws -> SeratoAnalysis) throws -> SeratoAnalysisWorker
    {
        let readiness = LibrarySyncReadiness()
        try readiness.markReady(readiness.prepareDrain())
        return SeratoAnalysisWorker(database: fixture.database, readiness: readiness, readAnalysis: readAnalysis)
    }

    private func analysis(of file: FileRecord, in fixture: SeratoRemovalFixture) async throws -> StoredAnalysis? {
        try await fixture.database.writer.read { connection in
            try Row.fetchOne(connection, sql: "SELECT cue_count, failure FROM \(SeratoAnalysisStore.table) WHERE file_id = ?",
                             arguments: [file.id]).map { row in StoredAnalysis(cueCount: row["cue_count"], failure: row["failure"]) }
        }
    }
}
