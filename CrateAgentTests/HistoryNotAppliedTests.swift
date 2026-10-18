@testable import CrateAgent
import XCTest

@MainActor
final class HistoryNotAppliedTests: XCTestCase {
    func testHistoryExplainsEachFilesUnappliedChangesAndResyncsOneFile() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.add("a-first.wav", bytes: FinalRemovalIntegrationTests.wav(sample: 1))
        let second = try await fixture.add("b-second.wav", bytes: FinalRemovalIntegrationTests.wav(sample: 2))
        try fixture.save(paths: [])
        for (file, title) in [(first, "First title"), (second, "Second title")] {
            let fileID = try XCTUnwrap(file.id)
            try await fixture.engine.apply(.setMetadata(.init(fileId: fileID, metadata: .init(title: title), isSeratoAuthoritative: false)), batchId: "edits")
            try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: title))), batchId: "edits")
        }

        let batches = try await EventHistoryQuery.loadRecentBatches(database: fixture.database)
        let batch = try XCTUnwrap(batches.first { batch in batch.batchId == "edits" })
        XCTAssertEqual(batch.notApplied.changeCount, 2)
        XCTAssertEqual(batch.notApplied.fileCount, 2)
        XCTAssertEqual(batch.notApplied.reasons, ["2 changes not applied because Serato's database has no entry at their path"])
        let secondPage = try await EventHistoryQuery.loadNotAppliedFiles(for: batch, database: fixture.database, limit: 1, offset: 1)
        XCTAssertEqual(secondPage, [NotAppliedFile(fileID: second.id, firstEventID: secondPage.first?.firstEventID ?? 0, path: second.path,
                                                   reasons: ["1 change not applied because Serato's database has no entry at their path"],
                                                   canResync: true)])

        try fixture.save(paths: [first.path, second.path].map(SeratoLibraryLocator.seratoRelativePath))
        let secondID = try XCTUnwrap(second.id)
        let outcome = try await fixture.engine.resyncSeratoForBatch("edits", fileID: secondID)

        XCTAssertEqual(outcome.appliedCount, 1)
        let titles = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path)
            .reduce(into: [String: String?]()) { titles, record in titles[SeratoPath.normalized(record.path)] = record.title }
        XCTAssertEqual(titles, [first.path: nil, second.path: "Second title"])
    }
}
