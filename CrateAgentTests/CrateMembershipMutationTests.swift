@testable import CrateAgent
import GRDB
import XCTest

@MainActor
final class CrateMembershipMutationTests: XCTestCase {
    func testAddingToACrateWritesTheCrateRecordsTheMembershipAndUndoRemovesBoth() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("warm.wav", bytes: FinalRemovalIntegrationTests.wav(sample: 1))
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let crate = fixture.locator.subcratesDirectoryUrl.appendingPathComponent("Warmup.crate")
        try SeratoTestEncoding.record("vrsn", Data("1.0/Serato ScratchLive Crate".data(using: .utf16BigEndian)!)).write(to: crate)
        let fileID = try XCTUnwrap(file.id)

        let batch = "crate-\(UUID().uuidString)"
        _ = try await fixture.engine.apply(.setCrateMembership(.init(fileId: fileID, crateFileName: "Warmup.crate", present: true)), batchId: batch)
        XCTAssertEqual(try readCratePaths(cratePath: crate.path), [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let added = try await memberships(fixture, fileID: fileID)
        XCTAssertEqual(added, ["Warmup.crate"])

        _ = try await fixture.engine.undoBatch(batch)
        XCTAssertEqual(try readCratePaths(cratePath: crate.path), [])
        let undone = try await memberships(fixture, fileID: fileID)
        XCTAssertEqual(undone, [])
    }

    private func memberships(_ fixture: SeratoRemovalFixture, fileID: Int64) async throws -> [String] {
        try await fixture.database.writer.read { connection in
            try String.fetchAll(connection, sql: "SELECT crate_name FROM serato_crate_memberships WHERE file_id = ? ORDER BY crate_name", arguments: [fileID])
        }
    }
}
