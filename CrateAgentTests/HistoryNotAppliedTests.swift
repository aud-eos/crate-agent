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
        func commitTitle(_ title: String, to file: FileRecord) async throws {
            let fileID = try XCTUnwrap(file.id)
            try await fixture.engine.apply(.setMetadata(.init(fileId: fileID, metadata: .init(title: title), isSeratoAuthoritative: false)), batchId: "edits")
            try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: title))), batchId: "edits")
        }
        try await commitTitle("First title", to: first)
        try await commitTitle("Second title", to: second)
        let noEntry = "1 change not applied because Serato's database has no entry at their path"

        var batches = try await EventHistoryQuery.loadRecentBatches(database: fixture.database)
        var batch = try XCTUnwrap(batches.first { batch in batch.batchId == "edits" })
        XCTAssertEqual(batch.notApplied.changeCount, 2)
        XCTAssertEqual(batch.notApplied.fileCount, 2)
        XCTAssertEqual(batch.notApplied.reasons, ["2 changes not applied because Serato's database has no entry at their path"])
        let firstPage = try await EventHistoryQuery.loadNotAppliedFiles(for: batch, database: fixture.database, limit: 1)
        XCTAssertEqual(firstPage.map(\.path), [first.path])

        // A change recorded between page loads, for a file listed before the
        // page boundary, must not shift the next page back onto a shown file.
        let earlier = try await fixture.add("0-earlier.wav", bytes: FinalRemovalIntegrationTests.wav(sample: 3))
        try await commitTitle("Earlier title", to: earlier)
        let secondPage = try await EventHistoryQuery.loadNotAppliedFiles(for: batch, database: fixture.database, limit: 1, after: firstPage.last)
        XCTAssertEqual(secondPage.map(\.path), [second.path])
        XCTAssertEqual(secondPage.map(\.reasons), [[noEntry]])
        XCTAssertEqual(secondPage.map(\.canResync), [true])

        try fixture.save(paths: [first.path, second.path].map(SeratoLibraryLocator.seratoRelativePath))
        let secondID = try XCTUnwrap(second.id)
        let outcome = try await fixture.engine.resyncSeratoForBatch("edits", fileID: secondID)

        XCTAssertEqual(outcome.appliedCount, 1)
        let titles = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path)
            .reduce(into: [String: String?]()) { titles, record in titles[SeratoPath.normalized(record.path)] = record.title }
        XCTAssertEqual(titles, [first.path: nil, second.path: "Second title"])

        batches = try await EventHistoryQuery.loadRecentBatches(database: fixture.database)
        batch = try XCTUnwrap(batches.first { batch in batch.batchId == "edits" })
        XCTAssertEqual(batch.notApplied.changeCount, 2)
        XCTAssertEqual(batch.notApplied.resolvedChangeCount, 1)
        XCTAssertEqual(batch.notApplied.listedFileCount, 3)
        let files = try await EventHistoryQuery.loadNotAppliedFiles(for: batch, database: fixture.database)
        XCTAssertEqual(files.map(\.path), [earlier.path, first.path, second.path])
        XCTAssertEqual(files.map(\.reasons), [[noEntry], [noEntry], []])
        XCTAssertEqual(files.map(\.canResync), [true, true, false])
    }
}
