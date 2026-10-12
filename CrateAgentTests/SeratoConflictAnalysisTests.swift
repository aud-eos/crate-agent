@testable import CrateAgent
import Foundation
import XCTest

@MainActor
final class SeratoConflictAnalysisTests: XCTestCase {
    func testRawOccurrencesMetadataAndIndexedAliasesSurviveGrouping() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let composed = "/Music/Caf\u{00E9}.mp3"
        let decomposed = "/Music/Cafe\u{0301}.mp3"
        var bytes = SeratoTestEncoding.library(paths: [])
        for (path, artist) in [(composed, "First"), (decomposed, "Second"), ("/Music/Other.mp3", "Other")] {
            let fields = try SeratoTestEncoding.record("pfil", XCTUnwrap(path.data(using: .utf16BigEndian)))
                + SeratoTestEncoding.record("tart", XCTUnwrap(artist.data(using: .utf16BigEndian)))
                + SeratoTestEncoding.record("zzzz", Data([9, 8, 7]))
            bytes += SeratoTestEncoding.record("otrk", fields)
        }
        try bytes.write(to: fixture.locator.databaseV2Url)
        let snapshot = try await fixture.reader.read()
        let identity = ConflictPhysicalIdentity(volumeID: "volume", inode: 42)
        let files = [FileRecord(id: 1, path: composed, volumeUuid: "volume", inode: 42, fileSize: 4, mtime: 0, trackId: 7),
                     FileRecord(id: 2, path: "/alias.mp3", volumeUuid: "volume", inode: 42, fileSize: 4, mtime: 0)]
        let analysis = try await SeratoConflictAnalyzer(inspect: { path in
            guard path != "/Music/Other.mp3" else { throw CocoaError(.fileReadUnknown) }
            return .existing(identity)
        }).analyze(snapshot: snapshot, files: files)
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        XCTAssertEqual(analysis.conflicts.count, 1)
        let conflict = try XCTUnwrap(analysis.conflicts.first)
        XCTAssertEqual(conflict.occurrences.map(\.rawPathBytes), [Data(composed.utf8), Data(decomposed.utf8)])
        XCTAssertEqual(conflict.occurrences.map(\.record.artist), ["First", "Second"])
        XCTAssertEqual(conflict.fileIDs, [1, 2])
        XCTAssertEqual(analysis.scope.conflictingPath(for: SeratoConflictTarget(fileIDs: [2])), composed)
        XCTAssertEqual(analysis.scope.conflictingPath(for: SeratoConflictTarget(sharedTrackIDs: [7])), composed)
        XCTAssertNil(analysis.scope.conflictingPath(for: SeratoConflictTarget(paths: ["/Music/Other.mp3"])))
    }

    func testEachRawSpellingGetsItsOwnDiagnosticIncludingInspectionErrors() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let composed = "/Music/Caf\u{00E9}.mp3"
        let decomposed = "/Music/Cafe\u{0301}.mp3"
        try fixture.save(paths: [composed, decomposed])
        let snapshot = try await fixture.reader.read()
        let first = ConflictPhysicalIdentity(volumeID: "volume", inode: 1)
        let second = ConflictPhysicalIdentity(volumeID: "volume", inode: 2)
        let scenarios: [(ConflictPathObservation, ConflictPathObservation)] = [
            (.missing, .missing), (.existing(first), .missing),
            (.existing(first), .existing(second)), (.existing(first), .existing(first)),
            (.inaccessible, .offline), (.unknown, .failed("I/O failure")),
        ]
        for (firstObservation, secondObservation) in scenarios {
            let analysis = try await SeratoConflictAnalyzer(inspect: { path in
                Data(path.utf8) == Data(composed.utf8) ? firstObservation : secondObservation
            }).analyze(snapshot: snapshot, files: [])
            XCTAssertEqual(analysis.conflicts.first?.occurrences.map(\.observation), [firstObservation, secondObservation])
        }
        let failed = try await SeratoConflictAnalyzer(inspect: { _ in throw CocoaError(.fileReadUnknown) })
            .analyze(snapshot: snapshot, files: [])
        guard case .failed = failed.conflicts[0].occurrences[0].observation else {
            return XCTFail("Inspection failure must remain visible, not become missing")
        }
    }

    func testIdenticalRepeatedRecordsRemainConflictAndRealFileIsIdentified() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("Cafe.mp3")
        try fixture.save(paths: [file.path, file.path])
        let analysis = try await SeratoConflictAnalyzer().analyze(snapshot: fixture.reader.read(), files: [file])
        XCTAssertEqual(analysis.conflicts.first?.occurrences.map(\.id), [0, 1])
        XCTAssertEqual(analysis.conflicts.first?.occurrences.map(\.observation),
                       Array(repeating: .existing(ConflictPhysicalIdentity(volumeID: file.volumeUuid, inode: UInt64(file.inode))), count: 2))
    }
}
