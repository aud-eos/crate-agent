@testable import CrateAgent
import XCTest

final class LibraryRefreshPlannerTests: XCTestCase {
    func testAnalysisFromDifferentSourceCannotAuthorizePlan() async throws {
        let fixture = try PlannerFixture()
        defer { fixture.cleanup() }
        let old = SeratoMembershipSnapshot(libraryID: "fixture", records: fixture.records, source: fixture.source, generation: 1)
        let analysis = try await SeratoConflictAnalyzer().analyze(snapshot: old, files: fixture.files)
        let sourceURL = fixture.directory.appendingPathComponent("database V2")
        try SeratoTestEncoding.library(paths: ["/changed.wav"]).write(to: sourceURL)
        let changed = try SeratoMembershipSnapshot(libraryID: "fixture", records: fixture.records, source: SeratoSourceIdentity.read(sourceURL), generation: 1)
        let planner = LibraryRefreshPlanner(evidence: fixture.evidence, validatedFileIDs: [1, 2, 3])
        do {
            _ = try await planner.makePlan(request: .incremental, snapshot: changed, indexedFiles: fixture.files,
                                           previousRecords: fixture.records, dirtyFileIDs: [], dirtyPaths: [], analysis: analysis)
            XCTFail("Analysis for a different source authorized observation")
        } catch SeratoMembershipSnapshotError.sourceChanged {}
    }

    func testExternalMetadataDifferenceSelectsOnlyChangedRecordAndPreservesLocalIntent() async throws {
        let fixture = try PlannerFixture()
        defer { fixture.cleanup() }
        var current = fixture.records
        current[1].title = "External edit"
        var files = fixture.files
        files[0].title = "Newer local intent"
        let snapshot = SeratoMembershipSnapshot(libraryID: "fixture", records: current, source: fixture.source, generation: 1)
        let analysis = try await SeratoConflictAnalyzer().analyze(snapshot: snapshot, files: files)
        let planner = LibraryRefreshPlanner(evidence: fixture.evidence, validatedFileIDs: [1, 2, 3], inspect: { _ in
            XCTFail("Covered unchanged audio was inspected")
            return nil
        })
        let plan = try await planner.makePlan(request: .incremental, snapshot: snapshot, indexedFiles: files,
                                              previousRecords: fixture.records, dirtyFileIDs: [], dirtyPaths: [], analysis: analysis)
        XCTAssertEqual(plan.metadataPaths, [Data(current[1].path.utf8)])
        XCTAssertEqual(plan.refreshPaths, [])
        XCTAssertEqual(plan.reconcileFileIDs, [])
        let forced = try await planner.makePlan(request: .forceRefresh, snapshot: snapshot, indexedFiles: files,
                                                previousRecords: fixture.records, dirtyFileIDs: [], dirtyPaths: [], analysis: analysis)
        XCTAssertEqual(forced.refreshPaths, Set(current.map { record in Data(record.path.utf8) }))
    }

    func testUncoveredPreciseChangeAndLostCoverageRequireRefresh() async throws {
        let fixture = try PlannerFixture()
        defer { fixture.cleanup() }
        let snapshot = SeratoMembershipSnapshot(libraryID: "fixture", records: fixture.records, source: fixture.source, generation: 1)
        let analysis = try await SeratoConflictAnalyzer().analyze(snapshot: snapshot, files: fixture.files)
        let changedPath = fixture.files[1].path
        try Data([7, 8, 9]).write(to: URL(fileURLWithPath: changedPath))
        let previousStamp = try XCTUnwrap(fixture.evidence[2]?.readIdentity)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(previousStamp.target.modifiedSeconds))], ofItemAtPath: changedPath)
        let changedStamp = try AudioFileReadIdentity.read(at: changedPath)
        XCTAssertEqual(changedStamp.target.size, previousStamp.target.size)
        XCTAssertEqual(changedStamp.target.modifiedSeconds, previousStamp.target.modifiedSeconds)
        XCTAssertNotEqual(changedStamp, previousStamp)
        let planner = LibraryRefreshPlanner(evidence: fixture.evidence, validatedFileIDs: [1, 3])
        let plan = try await planner.makePlan(request: .incremental, snapshot: snapshot, indexedFiles: fixture.files,
                                              previousRecords: fixture.records, dirtyFileIDs: [], dirtyPaths: [], analysis: analysis)
        XCTAssertEqual(plan.refreshPaths, [Data(changedPath.utf8)])
        XCTAssertEqual(plan.reconcileFileIDs, [2])
        let lost = LibraryRefreshPlanner(evidence: fixture.evidence, validatedFileIDs: [], requiresReconciliation: true)
        let broad = try await lost.makePlan(request: .incremental, snapshot: snapshot, indexedFiles: fixture.files,
                                            previousRecords: fixture.records, dirtyFileIDs: [], dirtyPaths: [], analysis: analysis)
        XCTAssertEqual(broad.reconcileFileIDs, [1, 2, 3])
    }

    func testEscapingSymlinkTargetReplacementRequiresRefresh() async throws {
        let fixture = try PlannerFixture()
        defer { fixture.cleanup() }
        let target = fixture.directory.appendingPathComponent("outside-target.wav")
        try Data([1, 2, 3]).write(to: target)
        let path = fixture.files[0].path
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
        let identity = try FileMetadataCollector.collectVerified(at: path)
        let stamp = try AudioFileReadIdentity.read(at: path)
        var files = fixture.files
        files[0].volumeUuid = identity.volumeUuid
        files[0].inode = identity.inode
        files[0].fileSize = identity.fileSize
        files[0].mtime = identity.mtime
        files[0].lightweightHash = identity.lightweightHash
        var evidence = fixture.evidence
        evidence[1] = SyncFileEvidence(fileID: 1, membershipRevision: 0, identity: identity, readIdentity: stamp, bitrateProbed: true)
        try Data([4, 5, 6]).write(to: target, options: .atomic)
        let changed = try AudioFileReadIdentity.read(at: path)
        XCTAssertEqual(changed.entry, stamp.entry)
        XCTAssertNotEqual(changed.target, stamp.target)
        let snapshot = SeratoMembershipSnapshot(libraryID: "fixture", records: fixture.records, source: fixture.source, generation: 1)
        let analysis = try await SeratoConflictAnalyzer().analyze(snapshot: snapshot, files: files)
        let planner = LibraryRefreshPlanner(evidence: evidence, validatedFileIDs: [2, 3])
        let plan = try await planner.makePlan(request: .incremental, snapshot: snapshot, indexedFiles: files,
                                              previousRecords: fixture.records, dirtyFileIDs: [], dirtyPaths: [], analysis: analysis)
        XCTAssertEqual(plan.refreshPaths, [Data(path.utf8)])
        XCTAssertEqual(plan.reconcileFileIDs, [1])
    }

    func testUncoveredMissingAndReplacedVolumesCannotReuseAudioEvidence() async throws {
        let fixture = try PlannerFixture()
        defer { fixture.cleanup() }
        let snapshot = SeratoMembershipSnapshot(libraryID: "fixture", records: fixture.records, source: fixture.source, generation: 1)
        let analysis = try await SeratoConflictAnalyzer().analyze(snapshot: snapshot, files: fixture.files)
        let missing = fixture.files[1].path
        let replaced = fixture.files[2].path
        let planner = LibraryRefreshPlanner(evidence: fixture.evidence, validatedFileIDs: [1], inspect: { path in
            if path == missing {
                return nil
            }
            return try FileRefreshObservation(identity: AudioFileReadIdentity.read(at: path), volumeID: "replacement-volume")
        })
        let plan = try await planner.makePlan(request: .incremental, snapshot: snapshot, indexedFiles: fixture.files,
                                              previousRecords: fixture.records, dirtyFileIDs: [], dirtyPaths: [], analysis: analysis)
        XCTAssertEqual(plan.refreshPaths, [Data(missing.utf8), Data(replaced.utf8)])
    }
}

private struct PlannerFixture {
    let directory: URL
    let source: SeratoSourceIdentity
    let records: [SeratoTrackRecord]
    let files: [FileRecord]
    let evidence: [Int64: SyncFileEvidence]

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("database V2")
        try SeratoTestEncoding.library(paths: []).write(to: sourceURL)
        source = try SeratoSourceIdentity.read(sourceURL)
        var builtFiles: [FileRecord] = []
        var builtRecords: [SeratoTrackRecord] = []
        var builtEvidence: [Int64: SyncFileEvidence] = [:]
        for identifier in 1 ... 3 {
            let fileURL = directory.appendingPathComponent("track-\(identifier).wav")
            try Data([1, 2, 3]).write(to: fileURL)
            let identity = try XCTUnwrap(FileMetadataCollector.collect(at: fileURL.path, includeLightweightHash: true))
            var file = FileRecord(path: identity.path, volumeUuid: identity.volumeUuid, inode: identity.inode, fileSize: identity.fileSize, mtime: identity.mtime)
            file.id = Int64(identifier)
            file.lightweightHash = identity.lightweightHash
            file.libraryMembership = .active
            file.fileAvailability = .available
            file.seratoLibraryId = "fixture"
            file.title = "Title \(identifier)"
            builtFiles.append(file)
            builtRecords.append(SeratoTrackRecord(path: file.path, artist: nil, title: file.title, album: nil, genre: nil, bpm: nil, key: nil, comment: nil, length: nil, label: nil))
            builtEvidence[Int64(identifier)] = try SyncFileEvidence(fileID: Int64(identifier), membershipRevision: 0, identity: identity,
                                                                    readIdentity: AudioFileReadIdentity.read(at: file.path), bitrateProbed: true)
        }
        files = builtFiles
        records = builtRecords
        evidence = builtEvidence
    }

    func cleanup() {
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Planner fixture cleanup failed: \(error)") }
    }
}
