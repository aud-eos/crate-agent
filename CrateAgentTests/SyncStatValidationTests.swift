@testable import CrateAgent
import XCTest

final class SyncStatValidationTests: XCTestCase {
    @MainActor
    func testStatValidationDetectsChangesWithoutAnyDeliveredEvents() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("cached.wav")
        try fixture.save(paths: [file.path])
        let snapshot = try await fixture.reader.read()
        let identifier = try XCTUnwrap(file.id)
        let store = SyncCheckpointStore(database: fixture.database)
        let revision = try await store.currentRevision()
        let evidence = try SyncFileEvidence(fileID: identifier, membershipRevision: file.membershipRevision,
                                            identity: file.identity, readIdentity: AudioFileReadIdentity.read(at: file.path), bitrateProbed: true)
        let header = SyncCheckpointHeader(libraryID: snapshot.libraryID, source: snapshot.source,
                                          localRevision: revision, watchRoots: [fixture.directory.path], eventID: 0, hadConflicts: false)
        try await store.publish(.init(header: header, records: snapshot.records.map(SavedSeratoOccurrence.init), files: [evidence]), expectedRevision: revision)
        let unchanged = try await store.validateFileStats(expectedRevision: revision)
        XCTAssertEqual(unchanged.validatedFileIDs, [identifier])
        XCTAssertTrue(unchanged.changedFileIDs.isEmpty)
        try Data([9, 8, 7, 6, 5]).write(to: URL(fileURLWithPath: file.path))
        let changed = try await store.validateFileStats(expectedRevision: revision)
        XCTAssertEqual(changed.changedFileIDs, [identifier])
        XCTAssertTrue(changed.validatedFileIDs.isEmpty)
        try FileManager.default.removeItem(atPath: file.path)
        let missing = try await store.validateFileStats(expectedRevision: revision)
        XCTAssertEqual(missing.changedFileIDs, [identifier])
    }
}
