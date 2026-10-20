@testable import CrateAgent
import Foundation
import GRDB
import XCTest

/// The checklist's Duplicate item counts only copies proven identical that
/// the owner hasn't chosen to keep.
@MainActor
final class ChecklistDuplicatesTests: XCTestCase {
    func testConfirmedMembersExcludeNeedsListeningAndKeptLabelGroups() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let identical = Data(repeating: 0x21, count: 4096)
        let confirmedA = try await fixture.add("confirmed-a.mp3", bytes: identical)
        let confirmedB = try await fixture.add("confirmed-b.mp3", bytes: identical)
        let labelled = Data(repeating: 0x42, count: 4096)
        _ = try await titled(fixture.add("tune-dirty.mp3", bytes: labelled), "Tune (Dirty)", in: fixture)
        _ = try await titled(fixture.add("tune.mp3", bytes: labelled), "Tune", in: fixture)
        let fingerprint = Data(repeating: 0x5A, count: 64)
        for (name, audio) in [("master-16.wav", TestAudio.wav(frequency: 440, bitsPerSample: 16)),
                              ("master-24.wav", TestAudio.wav(frequency: 440, bitsPerSample: 24))]
        {
            let file = try await fixture.add(name, bytes: audio)
            try await fixture.database.writer.write { connection in
                try connection.execute(sql: "UPDATE files SET chromaprint_fingerprint = ?, fingerprint_status = 'done' WHERE id = ?",
                                       arguments: [fingerprint, file.id])
            }
        }
        let verifier = DuplicateEvidenceVerifier(database: fixture.database)
        try await verifier.verifyPendingFiles(mode: .byteLevel)
        try await verifier.verifyPendingFiles(mode: .perceptual)
        let byteGroups = try await fixture.database.writer.read { connection in try DuplicateFinder.findDuplicates(in: connection, mode: .byteLevel) }
        let disagreeing = try XCTUnwrap(byteGroups.first { group in group.labelsDisagree })
        try await DuplicateLabelReviewer(operationEngine: fixture.engine, database: fixture.database).keepAll(disagreeing)

        let members = try await fixture.database.writer.read { connection in try ChecklistDuplicates.confirmedMembers(in: connection) }

        XCTAssertEqual(Set(members.keys), Set([confirmedA.id, confirmedB.id].compactMap { identifier in identifier }))
    }

    private func titled(_ file: FileRecord, _ title: String, in fixture: SeratoRemovalFixture) async throws -> FileRecord {
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET title = ? WHERE id = ?", arguments: [title, file.id])
        }
        return try await fixture.row(file)
    }
}
