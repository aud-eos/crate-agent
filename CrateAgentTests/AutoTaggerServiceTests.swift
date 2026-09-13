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
        // The pass stops at the first file — the second is never attempted.
        XCTAssertEqual(service.rows[fileB], .pending)
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
        XCTAssertNil(service.rows[fileID], "no row should be marked pending when the pass never starts")
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
