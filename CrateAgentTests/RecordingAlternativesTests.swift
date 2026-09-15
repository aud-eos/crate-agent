@testable import CrateAgent
import CryptoKit
import GRDB
import XCTest

@MainActor
final class RecordingAlternativesTests: XCTestCase {
    func testRetainsEveryReturnedRecordingWithHighestAssociatedSourceAndStableRanking() throws {
        let response = try JSONDecoder().decode(AcoustIDResponse.self, from: Data(#"{"status":"ok","results":[{"id":"low","score":0.2,"recordings":[{"id":"recording-c"},{"id":"recording-a"}]},{"id":"high","score":0.99,"recordings":[{"id":"recording-b"},{"id":"recording-a"}]},{"id":"tie-z","score":0.99,"recordings":[{"id":"recording-a"}]}]}"#.utf8))
        let alternatives = RecordingAlternatives(results: response.results)
        XCTAssertEqual(alternatives.entries.map(\.recordingID), ["recording-a", "recording-b", "recording-c"])
        XCTAssertEqual(alternatives.entries.map(\.acoustID), ["high", "high", "low"])
        XCTAssertEqual(alternatives.entries.map(\.score), [0.99, 0.99, 0.2])
        XCTAssertEqual(RecordingAlternatives(results: response.results.reversed()).entries, alternatives.entries)
    }

    func testKnownAliasesCollapseWithHighestScoreWhileUnknownIDsRemainConservative() throws {
        let alternatives = RecordingAlternatives(results: [
            AcoustIDResult(id: "best", score: 0.99, recordingIDs: ["old-id"]),
            AcoustIDResult(id: "other", score: 0.96, recordingIDs: ["canonical"]),
            AcoustIDResult(id: "low", score: 0.2, recordingIDs: ["unknown"]),
        ])
        let selected = try XCTUnwrap(alternatives.entries.first)
        XCTAssertFalse(alternatives.assessment(for: selected).isBulkApprovalEligible)
        let details = MBRecordingDetails(id: "canonical", title: "Song", creditedArtistName: "Artist", disambiguation: nil, durationMilliseconds: nil)
        let known = ["old-id": details]
        XCTAssertEqual(alternatives.collapsed(using: known).map(\.recordingID), ["old-id", "unknown"])
        XCTAssertTrue(alternatives.assessment(for: selected, details: known).isBulkApprovalEligible)
        let low = try XCTUnwrap(alternatives.entries.last)
        XCTAssertTrue(alternatives.assessment(for: low, details: known).isBelowStrongThreshold)
        XCTAssertFalse(alternatives.assessment(for: low, details: known).isBulkApprovalEligible)
    }

    func testInitialMetadataFailureKeepsAlternativesAndAlternateUsesOriginalBaseline() async throws {
        let database = try LibraryDatabase.openInMemory()
        let fileID = try await insertFile(in: database)
        let loader = MusicBrainzSequenceLoader(bodies: [
            Data(#"{"status":"ok","results":[{"id":"top-source","score":0.99,"recordings":[{"id":"first"}]},{"id":"chosen-source","score":0.4,"recordings":[{"id":"second"}]}]}"#.utf8),
            Data(#"{"id":"first","title":"No release"}"#.utf8),
            Data(#"{"id":"canonical-second","title":"New title","artist-credit":[{"name":"New Artist","artist":{"id":"artist-id","name":"New Artist"}}],"releases":[{"id":"other-release","title":"Other album","date":"1980"},{"id":"matching-release","title":"Original Album","date":"2002","release-group":{"id":"group","first-release-date":"1991"}}],"isrcs":["ISRC-NEW"]}"#.utf8),
        ])
        let baseline = MutableAlternativeBaseline()
        let service = makeService(database: database, loader: loader, baseline: baseline)
        await service.run(fileIDs: [fileID])
        guard case .failed = service.rows[fileID] else { return XCTFail("No releases must be an explicit failure") }
        XCTAssertEqual(service.recordingAlternatives[fileID]?.entries.map(\.recordingID), ["first", "second"])
        baseline.replaceTagsAndFreshness()
        let candidate = try await service.resolveAlternative(fileID: fileID, recordingID: "second")
        XCTAssertEqual(candidate.recordingMBID, "canonical-second")
        XCTAssertEqual(candidate.acoustID, "chosen-source")
        XCTAssertEqual(candidate.score, 0.4)
        XCTAssertEqual(candidate.artistMBID, "artist-id")
        XCTAssertEqual(candidate.chosenRelease.id, "matching-release")
        XCTAssertEqual(candidate.availableReleases.count, 2)
        XCTAssertEqual(candidate.proposedYear, 1991)
        XCTAssertEqual(candidate.currentFileArtist, "Original Artist")
        XCTAssertEqual(candidate.currentFileTitle, "Original Title")
        XCTAssertEqual(candidate.currentFileAlbum, "Original Album")
        XCTAssertEqual(candidate.currentFileYear, 1999)
        XCTAssertEqual(candidate.expectedFileSize, 1000)
        XCTAssertEqual(candidate.expectedMtime, 10)
        XCTAssertEqual(candidate.fingerprintHash, Data(SHA256.hash(data: FingerprintEncoder.serialize([1, 2, 3]))))
        let row = AutoTagRowModel(candidate: candidate)
        XCTAssertEqual(row.currentArtist, "Original Artist")
        XCTAssertFalse(row.includeAlbum, "Release defaults must still match the original album")
        XCTAssertTrue(row.includeYear)
        let payload = row.payload()
        XCTAssertEqual(payload.recordingMBID, "canonical-second")
        XCTAssertEqual(payload.acoustID, "chosen-source")
        XCTAssertEqual(payload.releaseMBID, "matching-release")
        XCTAssertEqual(payload.currentFileTitle, "Original Title")
        XCTAssertEqual(payload.expectedMtime, 10)
        XCTAssertEqual(service.matchAssessment(for: candidate)?.score, 0.4)
        XCTAssertEqual(service.matchAssessment(for: candidate)?.isBulkApprovalEligible, false)
        XCTAssertNil(service.candidate(for: fileID), "Resolution returns a proposal; only the session commits the switch")
        await XCTAssertThrowsErrorAsync(try await service.resolveAlternative(fileID: fileID, recordingID: "not-returned"))
        XCTAssertEqual(loader.requests.count, 3, "Unknown IDs must never start a network request")
        await service.run(fileIDs: [])
        XCTAssertTrue(service.recordingAlternatives.isEmpty)
        await XCTAssertThrowsErrorAsync(try await service.resolveAlternative(fileID: fileID, recordingID: "second"))
    }

    func testDetailPagesAreBoundedAndFailedEntriesRemainRetryable() async throws {
        let database = try LibraryDatabase.openInMemory()
        let fileID = try await insertFile(in: database)
        let recordings = (0 ..< 12).map { index in ["id": String(format: "recording-%02d", index)] }
        let acoustID = try JSONSerialization.data(withJSONObject: ["status": "ok", "results": [["id": "shared", "score": 0.98, "recordings": recordings]]])
        var responses = [acoustID, Data(#"{"id":"recording-00","title":"Initial","releases":[{"id":"release","title":"Album"}]}"#.utf8)]
        for index in 1 ..< 10 {
            responses.append(index == 3 ? Data("broken".utf8) : detailData(index: index))
        }
        responses += [detailData(index: 3), detailData(index: 10), detailData(index: 11)]
        let loader = MusicBrainzSequenceLoader(bodies: responses)
        let service = makeService(database: database, loader: loader, baseline: MutableAlternativeBaseline())
        await service.run(fileIDs: [fileID])
        XCTAssertEqual(loader.requests.count, 2, "The initial scan must not fan out metadata requests")
        let firstPage = try await service.loadAlternativeDetails(fileID: fileID, offset: 0)
        XCTAssertEqual(firstPage.count, 10)
        XCTAssertEqual(loader.requests.count, 11, "Initial selected details must be reused")
        guard firstPage.count == 10 else { return }
        guard case let .failed(reason) = firstPage[3].state else { return XCTFail("Failed details must keep their entry") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(firstPage[3].alternative.recordingID, "recording-03")
        let retry = try await service.loadAlternativeDetails(fileID: fileID, offset: 3, limit: 1)
        guard case let .loaded(details) = try XCTUnwrap(retry.first).state else { return XCTFail("Retry should load the failed entry") }
        XCTAssertEqual(details.id, "recording-03")
        let secondPage = try await service.loadAlternativeDetails(fileID: fileID, offset: 10)
        XCTAssertEqual(secondPage.map(\.alternative.recordingID), ["recording-10", "recording-11"])
        XCTAssertEqual(loader.requests.count, 14)
        let emptyPage = try await service.loadAlternativeDetails(fileID: fileID, offset: 12)
        XCTAssertTrue(emptyPage.isEmpty)
        await XCTAssertThrowsErrorAsync(try await service.loadAlternativeDetails(fileID: fileID, offset: -1))
    }

    func testCanonicalSelectionReusesCompleteMetadataAndFailedSwitchPreservesCandidate() async throws {
        let database = try LibraryDatabase.openInMemory()
        let fileID = try await insertFile(in: database)
        let loader = MusicBrainzSequenceLoader(bodies: [
            Data(#"{"status":"ok","results":[{"id":"top","score":0.99,"recordings":[{"id":"alias"}]},{"id":"lower","score":0.2,"recordings":[{"id":"no-release"}]}]}"#.utf8),
            Data(#"{"id":"canonical","title":"Current proposal","releases":[{"id":"release","title":"Album"}]}"#.utf8),
            Data(#"{"id":"no-release","title":"No usable release"}"#.utf8),
        ])
        let service = makeService(database: database, loader: loader, baseline: MutableAlternativeBaseline())
        await service.run(fileIDs: [fileID])
        let original = try XCTUnwrap(service.candidate(for: fileID))
        let sameCanonical = try await service.resolveAlternative(fileID: fileID, recordingID: "canonical")
        XCTAssertEqual(sameCanonical, original)
        XCTAssertEqual(loader.requests.count, 2)
        await XCTAssertThrowsErrorAsync(try await service.resolveAlternative(fileID: fileID, recordingID: "no-release"))
        XCTAssertEqual(service.candidate(for: fileID), original)
        XCTAssertEqual(loader.requests.count, 3)
        service.cancel()
        XCTAssertEqual(service.candidate(for: fileID), original)
        XCTAssertEqual(service.recordingAlternatives[fileID]?.entries.count, 2)
    }

    func testNewScanAndStopInvalidateDelayedDetailAndSelectionResponses() async throws {
        for loadDetails in [true, false] {
            for resetScan in [true, false] {
                let database = try LibraryDatabase.openInMemory()
                let fileID = try await insertFile(in: database)
                let underlying = MusicBrainzSequenceLoader(bodies: [
                    Data(#"{"status":"ok","results":[{"id":"source","score":0.99,"recordings":[{"id":"first"},{"id":"second"}]}]}"#.utf8),
                    Data(#"{"id":"first","title":"First","releases":[{"id":"release-first","title":"First album"}]}"#.utf8),
                    Data(#"{"id":"second","title":"Second","releases":[{"id":"release-second","title":"Second album"}]}"#.utf8),
                ])
                let started = AlternativeAsyncGate()
                let release = AlternativeAsyncGate()
                let loader = GatedAlternativeLoader(underlying: underlying, started: started, release: release)
                let service = makeService(database: database, loader: loader, baseline: MutableAlternativeBaseline())
                await service.run(fileIDs: [fileID])
                let task = Task {
                    if loadDetails {
                        _ = try await service.loadAlternativeDetails(fileID: fileID, offset: 1, limit: 1)
                    } else {
                        _ = try await service.resolveAlternative(fileID: fileID, recordingID: "second")
                    }
                }
                await started.wait()
                if resetScan {
                    await service.run(fileIDs: [])
                } else {
                    service.cancel()
                }
                await release.open()
                await XCTAssertThrowsErrorAsync(try await task.value) { error in
                    XCTAssertTrue(error is CancellationError)
                }
                XCTAssertNil(service.recordingDetails[fileID]?["second"])
                if resetScan {
                    XCTAssertTrue(service.recordingAlternatives.isEmpty)
                    XCTAssertTrue(service.rows.isEmpty)
                } else {
                    XCTAssertEqual(service.candidate(for: fileID)?.recordingMBID, "first")
                    XCTAssertEqual(service.recordingAlternatives[fileID]?.entries.count, 2)
                }
            }
        }
    }

    func testLearningAliasesDoesNotReplaceTheSelectedCandidatesAudioScore() async throws {
        let database = try LibraryDatabase.openInMemory()
        let fileID = try await insertFile(in: database)
        let loader = MusicBrainzSequenceLoader(bodies: [
            Data(#"{"status":"ok","results":[{"id":"top","score":0.99,"recordings":[{"id":"first"}]},{"id":"other","score":0.95,"recordings":[{"id":"unknown-alias"}]},{"id":"selected","score":0.4,"recordings":[{"id":"second"}]}]}"#.utf8),
            Data(#"{"id":"first","title":"First","releases":[{"id":"release-first","title":"First album"}]}"#.utf8),
            Data(#"{"id":"second","title":"Second","releases":[{"id":"release-second","title":"Second album"}]}"#.utf8),
            Data(#"{"id":"second","title":"Second"}"#.utf8),
        ])
        let service = makeService(database: database, loader: loader, baseline: MutableAlternativeBaseline())
        await service.run(fileIDs: [fileID])
        let selected = try await service.resolveAlternative(fileID: fileID, recordingID: "second")
        _ = try await service.loadAlternativeDetails(fileID: fileID, offset: 1, limit: 1)
        XCTAssertEqual(service.matchAssessment(for: selected)?.score, 0.4)
        XCTAssertEqual(service.matchAssessment(for: selected)?.isBelowStrongThreshold, true)
        XCTAssertEqual(service.matchAssessment(for: selected)?.isBulkApprovalEligible, false)
        XCTAssertEqual(service.recordingAlternatives[fileID]?.collapsed(using: service.recordingDetails[fileID] ?? [:]).map(\.acoustID), ["top", "other"])
    }

    func testInitialResolutionPreservesAlternativeDetailsLoadedDuringItsRequest() async throws {
        for loadDetails in [true, false] {
            let database = try LibraryDatabase.openInMemory()
            let fileID = try await insertFile(in: database)
            let underlying = MusicBrainzSequenceLoader(bodies: [
                Data(#"{"status":"ok","results":[{"id":"top","score":0.99,"recordings":[{"id":"first"}]},{"id":"alternate","score":0.96,"recordings":[{"id":"second"}]}]}"#.utf8),
                Data(#"{"id":"canonical","title":"Song","releases":[{"id":"release","title":"Album"}]}"#.utf8),
                Data(#"{"id":"canonical","title":"Song","releases":[{"id":"release","title":"Album"}]}"#.utf8),
            ])
            let started = AlternativeAsyncGate()
            let release = AlternativeAsyncGate()
            let loader = GatedAlternativeLoader(underlying: underlying, started: started, release: release, blockedRecordingID: "first")
            let service = makeService(database: database, loader: loader, baseline: MutableAlternativeBaseline())
            let scan = Task { await service.run(fileIDs: [fileID]) }
            await started.wait()
            do {
                if loadDetails {
                    _ = try await service.loadAlternativeDetails(fileID: fileID, offset: 1, limit: 1)
                } else {
                    _ = try await service.resolveAlternative(fileID: fileID, recordingID: "second")
                }
            } catch {
                await release.open()
                await scan.value
                throw error
            }
            XCTAssertEqual(service.recordingDetails[fileID]?["second"]?.id, "canonical")
            await release.open()
            await scan.value
            XCTAssertEqual(service.recordingDetails[fileID]?["second"]?.id, "canonical", "Initial completion must preserve metadata loaded by the chooser")
            XCTAssertEqual(service.recordingDetails[fileID]?["first"]?.id, "canonical")
            let candidate = try XCTUnwrap(service.candidate(for: fileID))
            XCTAssertEqual(service.matchAssessment(for: candidate)?.plausibleRecordingCount, 1)
            XCTAssertEqual(service.matchAssessment(for: candidate)?.isBulkApprovalEligible, true)
        }
    }

    private func detailData(index: Int) -> Data {
        Data("{\"id\":\"recording-\(String(format: "%02d", index))\",\"title\":\"Title \(index)\"}".utf8)
    }

    private func insertFile(in database: LibraryDatabase) async throws -> Int64 {
        let fileID = try await database.writer.write { connection in
            var file = FileRecord(path: "/fixture/alternative.mp3", volumeUuid: "TEST", inode: 1, fileSize: 1000, mtime: 10,
                                  chromaprintFingerprint: FingerprintEncoder.serialize([1, 2, 3]), fingerprintStatus: .done,
                                  album: "Stale library album")
            try file.insert(connection)
            return try XCTUnwrap(file.id)
        }
        try await markProcessingFixturesAvailable(in: database)
        return fileID
    }

    private func makeService(database: LibraryDatabase, loader: URLLoading, baseline: MutableAlternativeBaseline) -> AutoTaggerService {
        AutoTaggerService(database: database,
                          acoustIDClient: AcoustIDClient(loader: loader, limiter: .noop, cache: .memory()),
                          musicBrainzClient: MusicBrainzClient(loader: loader, limiter: .noop, cache: .memory()),
                          keyStore: AlternativeTestKeyProvider(),
                          audioTagsReader: { _ in baseline.tags }, fileFreshnessReader: { _ in baseline.freshness })
    }
}

private struct GatedAlternativeLoader: URLLoading {
    let underlying: MusicBrainzSequenceLoader
    let started: AlternativeAsyncGate
    let release: AlternativeAsyncGate
    let blockedRecordingID: String

    init(underlying: MusicBrainzSequenceLoader, started: AlternativeAsyncGate, release: AlternativeAsyncGate, blockedRecordingID: String = "second") {
        self.underlying = underlying
        self.started = started
        self.release = release
        self.blockedRecordingID = blockedRecordingID
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.url?.lastPathComponent == blockedRecordingID {
            await started.open()
            await release.wait()
        }
        return try await underlying.data(for: request)
    }
}

private actor AlternativeAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }
}

private struct AlternativeTestKeyProvider: AcoustIDKeyProviding {
    func load() throws -> String? {
        "fixture-key"
    }
}

private final class MutableAlternativeBaseline: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    var tags: AudioTags {
        lock.withLock {
            AudioTags(bitrateKbps: nil, title: changed ? "Changed title" : "Original Title",
                      artist: changed ? "Changed artist" : "Original Artist", album: changed ? "Changed album" : "Original Album",
                      albumArtist: nil, genre: nil, year: changed ? 2026 : 1999, trackNumber: nil, totalTracks: nil,
                      bpm: nil, comment: nil, durationSeconds: 200)
        }
    }

    var freshness: FileFreshnessSnapshot {
        lock.withLock { FileFreshnessSnapshot(fileSize: changed ? 2000 : 1000, mtime: changed ? 20 : 10) }
    }

    func replaceTagsAndFreshness() {
        lock.withLock { changed = true }
    }
}
