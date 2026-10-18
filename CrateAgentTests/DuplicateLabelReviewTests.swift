@testable import CrateAgent
import Foundation
import GRDB
import XCTest

/// Identical copies whose titles name different versions (#204).
@MainActor
final class DuplicateLabelReviewTests: XCTestCase {
    func testVersionLabelsComeFromTitleAnnotations() {
        let expectations: [(title: String, labels: Set<VersionLabel>)] = [
            ("Lockjaw (Intro Outro) (Clean)", [.introOutro, .clean]),
            ("Lockjaw (Explicit)", [.dirty]),
            ("The Next Episode (Instrumental)", [.instrumental]),
            ("The Next Episode", []),
            ("Dirty Diana", []),
            ("Song - Radio Edit", [.radio]),
            ("Song [DJ Name Remix - Short Edit]", [.remix, .edit]),
            ("Song (A Cappella)", [.acapella]),
            ("Song (feat. Someone)", []),
        ]
        for expectation in expectations {
            XCTAssertEqual(VersionLabel.labels(in: expectation.title), expectation.labels, expectation.title)
        }
    }

    func testKeepingDisagreeingCopiesLastsUntilTheGroupChangesAndUndoes() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let bytes = Data(repeating: 0x33, count: 4096)
        _ = try await titled(fixture.add("bubble-coat-dirty.mp3", bytes: bytes), "Bubble Coat (Dirty)", in: fixture)
        _ = try await titled(fixture.add("bubble-coat.mp3", bytes: bytes), "Bubble Coat", in: fixture)

        let disagreeing = try await checkedGroup(fixture)
        XCTAssertTrue(disagreeing.labelsDisagree)
        XCTAssertFalse(disagreeing.preselectsCleanup, "A wrong label must not be cleaned up by default")
        XCTAssertTrue(disagreeing.offersCleanup)

        try await DuplicateLabelReviewer(operationEngine: fixture.engine, database: fixture.database).keepAll(disagreeing)
        let kept = try await checkedGroup(fixture)
        XCTAssertEqual(kept.labelReview?.keptBoth, true)
        XCTAssertFalse(kept.offersCleanup)

        let batchID = try await fixture.database.writer.read { database in
            try String.fetchOne(database, sql: "SELECT batch_id FROM events WHERE event_type = ?", arguments: [EventType.duplicateLabelsKeptBoth.rawValue])
        }
        _ = try await fixture.engine.undoBatch(XCTUnwrap(batchID))
        let reopened = try await checkedGroup(fixture)
        XCTAssertTrue(reopened.labelsDisagree)

        try await DuplicateLabelReviewer(operationEngine: fixture.engine, database: fixture.database).keepAll(reopened)
        _ = try await titled(fixture.add("bubble-coat-copy.mp3", bytes: bytes), "Bubble Coat", in: fixture)
        let grown = try await checkedGroup(fixture)
        XCTAssertEqual(grown.size, 3)
        XCTAssertTrue(grown.labelsDisagree, "A new copy brings the disagreement back")
    }

    private func titled(_ file: FileRecord, _ title: String, in fixture: SeratoRemovalFixture) async throws -> FileRecord {
        try await fixture.database.writer.write { database in
            try database.execute(sql: "UPDATE files SET title = ? WHERE id = ?", arguments: [title, file.id])
        }
        return try await fixture.row(file)
    }

    private func checkedGroup(_ fixture: SeratoRemovalFixture) async throws -> DuplicateFinder.DuplicateGroup<DuplicateFileRow> {
        try await DuplicateEvidenceVerifier(database: fixture.database).verifyPendingFiles(mode: .byteLevel)
        let groups = try await fixture.database.writer.read { database in try DuplicateFinder.findDuplicates(in: database, mode: .byteLevel) }
        XCTAssertEqual(groups.count, 1)
        return try XCTUnwrap(groups.first)
    }
}
