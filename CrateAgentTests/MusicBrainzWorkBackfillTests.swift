@testable import CrateAgent
import GRDB
import XCTest

@MainActor
final class MusicBrainzWorkBackfillTests: XCTestCase {
    private var database: LibraryDatabase!
    private var engine: OperationEngine!
    private let cache = LookupCache.memory()
    private let audioFixture = OwnedProcessingAudioFixture()
    private var nextInode: Int64 = 0

    override func setUp() async throws {
        database = try LibraryDatabase.openInMemory()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        engine = OperationEngine(database: database, seratoWatchdog: watchdog,
                                 seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")),
                                 fileTagWriter: { _, _ in XCTFail("Recording a work wrote audio tags") }, fileTagReader: { _ in AudioTags.none })
    }

    override func tearDownWithError() throws {
        try audioFixture.remove()
    }

    func testRecordsTheWorkOfEachMatchedRecordingWithoutOneAsUndoableHistory() async throws {
        let mainEncoding = try await addMatchedTrack(recording: "rec-1")
        let otherEncoding = try await addMatchedTrack(recording: "rec-1")
        let alreadyKnown = try await addMatchedTrack(recording: "rec-2", work: "kept-work")
        let workless = try await addMatchedTrack(recording: "rec-3")
        let loader = try MusicBrainzSequenceLoader(bodies: [recordingBody("rec-1", work: "work-1"), recordingBody("rec-3", work: nil)])

        let backfill = makeBackfill(loader: loader)
        await backfill.run()

        XCTAssertEqual(backfill.status, .finished(.init(checked: 2, total: 2, recorded: 2)))
        XCTAssertEqual(loader.requests.compactMap { request in request.url?.pathComponents.last }, ["rec-1", "rec-3"])
        let recorded = try await works(of: [mainEncoding, otherEncoding, alreadyKnown, workless])
        XCTAssertEqual(recorded, ["work-1", "work-1", "kept-work", nil])

        let batches = try await database.writer.read { connection in
            try String.fetchAll(connection, sql: "SELECT DISTINCT batch_id FROM events WHERE event_type = ?",
                                arguments: [EventType.musicBrainzWorkRecorded.rawValue])
        }
        XCTAssertEqual(batches.count, 1)
        try await engine.undoBatch(XCTUnwrap(batches.first))
        let undone = try await works(of: [mainEncoding, otherEncoding, alreadyKnown, workless])
        XCTAssertEqual(undone, [nil, nil, "kept-work", nil])
    }

    func testStopsOnTheFirstLookupErrorAndResumesWithTheRest() async throws {
        let first = try await addMatchedTrack(recording: "rec-1")
        let second = try await addMatchedTrack(recording: "rec-2")
        let third = try await addMatchedTrack(recording: "rec-3")
        let failingLoader = try MusicBrainzSequenceLoader(bodies: [recordingBody("rec-1", work: "work-1")])

        let failing = makeBackfill(loader: failingLoader)
        await failing.run()

        guard case let .failed(progress, _) = failing.status else {
            return XCTFail("The run did not stop on the lookup error: \(failing.status)")
        }
        XCTAssertEqual(progress, .init(checked: 1, total: 3, recorded: 1))
        XCTAssertEqual(failingLoader.requests.count, 2)
        let afterFailure = try await works(of: [first, second, third])
        XCTAssertEqual(afterFailure, ["work-1", nil, nil])

        let resumingLoader = try MusicBrainzSequenceLoader(bodies: [recordingBody("rec-2", work: "work-2"), recordingBody("rec-3", work: "work-3")])
        let resuming = makeBackfill(loader: resumingLoader)
        await resuming.run()

        XCTAssertEqual(resuming.status, .finished(.init(checked: 2, total: 2, recorded: 2)))
        XCTAssertEqual(resumingLoader.requests.compactMap { request in request.url?.pathComponents.last }, ["rec-2", "rec-3"])
        let resumed = try await works(of: [first, second, third])
        XCTAssertEqual(resumed, ["work-1", "work-2", "work-3"])
    }

    func testRecordingAWorkIsRefusedOnceTheTrackNamesAnotherRecordingOrWork() async throws {
        let rematched = try await addMatchedTrack(recording: "rec-new")
        let known = try await addMatchedTrack(recording: "rec-known", work: "kept-work")

        for payload in [
            RecordMusicBrainzWorkPayload(trackId: rematched, recordingMBID: "rec-old", workMBID: "work", previousWorkMBID: nil),
            RecordMusicBrainzWorkPayload(trackId: known, recordingMBID: "rec-known", workMBID: "work", previousWorkMBID: nil),
        ] {
            await XCTAssertThrowsErrorAsync(try await engine.apply(.recordMusicBrainzWork(payload))) { error in
                XCTAssertEqual(error as? MusicBrainzWorkError, .changedSinceLookup(trackId: payload.trackId))
            }
        }
        let recorded = try await works(of: [rematched, known])
        XCTAssertEqual(recorded, [nil, "kept-work"])
    }

    private func makeBackfill(loader: MusicBrainzSequenceLoader) -> MusicBrainzWorkBackfill {
        MusicBrainzWorkBackfill(database: database, engine: engine,
                                client: MusicBrainzClient(loader: loader, limiter: .noop, cache: cache))
    }

    private func recordingBody(_ recording: String, work: String?) throws -> Data {
        let relations: [[String: Any]] = work.map { work in [["type": "performance", "work": ["id": work]]] } ?? []
        return try JSONSerialization.data(withJSONObject: ["id": recording, "title": "Song", "releases": [], "relations": relations])
    }

    private func addMatchedTrack(recording: String, work: String? = nil) async throws -> Int64 {
        nextInode += 1
        let inode = nextInode
        return try await database.writer.write { connection in
            var track = TrackRecord(fingerprintHash: Data("fingerprint-\(inode)".utf8), musicbrainzRecordingId: recording, musicbrainzWorkId: work)
            try track.insert(connection)
            var file = FileRecord(path: self.audioFixture.path("/Music/\(inode).mp3"), volumeUuid: "volume", inode: inode, fileSize: 10, mtime: 10,
                                  artist: "Artist", title: "Song")
            file.libraryMembership = .active
            file.fileAvailability = .available
            file.trackId = track.id
            try self.audioFixture.prepare(&file)
            try file.insert(connection)
            return try XCTUnwrap(track.id)
        }
    }

    private func works(of trackIDs: [Int64]) async throws -> [String?] {
        try await database.writer.read { connection in
            try trackIDs.map { trackID in try TrackRecord.fetchOne(connection, key: trackID)?.musicbrainzWorkId }
        }
    }
}
