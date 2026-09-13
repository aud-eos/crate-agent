@testable import CrateAgent
import GRDB
import XCTest

@MainActor
final class AutoTaggerServiceTests: XCTestCase {
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

        guard case .strong = service.rows[file1] else {
            return XCTFail("expected the in-flight file to still resolve, got \(String(describing: service.rows[file1]))")
        }
        XCTAssertEqual(service.rows[file2], .pending, "cancellation should stop the pass before file2 is attempted")
        XCTAssertEqual(service.rows[file3], .pending, "cancellation should stop the pass before file3 is attempted")
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

        let stale = await service.staleFileIDs(for: [payload])
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

        let stale = await service.staleFileIDs(for: [payload])
        XCTAssertTrue(stale.isEmpty)
    }

    /// A file that vanished / can't be stat'd at apply time is flagged
    /// stale — applying a tag write to a missing file is meaningless.
    func testStaleFileIDsFlagsMissingFile() async throws {
        let database = try makeDatabase()
        let fileID = try insertFile(in: database, path: "/music/gone.mp3")
        let service = makeService(database: database) { _ in nil }
        let payload = makeMatchPayload(fileID: fileID, expectedFileSize: 1000, expectedMtime: 0)

        let stale = await service.staleFileIDs(for: [payload])
        XCTAssertEqual(stale, [fileID])
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
