@testable import CrateAgent
import GRDB
import XCTest

@MainActor
final class AutoTaggerServiceTests: XCTestCase {
    func testCompletedReviewCanChooseAlternativeAfterSyncButNotAfterRetirement() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("review.mp3")
        let recording = makeRecording()
        let service = AutoTaggerService(database: fixture.database,
                                        acoustIDClient: StubAcoustIDClient { _ in [AcoustIDResult(id: "review", score: 0.99, recordingIDs: ["recording"])] },
                                        musicBrainzClient: StubMusicBrainzClient { _ in recording }, keyStore: StubKeyProvider(),
                                        fingerprintFunction: { _ in [1, 2, 3] }, audioTagsReader: stubAudioTagsReader(), readiness: gate)
        try gate.markReady(gate.prepareDrain())
        await service.run(fileIDs: [file.id!])
        XCTAssertNotNil(service.candidate(for: file.id!))
        gate.invalidate()
        service.cancel()
        try gate.markReady(gate.prepareDrain())
        do {
            let alternatives = try await service.loadAlternativeDetails(fileID: file.id!, offset: 0)
            XCTAssertEqual(alternatives.count, 1)
            let alternative = try await service.resolveAlternative(fileID: file.id!, recordingID: "recording")
            XCTAssertEqual(alternative.fileID, file.id)
        } catch { XCTFail("Completed current review was rejected after synchronization: \(error)") }
        _ = try await fixture.reconcile()
        do {
            _ = try await service.resolveAlternative(fileID: file.id!, recordingID: "recording")
            XCTFail("Retired candidate regained authority")
        } catch is FileProcessingEligibilityError {}
    }

    func testSyncGenerationInvalidationStopsDecodeWithoutPersistingFailure() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("lookup.mp3")
        let started = expectation(description: "Lookup decoder entered")
        let release = DispatchSemaphore(value: 0)
        let recording = makeRecording()
        let service = AutoTaggerService(database: fixture.database,
                                        acoustIDClient: StubAcoustIDClient { _ in [] },
                                        musicBrainzClient: StubMusicBrainzClient { _ in recording }, keyStore: StubKeyProvider(),
                                        fingerprintFunction: { _ in started.fulfill(); release.wait(); return [1, 2, 3] },
                                        audioTagsReader: stubAudioTagsReader(), readiness: gate)
        try gate.markReady(gate.prepareDrain())
        let task = Task { await service.run(fileIDs: [file.id!]) }
        await fulfillment(of: [started], timeout: 5)
        gate.invalidate()
        try gate.markReady(gate.prepareDrain())
        release.signal()
        await task.value
        let current = try await fixture.row(file)
        XCTAssertNil(current.chromaprintFingerprint)
        XCTAssertEqual(current.fingerprintStatus, .pending)
        guard case .stopped = service.rows[file.id!] else { return XCTFail("Expected superseded pass to stop") }
        XCTAssertNil(service.fatalError)
    }

    private var inodeCounter: Int64 = 0

    // MARK: - Fixtures

    private func makeDatabase() throws -> LibraryDatabase {
        try LibraryDatabase.openInMemory()
    }

    @discardableResult
    private func insertFile(
        in database: LibraryDatabase,
        path: String,
        album: String? = nil,
        fingerprintHashes: [UInt32]? = [1, 2, 3],
        fingerprintStatus: FingerprintStatus = .done
    ) throws -> Int64 {
        inodeCounter += 1
        var record = FileRecord(
            path: path,
            volumeUuid: "VOL",
            inode: inodeCounter,
            fileSize: 1000,
            mtime: 0,
            chromaprintFingerprint: fingerprintHashes.map(FingerprintEncoder.serialize),
            fingerprintStatus: fingerprintStatus,
            album: album
        )
        record.libraryMembership = .active
        record.fileAvailability = .available
        try database.writer.write { db in
            try record.insert(db)
        }
        return try XCTUnwrap(record.id)
    }

    private func fingerprintBase64(for hashes: [UInt32]) -> String {
        FingerprintEncoder.base64(fromStoredBytes: FingerprintEncoder.serialize(hashes))!
    }

    private func makeRecording(
        title: String = "Test Title",
        artistName: String = "Test Artist",
        releaseDate: String = "1994-04-19"
    ) -> MBRecording {
        let releaseGroup = MBReleaseGroup(id: "rg-1", firstReleaseDate: releaseDate)
        let release = MBRelease(
            id: "release-1",
            title: "Test Album",
            date: releaseDate,
            country: "US",
            status: "Official",
            releaseGroup: releaseGroup
        )
        return MBRecording(
            title: title,
            artistCredit: [MBArtistCredit(name: artistName, artist: MBArtist(id: "artist-1", name: artistName))],
            releases: [release],
            releaseGroup: releaseGroup,
            isrcs: ["US1234567890"]
        )
    }

    private func stubAudioTagsReader(durationSeconds: UInt64? = 200) -> AudioTagsReading {
        { _ in
            AudioTags(
                bitrateKbps: nil, title: nil, artist: nil, album: nil, albumArtist: nil,
                genre: nil, year: nil, trackNumber: nil, totalTracks: nil, bpm: nil,
                comment: nil, durationSeconds: durationSeconds
            )
        }
    }

    func testUsesCanonicalRecordingIdentityFromRealClientResponseAndCache() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/merged.mp3")
        let response = Data(#"{"id":"canonical-id","title":"Song","releases":[{"id":"release","title":"Album","release-group":{"id":"group","first-release-date":"1980"}}]}"#.utf8)
        let loader = MusicBrainzSequenceLoader(bodies: [response])
        let client = MusicBrainzClient(loader: loader, limiter: .noop, cache: .memory())
        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in [AcoustIDResult(id: "match", score: 0.99, recordingIDs: ["merged-id"])] },
            musicBrainzClient: client, keyStore: StubKeyProvider(), audioTagsReader: stubAudioTagsReader()
        )
        await service.run(fileIDs: [fileID])
        XCTAssertEqual(service.candidate(for: fileID)?.recordingMBID, "canonical-id")
        await service.run(fileIDs: [fileID])
        XCTAssertEqual(service.candidate(for: fileID)?.recordingMBID, "canonical-id")
        XCTAssertEqual(loader.requests.count, 1)
    }

    func testNewScanEvictsCompletedRowsOutsideItsSelection() async throws {
        let database = try makeDatabase()
        let firstID = try insertFile(in: database, path: "/music/first.mp3")
        let secondID = try insertFile(in: database, path: "/music/second.mp3")
        let recording = makeRecording()
        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in
                [AcoustIDResult(id: "match-1", score: 0.99, recordingIDs: ["recording-1"])]
            },
            musicBrainzClient: StubMusicBrainzClient { _ in recording },
            keyStore: StubKeyProvider(),
            audioTagsReader: stubAudioTagsReader()
        )
        await service.run(fileIDs: [firstID])
        XCTAssertNotNil(service.candidate(for: firstID))
        await service.run(fileIDs: [secondID, secondID])
        XCTAssertEqual(Set(service.rows.keys), [secondID])
        XCTAssertNil(service.candidate(for: firstID))
        await service.run(fileIDs: [])
        XCTAssertTrue(service.rows.isEmpty)
    }

    func testFailedRecomputeClearsStaleCompletedFingerprint() async throws {
        let database = try makeDatabase()
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-audio-\(UUID().uuidString).mp3")
        try Data(repeating: 0, count: 2000).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let fileID = try insertFile(in: database, path: audioURL.path)
        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in
                XCTFail("invalid audio must fail before lookup")
                return []
            },
            musicBrainzClient: StubMusicBrainzClient { _ in throw LookupError.transport("unreachable") },
            keyStore: StubKeyProvider()
        )
        await service.run(fileIDs: [fileID])
        guard case .failed = service.rows[fileID] else { return XCTFail("expected a decode failure") }
        let persisted = try await database.writer.read { db in try FileRecord.fetchOne(db, key: fileID) }
        XCTAssertEqual(persisted?.fingerprintStatus, .failed)
        XCTAssertNil(persisted?.chromaprintFingerprint)
    }

    func testFailedStaleRecomputePreservesNewerCompletedFingerprint() async throws {
        let database = try makeDatabase()
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("changed-audio-\(UUID().uuidString).mp3")
        try Data(repeating: 0, count: 2000).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let fileID = try insertFile(in: database, path: audioURL.path)
        let newerBytes = FingerprintEncoder.serialize([9, 8, 7])
        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in [] },
            musicBrainzClient: StubMusicBrainzClient { _ in throw LookupError.transport("unreachable") },
            keyStore: StubKeyProvider(),
            fingerprintFunction: { _ in
                try database.writer.write { db in
                    _ = try FingerprintPersistence.write(fileID: fileID, fingerprint: newerBytes, status: .done,
                                                     freshnessBasis: FileFreshnessSnapshot(fileSize: 2000, mtime: 123), in: db)
                }
                throw NSError(domain: "decode-test", code: 1)
            }
        )
        await service.run(fileIDs: [fileID])
        let persisted = try await database.writer.read { db in try FileRecord.fetchOne(db, key: fileID) }
        XCTAssertEqual(persisted?.fingerprintStatus, .done)
        XCTAssertEqual(persisted?.chromaprintFingerprint, newerBytes)
        XCTAssertEqual(persisted?.fingerprintedMtime, 123)
    }

    // MARK: - Classification

    func testClassifiesStrongWeakAndNoMatch() async throws {
        let database = try makeDatabase()
        let strongHashes: [UInt32] = [1, 2, 3]
        let weakHashes: [UInt32] = [4, 5, 6]
        let noMatchHashes: [UInt32] = [7, 8, 9]

        let strongFileID = try insertFile(in: database, path: "/music/strong.mp3", fingerprintHashes: strongHashes)
        let weakFileID = try insertFile(in: database, path: "/music/weak.mp3", fingerprintHashes: weakHashes)
        let noMatchFileID = try insertFile(in: database, path: "/music/nomatch.mp3", fingerprintHashes: noMatchHashes)

        let strongBase64 = fingerprintBase64(for: strongHashes)
        let weakBase64 = fingerprintBase64(for: weakHashes)
        let noMatchBase64 = fingerprintBase64(for: noMatchHashes)

        let acoustIDClient = StubAcoustIDClient { base64 in
            switch base64 {
            case strongBase64:
                return [AcoustIDResult(id: "a-strong", score: 0.98, recordingIDs: ["mb-strong"])]
            case weakBase64:
                return [AcoustIDResult(id: "a-weak", score: 0.7, recordingIDs: ["mb-weak"])]
            case noMatchBase64:
                return []
            default:
                XCTFail("unexpected fingerprint \(base64)")
                return []
            }
        }
        let recording = makeRecording()
        let musicBrainzClient = StubMusicBrainzClient { _ in recording }

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: musicBrainzClient,
            keyStore: StubKeyProvider(),
            audioTagsReader: stubAudioTagsReader()
        )

        await service.run(fileIDs: [strongFileID, weakFileID, noMatchFileID])

        guard case let .strong(strongCandidate) = service.rows[strongFileID] else {
            return XCTFail("expected .strong, got \(String(describing: service.rows[strongFileID]))")
        }
        XCTAssertEqual(strongCandidate.score, 0.98)
        XCTAssertEqual(strongCandidate.recordingMBID, "mb-strong")

        guard case let .weak(weakCandidate) = service.rows[weakFileID] else {
            return XCTFail("expected .weak, got \(String(describing: service.rows[weakFileID]))")
        }
        XCTAssertEqual(weakCandidate.score, 0.7)

        XCTAssertEqual(service.rows[noMatchFileID], .noMatch)
        XCTAssertNil(service.fatalError)
    }

    /// A 401 from the KEYLESS MusicBrainz request must not be reported as a
    /// rejected AcoustID key (the AcoustID request already succeeded), and must
    /// not halt the whole pass. It is a per-row `.failed` with a service-neutral
    /// message (finding #4001501075).
    func testMusicBrainz401IsNotReportedAsRejectedAcoustIDKey() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/x.mp3")

        let acoustIDClient = StubAcoustIDClient { _ in
            [AcoustIDResult(id: "a", score: 0.95, recordingIDs: ["mb-1"])]
        }
        let musicBrainzClient = StubMusicBrainzClient { _ in throw LookupError.unauthorized }

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: musicBrainzClient,
            keyStore: StubKeyProvider(),
            audioTagsReader: stubAudioTagsReader()
        )

        await service.run(fileIDs: [fileID])

        guard case let .failed(reason) = service.rows[fileID] else {
            return XCTFail("expected per-row .failed (a MusicBrainz 401 must not halt the pass), got \(String(describing: service.rows[fileID]))")
        }
        XCTAssertFalse(
            reason.contains("AcoustID"),
            "a MusicBrainz 401 must not blame the AcoustID key; reason was: \(reason)"
        )
        XCTAssertTrue(reason.contains("MusicBrainz"), "the reason should name MusicBrainz; was: \(reason)")
        XCTAssertNil(service.fatalError, "a MusicBrainz 401 must not halt the whole pass")
    }

    /// A cancelled lookup (New Scan / left Auto-Tag) now propagates
    /// `CancellationError` because backoff sleeps stopped swallowing it
    /// (#4001501076). The pass must stop silently — never stamp a spurious
    /// `.failed(CancellationError())` on the in-flight row.
    func testCancelledLookupDoesNotStampSpuriousFailedRow() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/x.mp3")

        let acoustIDClient = StubAcoustIDClient { _ in throw CancellationError() }
        let unreachableRecording = makeRecording()
        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: StubMusicBrainzClient { _ in
                XCTFail("MusicBrainz should not be reached after a cancelled AcoustID lookup")
                return unreachableRecording
            },
            keyStore: StubKeyProvider(),
            audioTagsReader: stubAudioTagsReader()
        )

        await service.run(fileIDs: [fileID])

        if case .failed = service.rows[fileID] {
            XCTFail("a cancelled lookup must not stamp a .failed row; got \(String(describing: service.rows[fileID]))")
        }
        XCTAssertNil(service.fatalError, "cancellation is not a fatal pass error")
    }

    // MARK: - E-A: an empty ASSEMBLED artist name is nil, not just an empty credit array

    /// A recording whose `artistCredit` is NON-empty but whose entries all
    /// resolve to an empty display name (e.g. every credited artist's name
    /// is itself empty) must still propose `nil`, not `""` — the nil check
    /// has to be on the assembled string (`creditedArtistName`), not just
    /// `artistCredit.isEmpty`, or this narrow case reopens the exact
    /// artist-blanking bug E-A exists to close.
    func testEmptyAssembledArtistNameFromNonEmptyCreditProposesNil() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/sparse.mp3")

        let acoustIDClient = StubAcoustIDClient { _ in
            [AcoustIDResult(id: "a", score: 0.95, recordingIDs: ["mb-1"])]
        }
        // Non-empty artistCredit array, but the one entry's name is empty —
        // creditedArtistName assembles to "".
        let recording = makeRecording(artistName: "")
        let musicBrainzClient = StubMusicBrainzClient { _ in recording }

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: musicBrainzClient,
            keyStore: StubKeyProvider(),
            audioTagsReader: stubAudioTagsReader()
        )

        await service.run(fileIDs: [fileID])

        // Sanity: the recording's credit array itself is non-empty (one
        // entry, whose name is empty) — the array-level check alone would
        // have let this case slip through as `.artistCredit.isEmpty ==
        // false`.
        XCTAssertFalse(recording.artistCredit.isEmpty)

        guard let candidate = service.candidate(for: fileID) else {
            return XCTFail("expected a resolved candidate, got \(String(describing: service.rows[fileID]))")
        }
        XCTAssertNil(candidate.proposedArtist, "an empty assembled name must propose nil, never \"\"")

        let model = AutoTagRowModel(candidate: candidate)
        XCTAssertFalse(model.includeArtist, "nil proposal must never default to included")
        XCTAssertNil(model.payload().artist, "Confirm-All must never blank the existing artist")
    }

    // MARK: - Per-row failure isolation

    func testPerRowFailureIsolated() async throws {
        let database = try makeDatabase()
        let goodHashes: [UInt32] = [10, 11, 12]
        let badHashes: [UInt32] = [13, 14, 15]

        let goodFileID = try insertFile(in: database, path: "/music/good.mp3", fingerprintHashes: goodHashes)
        let badFileID = try insertFile(in: database, path: "/music/bad.mp3", fingerprintHashes: badHashes)

        let goodBase64 = fingerprintBase64(for: goodHashes)
        let badBase64 = fingerprintBase64(for: badHashes)

        let acoustIDClient = StubAcoustIDClient { base64 in
            if base64 == badBase64 {
                throw LookupError.transport("simulated transport failure")
            }
            XCTAssertEqual(base64, goodBase64)
            return [AcoustIDResult(id: "a-good", score: 0.95, recordingIDs: ["mb-good"])]
        }
        let recording = makeRecording()
        let musicBrainzClient = StubMusicBrainzClient { _ in recording }

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: musicBrainzClient,
            keyStore: StubKeyProvider(),
            audioTagsReader: stubAudioTagsReader()
        )

        // Bad file first, to prove the failure doesn't abort files after it.
        await service.run(fileIDs: [badFileID, goodFileID])

        guard case let .failed(reason) = service.rows[badFileID] else {
            return XCTFail("expected .failed, got \(String(describing: service.rows[badFileID]))")
        }
        XCTAssertTrue(reason.contains("simulated transport failure"), "reason was: \(reason)")

        guard case .strong = service.rows[goodFileID] else {
            return XCTFail("expected the other row to still resolve, got \(String(describing: service.rows[goodFileID]))")
        }
        XCTAssertNil(service.fatalError)
    }

    // MARK: - Fatal halts

    func testUnauthorizedHaltsPassWithFatalBanner() async throws {
        let database = try makeDatabase()
        let fileA = try insertFile(in: database, path: "/music/a.mp3", fingerprintHashes: [20, 21, 22])
        let fileB = try insertFile(in: database, path: "/music/b.mp3", fingerprintHashes: [23, 24, 25])

        let acoustIDClient = StubAcoustIDClient { _ in throw LookupError.unauthorized }
        let musicBrainzClient = StubMusicBrainzClient { _ in
            XCTFail("MusicBrainz should never be reached when AcoustID is unauthorized")
            throw LookupError.transport("unreachable")
        }

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: musicBrainzClient,
            keyStore: StubKeyProvider(),
            audioTagsReader: stubAudioTagsReader()
        )

        await service.run(fileIDs: [fileA, fileB])

        let fatalMessage = try XCTUnwrap(service.fatalError)
        XCTAssertTrue(fatalMessage.lowercased().contains("unauthorized"), "message was: \(fatalMessage)")
        // The pass stops at the first file — the second is never attempted
        // — but neither row is left looking permanently "Looking up…":
        // both transition to the terminal .stopped state.
        // Each stopped row carries only the bare reason; the banner wraps
        // it as "Auto-tag pass stopped: …" so the view (which prefixes
        // "Stopped — ") never reads "Stopped — Auto-tag pass stopped: …".
        guard case let .stopped(fileAReason) = service.rows[fileA] else {
            return XCTFail("expected fileA .stopped, got \(String(describing: service.rows[fileA]))")
        }
        XCTAssertEqual(fatalMessage, "Auto-tag pass stopped: \(fileAReason)")
        XCTAssertFalse(fileAReason.contains("Auto-tag pass stopped"))
        guard case let .stopped(fileBReason) = service.rows[fileB] else {
            return XCTFail("expected fileB .stopped, got \(String(describing: service.rows[fileB]))")
        }
        XCTAssertEqual(fileBReason, fileAReason)
    }

    /// A connection-wide `.offline` failure (machine offline / DNS down / host
    /// unreachable) halts the whole pass like `.unauthorized`/`.server` —
    /// every remaining file would fail identically, so the scan must not
    /// hammer a dead connection once per row (finding #3999114468).
    func testOfflineHaltsPassWithFatalBanner() async throws {
        let database = try makeDatabase()
        let fileA = try insertFile(in: database, path: "/music/a.mp3", fingerprintHashes: [20, 21, 22])
        let fileB = try insertFile(in: database, path: "/music/b.mp3", fingerprintHashes: [23, 24, 25])

        let lookupCount = FingerprintCallCounter()
        let acoustIDClient = StubAcoustIDClient { _ in
            lookupCount.increment()
            throw LookupError.offline("The Internet connection appears to be offline.")
        }
        let musicBrainzClient = StubMusicBrainzClient { _ in
            XCTFail("MusicBrainz should never be reached when offline")
            throw LookupError.transport("unreachable")
        }

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: musicBrainzClient,
            keyStore: StubKeyProvider(),
            audioTagsReader: stubAudioTagsReader()
        )

        await service.run(fileIDs: [fileA, fileB])

        let fatalMessage = try XCTUnwrap(service.fatalError)
        XCTAssertTrue(fatalMessage.lowercased().contains("network"), "message was: \(fatalMessage)")
        XCTAssertEqual(lookupCount.value, 1, "the pass halts at the first offline failure, not once per file")
        guard case .stopped = service.rows[fileA] else {
            return XCTFail("expected fileA .stopped, got \(String(describing: service.rows[fileA]))")
        }
        guard case .stopped = service.rows[fileB] else {
            return XCTFail("expected fileB .stopped (never attempted), got \(String(describing: service.rows[fileB]))")
        }
    }

    func testNoKeyConfiguredYieldsFatalState() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/x.mp3")

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in
                XCTFail("should never look up without a key")
                return []
            },
            musicBrainzClient: StubMusicBrainzClient { _ in
                XCTFail("should never look up without a key")
                throw LookupError.transport("unreachable")
            },
            keyStore: StubKeyProvider(key: nil)
        )

        await service.run(fileIDs: [fileID])

        let fatalMessage = try XCTUnwrap(service.fatalError)
        XCTAssertTrue(fatalMessage.lowercased().contains("key"), "message was: \(fatalMessage)")
        guard case let .stopped(reason) = service.rows[fileID] else {
            return XCTFail("expected .stopped so the row doesn't look permanently pending, got \(String(describing: service.rows[fileID]))")
        }
        XCTAssertEqual(reason, fatalMessage)
    }

    // MARK: - E-J: a no-key re-scan never shows a stale prior-pass result

    /// Scan two files once (with a key) so one resolves `.strong` and the
    /// other `.noMatch`. Re-scan the SAME ids with the key now missing:
    /// neither may still show the prior pass's `.strong`/`.noMatch` —
    /// both must read as `.stopped` for THIS pass.
    func testNoKeyRescanNeverShowsStalePriorPassResult() async throws {
        let database = try makeDatabase()
        let matchHashes: [UInt32] = [50, 51, 52]
        let noMatchHashes: [UInt32] = [53, 54, 55]
        let matchFileID = try insertFile(in: database, path: "/music/match.mp3", fingerprintHashes: matchHashes)
        let noMatchFileID = try insertFile(in: database, path: "/music/nomatch.mp3", fingerprintHashes: noMatchHashes)

        let matchBase64 = fingerprintBase64(for: matchHashes)
        let noMatchBase64 = fingerprintBase64(for: noMatchHashes)
        let acoustIDClient = StubAcoustIDClient { base64 in
            base64 == matchBase64 ? [AcoustIDResult(id: "a", score: 0.95, recordingIDs: ["mb-1"])] : []
        }
        let recording = makeRecording()
        let musicBrainzClient = StubMusicBrainzClient { _ in recording }
        let keyStore = MutableKeyProvider(key: "TESTKEY")

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: musicBrainzClient,
            keyStore: keyStore,
            audioTagsReader: stubAudioTagsReader()
        )

        await service.run(fileIDs: [matchFileID, noMatchFileID])
        guard case .strong = service.rows[matchFileID] else {
            return XCTFail("setup: expected .strong, got \(String(describing: service.rows[matchFileID]))")
        }
        XCTAssertEqual(service.rows[noMatchFileID], .noMatch, "setup: expected .noMatch")

        // Now the key goes missing; re-scan the SAME two ids.
        keyStore.key = nil
        await service.run(fileIDs: [matchFileID, noMatchFileID])

        guard case .stopped = service.rows[matchFileID] else {
            return XCTFail(
                "stale .strong survived a keyless re-scan: \(String(describing: service.rows[matchFileID]))"
            )
        }
        guard case .stopped = service.rows[noMatchFileID] else {
            return XCTFail(
                "stale .noMatch survived a keyless re-scan: \(String(describing: service.rows[noMatchFileID]))"
            )
        }
    }

    // MARK: - Keychain failure

    func testKeychainErrorSetsFatalBanner() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/x.mp3")

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in
                XCTFail("should never look up when the key store throws")
                return []
            },
            musicBrainzClient: StubMusicBrainzClient { _ in
                XCTFail("should never look up when the key store throws")
                throw LookupError.transport("unreachable")
            },
            keyStore: StubKeyProvider(errorToThrow: FakeKeychainError())
        )

        await service.run(fileIDs: [fileID])

        let fatalMessage = try XCTUnwrap(service.fatalError)
        XCTAssertTrue(fatalMessage.lowercased().contains("keychain"), "message was: \(fatalMessage)")
        XCTAssertFalse(
            fatalMessage.contains("No AcoustID API key is configured"),
            "a real keychain error must read differently from the no-key-configured message"
        )
        guard case let .stopped(reason) = service.rows[fileID] else {
            return XCTFail("expected .stopped so the row doesn't look permanently pending, got \(String(describing: service.rows[fileID]))")
        }
        XCTAssertEqual(reason, fatalMessage)
    }

    func testLookupRejectsRetirementAndReactivation() async throws {
        for reactivate in [false, true] {
            let database = try makeDatabase()
            let fileID = try insertFile(in: database, path: "/music/race.mp3")
            let started = AsyncGate()
            let release = AsyncGate()
            let recording = makeRecording()
            let service = AutoTaggerService(database: database,
                                            acoustIDClient: SuspendingAcoustIDClient(onStart: {
                    await started.open()
                    await release.wait()
                }, result: [AcoustIDResult(id: "match", score: 0.99, recordingIDs: ["recording"])]),
                                            musicBrainzClient: StubMusicBrainzClient { _ in recording },
                                            keyStore: StubKeyProvider(), audioTagsReader: stubAudioTagsReader())
            let task = Task { await service.run(fileIDs: [fileID]) }
            await started.wait()
            try await database.writer.write { database in
                try database.execute(sql: "UPDATE files SET library_membership = ?, membership_revision = 2 WHERE id = ?", arguments: [reactivate ? "active" : "retired", fileID])
            }
            await release.open()
            await task.value
            XCTAssertNil(service.candidate(for: fileID))
            guard case .failed = service.rows[fileID] else { return XCTFail("stale lookup must fail") }
        }
    }

    // MARK: - Cancellation

    func testCancelStopsThePass() async throws {
        let database = try makeDatabase()
        let file1 = try insertFile(in: database, path: "/music/1.mp3", fingerprintHashes: [40, 41, 42])
        let file2 = try insertFile(in: database, path: "/music/2.mp3", fingerprintHashes: [43, 44, 45])
        let file3 = try insertFile(in: database, path: "/music/3.mp3", fingerprintHashes: [46, 47, 48])

        let lookupStarted = AsyncGate()
        let releaseLookup = AsyncGate()

        let acoustIDClient = SuspendingAcoustIDClient(
            onStart: {
                await lookupStarted.open()
                await releaseLookup.wait()
            },
            result: [AcoustIDResult(id: "a", score: 0.95, recordingIDs: ["mb-1"])]
        )
        let recording = makeRecording()
        let musicBrainzClient = StubMusicBrainzClient { _ in recording }

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: musicBrainzClient,
            keyStore: StubKeyProvider(),
            audioTagsReader: stubAudioTagsReader()
        )

        let runHandle = Task { await service.run(fileIDs: [file1, file2, file3]) }

        // Wait until the pass is actually inside file1's AcoustID lookup
        // before cancelling, so the cancellation deterministically lands
        // between file1 (already in flight) and file2 (not yet attempted).
        await lookupStarted.wait()
        service.cancel()
        await releaseLookup.open()

        await runHandle.value

        for fileID in [file1, file2, file3] {
            guard case let .stopped(reason) = service.rows[fileID] else {
                return XCTFail("Explicit Stop must leave unfinished rows stopped, got \(String(describing: service.rows[fileID]))")
            }
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertNil(service.candidate(for: file1), "A late response must not revive a stopped row")
        XCTAssertTrue(service.recordingAlternatives.isEmpty, "An obsolete lookup must not restore chooser entries")
    }

    // MARK: - On-demand fingerprinting

    func testComputesAndPersistsFingerprintWhenMissing() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(
            in: database,
            path: "/music/needs-fingerprint.mp3",
            fingerprintHashes: nil,
            fingerprintStatus: .pending
        )

        let expectedHashes: [UInt32] = [30, 31, 32]
        let expectedBase64 = fingerprintBase64(for: expectedHashes)

        let acoustIDClient = StubAcoustIDClient { base64 in
            XCTAssertEqual(base64, expectedBase64)
            return [AcoustIDResult(id: "a", score: 0.95, recordingIDs: ["mb-1"])]
        }
        let recording = makeRecording()
        let musicBrainzClient = StubMusicBrainzClient { _ in recording }

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: musicBrainzClient,
            keyStore: StubKeyProvider(),
            fingerprintFunction: { _ in expectedHashes },
            audioTagsReader: stubAudioTagsReader()
        )

        await service.run(fileIDs: [fileID])

        guard case .strong = service.rows[fileID] else {
            return XCTFail("expected .strong, got \(String(describing: service.rows[fileID]))")
        }

        let persisted = try await database.writer.read { db in try FileRecord.fetchOne(db, key: fileID) }
        XCTAssertEqual(persisted?.fingerprintStatus, .done)
        XCTAssertEqual(persisted?.chromaprintFingerprint, FingerprintEncoder.serialize(expectedHashes))
    }

    // MARK: - D-B: stale stored fingerprint is recomputed before lookup

    /// A `.done` file whose current on-disk size/mtime differ from the
    /// indexed snapshot the fingerprint was computed from (the file was
    /// edited/replaced since fingerprinting) must NOT reuse the stale stored
    /// bytes — it recomputes, so the lookup identifies the current audio.
    func testStaleStoredFingerprintIsRecomputedBeforeLookup() async throws {
        let database = try makeDatabase()
        // insertFile stores fingerprint [1,2,3] with indexed fileSize 1000/mtime 0.
        let fileID = try insertFile(in: database, path: "/music/edited.mp3")

        let recomputedHashes: [UInt32] = [40, 41, 42]
        let recomputedBase64 = fingerprintBase64(for: recomputedHashes)

        let acoustIDClient = StubAcoustIDClient { base64 in
            XCTAssertEqual(
                base64, recomputedBase64,
                "lookup must use the recomputed fingerprint, not the stale stored bytes"
            )
            return [AcoustIDResult(id: "a", score: 0.95, recordingIDs: ["mb-1"])]
        }
        let recording = makeRecording()
        let musicBrainzClient = StubMusicBrainzClient { _ in recording }

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: musicBrainzClient,
            keyStore: StubKeyProvider(),
            fingerprintFunction: { _ in recomputedHashes },
            audioTagsReader: stubAudioTagsReader(),
            // Current on-disk identity differs from the indexed 1000/0 → stale.
            fileFreshnessReader: { _ in FileFreshnessSnapshot(fileSize: 2000, mtime: 999) }
        )

        await service.run(fileIDs: [fileID])

        guard case .strong = service.rows[fileID] else {
            return XCTFail("expected .strong, got \(String(describing: service.rows[fileID]))")
        }

        let persisted = try await database.writer.read { db in try FileRecord.fetchOne(db, key: fileID) }
        XCTAssertEqual(
            persisted?.chromaprintFingerprint, FingerprintEncoder.serialize(recomputedHashes),
            "the recomputed fingerprint must be persisted, replacing the stale bytes"
        )
        // #3999114461: the recompute must ALSO persist the on-disk stat it was
        // computed from as the fingerprint's freshness basis — otherwise the
        // basis stays pinned to the stale index snapshot and every later scan
        // re-decodes forever.
        XCTAssertEqual(persisted?.fingerprintedSize, 2000, "recompute must record the current size as the fingerprint basis")
        XCTAssertEqual(persisted?.fingerprintedMtime, 999, "recompute must record the current mtime as the fingerprint basis")
    }

    /// The thrash regression (#3999114461): after a recompute persists the
    /// new freshness basis, a SECOND scan of the same (still-unchanged) file
    /// must reuse the fingerprint rather than re-decoding — the basis now
    /// matches the live stat, so freshness holds.
    func testRecomputedFingerprintIsNotReDecodedOnNextScanOfUnchangedFile() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/edited-once.mp3")

        let recomputedHashes: [UInt32] = [40, 41, 42]
        let acoustIDClient = StubAcoustIDClient { _ in
            [AcoustIDResult(id: "a", score: 0.95, recordingIDs: ["mb-1"])]
        }
        let recording = makeRecording()
        let musicBrainzClient = StubMusicBrainzClient { _ in recording }

        let fingerprintCallCount = FingerprintCallCounter()
        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: musicBrainzClient,
            keyStore: StubKeyProvider(),
            fingerprintFunction: { _ in
                fingerprintCallCount.increment()
                return recomputedHashes
            },
            audioTagsReader: stubAudioTagsReader(),
            // The file's on-disk identity is stable at (2000, 999) — differs
            // from the index snapshot (1000, 0), so the FIRST scan recomputes.
            fileFreshnessReader: { _ in FileFreshnessSnapshot(fileSize: 2000, mtime: 999) }
        )

        await service.run(fileIDs: [fileID])
        XCTAssertEqual(fingerprintCallCount.value, 1, "first scan recomputes the stale fingerprint")

        await service.run(fileIDs: [fileID])
        XCTAssertEqual(
            fingerprintCallCount.value, 1,
            "second scan of the unchanged file must NOT re-decode — the persisted basis now matches the live stat"
        )
    }

    /// A `.done` file whose current on-disk size/mtime match the indexed
    /// snapshot is unchanged — the stored fingerprint is reused as-is, with
    /// no recompute.
    func testFreshStoredFingerprintIsReusedWithoutRecompute() async throws {
        let database = try makeDatabase()
        let storedHashes: [UInt32] = [1, 2, 3]
        let fileID = try insertFile(in: database, path: "/music/unchanged.mp3")
        let storedBase64 = fingerprintBase64(for: storedHashes)

        let acoustIDClient = StubAcoustIDClient { base64 in
            XCTAssertEqual(base64, storedBase64, "fresh file must reuse the stored fingerprint")
            return [AcoustIDResult(id: "a", score: 0.95, recordingIDs: ["mb-1"])]
        }
        let recording = makeRecording()
        let musicBrainzClient = StubMusicBrainzClient { _ in recording }

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: acoustIDClient,
            musicBrainzClient: musicBrainzClient,
            keyStore: StubKeyProvider(),
            fingerprintFunction: { _ in
                XCTFail("must not recompute a fingerprint for an unchanged file")
                return []
            },
            audioTagsReader: stubAudioTagsReader(),
            // Matches the indexed snapshot (fileSize 1000, mtime 0) → fresh.
            fileFreshnessReader: { _ in FileFreshnessSnapshot(fileSize: 1000, mtime: 0) }
        )

        await service.run(fileIDs: [fileID])

        guard case .strong = service.rows[fileID] else {
            return XCTFail("expected .strong, got \(String(describing: service.rows[fileID]))")
        }
    }

    /// Finding #4001064040: the on-demand decode's FAILURE write must not
    /// clobber a `.done` fingerprint the background `FingerprintWorker`
    /// persisted concurrently. Symmetric to the worker-side
    /// `requirePendingStatus` guard (#4000806487) — there the worker's write
    /// yields to a newer on-demand result; here the on-demand FAILURE yields
    /// to the worker's completed result, so the row is not forced back to
    /// `.failed` (which would strip the valid fingerprint and force a re-decode).
    func testOnDemandFailureDoesNotClobberConcurrentWorkerDone() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(
            in: database, path: "/music/race.mp3",
            fingerprintHashes: nil, fingerprintStatus: .pending
        )
        let workerHashes: [UInt32] = [7, 8, 9]

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in
                XCTFail("decode failed — lookup must not run")
                return []
            },
            musicBrainzClient: StubMusicBrainzClient { _ in
                XCTFail("decode failed — MusicBrainz must not be hit")
                throw LookupError.transport("unreachable")
            },
            keyStore: StubKeyProvider(),
            fingerprintFunction: { _ in
                // Simulate the background worker persisting .done in the window
                // between this on-demand decode starting and its failure.
                try? database.writer.write { db in
                    try FingerprintPersistence.write(
                        fileID: fileID,
                        fingerprint: FingerprintEncoder.serialize(workerHashes),
                        status: .done, in: db
                    )
                }
                throw NSError(domain: "test.decode", code: 1)
            },
            audioTagsReader: stubAudioTagsReader()
        )

        await service.run(fileIDs: [fileID])

        // The on-demand attempt failed for THIS run…
        guard case .failed = service.rows[fileID] else {
            return XCTFail("expected .failed for the on-demand run, got \(String(describing: service.rows[fileID]))")
        }
        // …but the worker's completed fingerprint must survive in the DB, so a
        // retry / next scan reuses it instead of re-decoding a now-.failed row.
        let persisted = try await database.writer.read { db in try FileRecord.fetchOne(db, key: fileID) }
        XCTAssertEqual(
            persisted?.fingerprintStatus, .done,
            "the concurrent worker .done must not be overwritten with .failed"
        )
        XCTAssertEqual(
            persisted?.chromaprintFingerprint, FingerprintEncoder.serialize(workerHashes),
            "the worker's fingerprint bytes must be preserved"
        )
    }

    // MARK: - D-A: apply-time candidate revalidation

    private func makeMatchPayload(
        fileID: Int64,
        expectedFileSize: Int64,
        expectedMtime: Int64
    ) -> ApplyMusicBrainzMatchPayload {
        ApplyMusicBrainzMatchPayload(
            fileID: fileID,
            acoustID: "aid",
            recordingMBID: "rec",
            releaseMBID: "rel",
            artistMBID: "art",
            isrc: "isrc",
            fingerprintHash: Data([0x01]),
            expectedFileSize: expectedFileSize,
            expectedMtime: expectedMtime,
            artist: "A", title: "T", album: "Al", year: 1994
        )
    }

    private func makeService(
        database: LibraryDatabase,
        fileFreshnessReader: @escaping FileFreshnessReading
    ) -> AutoTaggerService {
        AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in [] },
            musicBrainzClient: StubMusicBrainzClient { _ in
                XCTFail("revalidation must not hit MusicBrainz")
                throw LookupError.transport("unreachable")
            },
            keyStore: StubKeyProvider(),
            audioTagsReader: stubAudioTagsReader(),
            fileFreshnessReader: fileFreshnessReader
        )
    }

    /// The candidate's `expected*` snapshot is the file's ACTUAL on-disk
    /// identity at lookup (via the freshness reader), NOT the DB-indexed
    /// `FileRecord.fileSize`/`mtime` — otherwise D-A can never fire, since
    /// nothing mutates the DB values in place.
    func testCandidateCapturesOnDiskFreshnessSnapshotAtLookup() async throws {
        let database = try makeDatabase()
        // DB row is fileSize 1000 / mtime 0; on disk it's something else.
        let fileID = try insertFile(
            in: database, path: "/music/x.mp3",
            fingerprintHashes: nil, fingerprintStatus: .pending
        )
        let recording = makeRecording()
        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in
                [AcoustIDResult(id: "a", score: 0.95, recordingIDs: ["mb-1"])]
            },
            musicBrainzClient: StubMusicBrainzClient { _ in recording },
            keyStore: StubKeyProvider(),
            fingerprintFunction: { _ in [9, 9, 9] },
            audioTagsReader: stubAudioTagsReader(),
            fileFreshnessReader: { _ in FileFreshnessSnapshot(fileSize: 7777, mtime: 8888) }
        )

        await service.run(fileIDs: [fileID])

        guard let candidate = service.candidate(for: fileID) else {
            return XCTFail("expected a resolved candidate")
        }
        XCTAssertEqual(candidate.expectedFileSize, 7777, "expected size must be the on-disk value, not the DB 1000")
        XCTAssertEqual(candidate.expectedMtime, 8888, "expected mtime must be the on-disk value, not the DB 0")
    }

    /// A file whose on-disk size/mtime changed between lookup and Apply is
    /// flagged stale, so the caller excludes it from the batch.
    func testStaleFileIDsFlagsFileChangedSinceLookup() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/edited.mp3")
        // Current on-disk (2000, 999) differs from the lookup snapshot (1000, 0).
        let service = makeService(database: database) { _ in
            FileFreshnessSnapshot(fileSize: 2000, mtime: 999)
        }
        let payload = makeMatchPayload(fileID: fileID, expectedFileSize: 1000, expectedMtime: 0)

        let stale = try await service.staleFileIDs(for: [payload])
        XCTAssertEqual(stale, [fileID])
    }

    /// A file whose on-disk size/mtime still match the lookup snapshot is
    /// NOT flagged — the apply proceeds for it.
    func testStaleFileIDsPassesUnchangedFile() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/unchanged.mp3")
        let service = makeService(database: database) { _ in
            FileFreshnessSnapshot(fileSize: 1000, mtime: 0)
        }
        let payload = makeMatchPayload(fileID: fileID, expectedFileSize: 1000, expectedMtime: 0)

        let stale = try await service.staleFileIDs(for: [payload])
        XCTAssertTrue(stale.isEmpty)
    }

    /// A file that vanished / can't be stat'd at apply time is flagged
    /// stale — applying a tag write to a missing file is meaningless.
    func testStaleFileIDsFlagsMissingFile() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/gone.mp3")
        let service = makeService(database: database) { _ in nil }
        let payload = makeMatchPayload(fileID: fileID, expectedFileSize: 1000, expectedMtime: 0)

        let stale = try await service.staleFileIDs(for: [payload])
        XCTAssertEqual(stale, [fileID])
    }

    /// A legacy payload lacking the on-disk snapshot (both expected fields
    /// nil — journaled before D-A) can't be revalidated and is treated as
    /// NOT stale, even when the file would otherwise appear changed. It must
    /// never crash by force-unwrapping the missing snapshot.
    func testStaleFileIDsSkipsLegacyPayloadWithoutSnapshot() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/legacy.mp3")
        // Reader would report a wildly different size/mtime, but the payload
        // has no captured snapshot to compare against.
        let service = makeService(database: database) { _ in
            FileFreshnessSnapshot(fileSize: 999_999, mtime: 123_456)
        }
        let payload = ApplyMusicBrainzMatchPayload(
            fileID: fileID,
            acoustID: nil,
            recordingMBID: "rec",
            releaseMBID: nil,
            artistMBID: nil,
            isrc: nil,
            fingerprintHash: Data([0x01]),
            expectedFileSize: nil,
            expectedMtime: nil,
            artist: nil, title: nil, album: nil, year: nil
        )

        let stale = try await service.staleFileIDs(for: [payload])
        XCTAssertTrue(stale.isEmpty, "a legacy event with no captured snapshot must not be flagged stale")
    }

    /// A database read failure during apply-time revalidation must PROPAGATE,
    /// not be swallowed into an empty path map that marks every file stale and
    /// misreports a DB problem as "the files changed on disk" (finding
    /// #3999114466).
    func testStaleFileIDsThrowsWhenDatabaseReadFails() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/x.mp3")
        let service = makeService(database: database) { _ in
            FileFreshnessSnapshot(fileSize: 1000, mtime: 0)
        }
        // Drop the table the revalidation reads, so the fetch throws.
        try await database.writer.write { db in try db.execute(sql: "DROP TABLE files") }
        let payload = makeMatchPayload(fileID: fileID, expectedFileSize: 1000, expectedMtime: 0)

        do {
            _ = try await service.staleFileIDs(for: [payload])
            XCTFail("expected the database read failure to propagate")
        } catch {
            // Any thrown error is correct — the point is it is not swallowed
            // into an empty map and reported as a stale file.
        }
    }

    // MARK: - #4000261459: release selection uses the on-disk album

    /// Release selection must default from the file's ON-DISK album tag, not
    /// the Serato-imported `FileRecord.album`. When they differ and MusicBrainz
    /// offers pressings for both, the chosen release must match the embedded
    /// value the review shows as current — not the stale Serato snapshot.
    func testReleaseSelectionUsesOnDiskAlbumNotDatabaseSnapshot() async throws {
        let database = try makeDatabase()
        // DB snapshot says "Serato Album"; the file on disk says "File Album".
        let fileID = try insertFile(in: database, path: "/music/x.mp3", album: "Serato Album")

        let seratoRelease = MBRelease(id: "rel-serato", title: "Serato Album", date: "1990", country: "US", status: "Official")
        let fileRelease = MBRelease(id: "rel-file", title: "File Album", date: "1994", country: "US", status: "Official")
        let recording = MBRecording(
            title: "Song",
            artistCredit: [MBArtistCredit(name: "Artist", artist: MBArtist(id: "a", name: "Artist"))],
            releases: [seratoRelease, fileRelease],
            releaseGroup: nil,
            isrcs: []
        )

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in
                [AcoustIDResult(id: "a", score: 0.95, recordingIDs: ["mb-1"])]
            },
            musicBrainzClient: StubMusicBrainzClient { _ in recording },
            keyStore: StubKeyProvider(),
            audioTagsReader: { _ in
                AudioTags(
                    bitrateKbps: nil, title: nil, artist: nil, album: "File Album", albumArtist: nil,
                    genre: nil, year: nil, trackNumber: nil, totalTracks: nil, bpm: nil,
                    comment: nil, durationSeconds: 200
                )
            }
        )

        await service.run(fileIDs: [fileID])

        guard let candidate = service.candidate(for: fileID) else {
            return XCTFail("expected a resolved candidate")
        }
        XCTAssertEqual(candidate.chosenRelease.id, "rel-file", "release must follow the on-disk album, not the DB snapshot")
        XCTAssertEqual(candidate.proposedAlbum, "File Album")
    }

    // MARK: - #4000261453: reject a fingerprint from a file that changed mid-decode

    /// If the file is edited/replaced WHILE its fingerprint is being computed,
    /// the resulting fingerprint describes old-or-mixed audio while later steps
    /// capture the NEW file's stat as the candidate's expected identity — so
    /// apply-time validation would pass and write the old recording's match
    /// onto the new audio. The row must fail instead.
    func testFingerprintRejectedWhenFileChangesDuringDecode() async throws {
        let database = try makeDatabase()
        // .pending so currentFingerprint takes the compute path.
        let fileID = try insertFile(
            in: database, path: "/music/racing.mp3",
            fingerprintHashes: nil, fingerprintStatus: .pending
        )

        // The freshness reader returns a DIFFERENT stat pre- vs post-decode,
        // simulating the file changing while `fingerprintFunction` read it.
        let freshness = SequencedFreshnessReader(snapshots: [
            FileFreshnessSnapshot(fileSize: 1000, mtime: 0), // pre-decode basis
            FileFreshnessSnapshot(fileSize: 2000, mtime: 999), // post-decode: changed
        ])
        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in
                XCTFail("a mid-decode change must fail the row before any lookup")
                return []
            },
            musicBrainzClient: StubMusicBrainzClient { _ in
                XCTFail("must not reach MusicBrainz")
                throw LookupError.transport("unreachable")
            },
            keyStore: StubKeyProvider(),
            fingerprintFunction: { _ in [9, 9, 9] },
            audioTagsReader: stubAudioTagsReader(),
            fileFreshnessReader: { path in freshness.next(path) }
        )

        await service.run(fileIDs: [fileID])

        guard case let .failed(reason) = service.rows[fileID] else {
            return XCTFail("expected .failed, got \(String(describing: service.rows[fileID]))")
        }
        XCTAssertTrue(reason.contains("changed on disk"), "reason was: \(reason)")
    }

    // MARK: - #4000668529: multi-recording AcoustID result is not auto-strong

    /// When the top AcoustID result carries more than one recording id, the
    /// choice of recording is ambiguous — such a match must never auto-classify
    /// as strong (which "Confirm All Strong" would persist unseen); it is
    /// downgraded to weak for review.
    func testCompetingStrongResultsRequireReview() async throws {
        try await assertCompetingResults(topScore: 0.99, otherScore: 0.99, otherRecording: "mb-other", expectWeak: true)
        try await assertCompetingResults(topScore: 0.99, otherScore: 0.90, otherRecording: "mb-other", expectWeak: true)
    }

    func testCloseCompetitorBelowStrongThresholdRequiresReview() async throws {
        try await assertCompetingResults(topScore: 0.91, otherScore: 0.89, otherRecording: "mb-other", expectWeak: true)
    }

    func testDuplicateRecordingAndDistantWeakResultDoNotDowngrade() async throws {
        try await assertCompetingResults(topScore: 0.99, otherScore: 0.99, otherRecording: "mb-top", expectWeak: false)
        try await assertCompetingResults(topScore: 0.99, otherScore: 0.50, otherRecording: "mb-other", expectWeak: false)
    }

    private func assertCompetingResults(topScore: Double, otherScore: Double, otherRecording: String, expectWeak: Bool) async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/competing.mp3")
        let recording = makeRecording()
        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in [
                AcoustIDResult(id: "top", score: topScore, recordingIDs: ["mb-top"]),
                AcoustIDResult(id: "other", score: otherScore, recordingIDs: [otherRecording]),
            ] },
            musicBrainzClient: StubMusicBrainzClient { recordingID in
                XCTAssertEqual(recordingID, "mb-top")
                return recording
            },
            keyStore: StubKeyProvider(),
            audioTagsReader: stubAudioTagsReader()
        )
        await service.run(fileIDs: [fileID])
        switch service.rows[fileID] {
        case .weak: XCTAssertTrue(expectWeak)
        case .strong: XCTAssertFalse(expectWeak)
        default: XCTFail("expected a classified candidate")
        }
        XCTAssertEqual(service.candidate(for: fileID)?.recordingMBID, "mb-top")
    }

    func testMultiRecordingResultDoesNotAutoClassifyStrong() async throws {
        let database = try makeDatabase()
        let hashes: [UInt32] = [1, 2, 3]
        let fileID = try insertFile(in: database, path: "/music/ambiguous.mp3", fingerprintHashes: hashes)
        let recording = makeRecording()

        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in
                // High score, but TWO candidate recordings.
                [AcoustIDResult(id: "a", score: 0.99, recordingIDs: ["mb-1", "mb-2"])]
            },
            musicBrainzClient: StubMusicBrainzClient { _ in recording },
            keyStore: StubKeyProvider(),
            audioTagsReader: stubAudioTagsReader()
        )

        await service.run(fileIDs: [fileID])

        guard case .weak = service.rows[fileID] else {
            return XCTFail("a multi-recording result must be weak, got \(String(describing: service.rows[fileID]))")
        }
    }

    // MARK: - #4000405424: cached fingerprint rejected if file changes before lookup

    /// A cached (`.done`, fresh) fingerprint whose file is replaced AFTER the
    /// freshness check but BEFORE the lookup snapshot must fail the row — the
    /// candidate would otherwise pair the old fingerprint's recording with the
    /// new file's captured size/mtime, and apply-time validation would pass.
    func testCachedFingerprintRejectedWhenFileChangesBeforeLookup() async throws {
        let database = try makeDatabase()
        // .done + fingerprint bytes; basis falls back to fileSize 1000 / mtime 0.
        let fileID = try insertFile(in: database, path: "/music/swapped.mp3")

        // Freshness reader: the freshness check sees the unchanged file (basis),
        // then the lookup snapshot sees the replacement.
        let freshness = SequencedFreshnessReader(snapshots: [
            FileFreshnessSnapshot(fileSize: 1000, mtime: 0), // storedFingerprintIsFresh → fresh
            FileFreshnessSnapshot(fileSize: 5000, mtime: 777), // lookup snapshot → changed
        ])
        let service = AutoTaggerService(
            database: database,
            acoustIDClient: StubAcoustIDClient { _ in
                XCTFail("must fail the row before any lookup")
                return []
            },
            musicBrainzClient: StubMusicBrainzClient { _ in
                XCTFail("must not reach MusicBrainz")
                throw LookupError.transport("unreachable")
            },
            keyStore: StubKeyProvider(),
            fingerprintFunction: { _ in
                XCTFail("cached fingerprint must not be recomputed")
                return []
            },
            audioTagsReader: stubAudioTagsReader(),
            fileFreshnessReader: { path in freshness.next(path) }
        )

        await service.run(fileIDs: [fileID])

        guard case let .failed(reason) = service.rows[fileID] else {
            return XCTFail("expected .failed, got \(String(describing: service.rows[fileID]))")
        }
        XCTAssertTrue(reason.contains("between fingerprinting and lookup"), "reason was: \(reason)")
    }
}

/// Returns a preset sequence of freshness snapshots on successive calls (the
/// last repeats), so a test can simulate a file changing between the pre-decode
/// and post-decode stats.
private final class SequencedFreshnessReader: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [FileFreshnessSnapshot?]
    init(snapshots: [FileFreshnessSnapshot?]) {
        self.snapshots = snapshots
    }

    func next(_: String) -> FileFreshnessSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard !snapshots.isEmpty else { return nil }
        return snapshots.count == 1 ? snapshots[0] : snapshots.removeFirst()
    }
}

/// Thread-safe call counter for injected `@Sendable` closures (fingerprint /
/// lookup stubs), so tests can assert how many times a stub was invoked.
private final class FingerprintCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }; return count
    }
}

// MARK: - Test doubles

private struct StubAcoustIDClient: AcoustIDLookupClient {
    let handler: @Sendable (String) throws -> [AcoustIDResult]

    func lookup(fingerprintBase64: String, durationSeconds _: Int, apiKey _: String) async throws -> [AcoustIDResult] {
        try handler(fingerprintBase64)
    }
}

private struct StubMusicBrainzClient: MusicBrainzLookupClient {
    let handler: @Sendable (String) throws -> MBRecording

    func recording(mbid: String) async throws -> MBRecording {
        try handler(mbid)
    }
}

private struct StubKeyProvider: AcoustIDKeyProviding {
    let key: String?
    let errorToThrow: Error?

    init(key: String? = "TESTKEY", errorToThrow: Error? = nil) {
        self.key = key
        self.errorToThrow = errorToThrow
    }

    func load() throws -> String? {
        if let errorToThrow {
            throw errorToThrow
        }
        return key
    }
}

/// A key provider whose `key` can be flipped between two `run` calls in
/// the same test — `StubKeyProvider` is fixed at construction, which
/// can't express "resolved with a key, then re-scanned with none" (E-J).
private final class MutableKeyProvider: AcoustIDKeyProviding, @unchecked Sendable {
    var key: String?

    init(key: String?) {
        self.key = key
    }

    func load() throws -> String? {
        key
    }
}

/// A distinctly-worded stand-in for a real `AcoustIDKeyStoreError`, so
/// `testKeychainErrorSetsFatalBanner` can assert the fatal message came from
/// this error rather than coincidentally matching the no-key-configured text.
private struct FakeKeychainError: Error, CustomStringConvertible {
    let description = "keychain unavailable"
}

/// An `AcoustIDLookupClient` whose single lookup call suspends on `onStart`
/// before returning `result` — lets `testCancelStopsThePass` deterministically
/// land a `cancel()` call while a lookup for the first file is genuinely in
/// flight, with no real sleeping or network involved.
private struct SuspendingAcoustIDClient: AcoustIDLookupClient {
    let onStart: @Sendable () async -> Void
    let result: [AcoustIDResult]

    func lookup(fingerprintBase64 _: String, durationSeconds _: Int, apiKey _: String) async throws -> [AcoustIDResult] {
        await onStart()
        return result
    }
}

/// A minimal async rendezvous point: `wait()` suspends until `open()` has
/// been called (from any task), and returns immediately if `open()` already
/// happened. Used to sequence test code and the service's in-flight lookup
/// without any real delay.
private actor AsyncGate {
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
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
