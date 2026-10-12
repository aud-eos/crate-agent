@testable import CrateAgent
import Foundation
import GRDB
import os
import XCTest

@MainActor
final class SeratoConflictAnalysisTests: XCTestCase {
    func testThirtyThousandRecordAnalysisBoundsDiagnosticsAndKeepsMainActorResponsive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove performance fixture: \(error)") }
        }
        let database = try LibraryDatabase.openWAL(at: directory.appendingPathComponent("library.sqlite"))
        let paths = (1 ... 30000).map { identifier in identifier == 1 ? "/fixture/Café.mp3" : "/fixture/track-\(identifier).mp3" }
        try await database.writer.write { connection in
            for (offset, path) in paths.enumerated() {
                try connection.execute(sql: "INSERT INTO files (id, path, volume_uuid, inode, file_size, mtime, library_membership, file_availability) VALUES (?, ?, 'fixture', ?, 1, 1, 'active', 'available')", arguments: [offset + 1, path, offset + 1])
            }
        }
        let files = try await FileRecord.loadIdentityProjections(database: database)
        let sourceURL = directory.appendingPathComponent("database V2")
        try SeratoTestEncoding.library(paths: []).write(to: sourceURL)
        let records = (paths + ["/fixture/Cafe\u{0301}.mp3", "/fixture/Café.mp3"]).map { path in
            SeratoTrackRecord(path: path, artist: nil, title: nil, album: nil, genre: nil, bpm: nil, key: nil, comment: nil, length: nil, label: nil)
        }
        let snapshot = try SeratoMembershipSnapshot(libraryID: "fixture", records: records, source: SeratoSourceIdentity.read(sourceURL), generation: 1)
        let probes = OSAllocatedUnfairLock(initialState: 0)
        let analyzer = SeratoConflictAnalyzer(inspect: { _ in
            probes.withLock { count in count += 1 }
            return .missing
        })
        var maximumGap = Duration.zero
        var samples = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                let start = ContinuousClock.now
                do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
                maximumGap = max(maximumGap, start.duration(to: .now))
                samples += 1
            }
        }
        await Task.yield()
        let start = ContinuousClock.now
        let analysis = try await analyzer.analyze(snapshot: snapshot, files: files)
        let elapsed = start.duration(to: .now)
        heartbeat.cancel()
        await heartbeat.value
        XCTAssertEqual(analysis.conflicts.count, 1)
        XCTAssertEqual(analysis.conflicts[0].occurrences.count, 3)
        XCTAssertEqual(analysis.scope.fileIDs, [1])
        XCTAssertEqual(probes.withLock { count in count }, 2, "Inspect raw conflicting spellings once, never all 30,000 paths")
        XCTAssertGreaterThan(samples, 0)
        XCTAssertLessThan(maximumGap, .milliseconds(50))
        XCTAssertNil(analysis.scope.conflictingPath(for: .file(files[1])))
        let events = try await database.writer.read { connection in try EventRecord.fetchCount(connection) }
        XCTAssertEqual(events, 0)
        let metrics = "CONFLICT_PERF records=\(records.count) analysis=\(elapsed) target=100ms max_main_gap=\(maximumGap) probes=2"
        print(metrics)
        let attachment = XCTAttachment(string: metrics)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
