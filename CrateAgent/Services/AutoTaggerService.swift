import CryptoKit
import Foundation
import GRDB

/// Orchestrates the MusicBrainz auto-tag lookup pipeline for a selection of
/// files, producing a per-file `MatchCandidate` for the review UI (Task 14).
///
/// Per file: ensure a Chromaprint fingerprint exists (computing one
/// on-demand if the background `FingerprintWorker` hasn't gotten to it yet)
/// → encode it for AcoustID → read the file's full-track duration → look up
/// AcoustID → resolve the winning recording's ID → fetch the MusicBrainz
/// recording → assemble a `MatchCandidate` (release via `ReleaseSelector`,
/// year via Ruling F) → classify by AcoustID confidence.
///
/// A single file's failure (a bad fingerprint, a transport error, a rate
/// limit) never aborts the rest of the pass — it becomes that row's
/// `.failed(reason)` and the loop continues (no-silent-failures: the reason
/// is visible in `rows`, not swallowed). An `.unauthorized` or `.server`
/// `LookupError` is different in kind — it means every remaining lookup in
/// this pass would fail too — so it halts the whole pass and surfaces
/// `fatalError` instead of failing every remaining row individually.
@MainActor
final class AutoTaggerService: ObservableObject {
    enum RowState: Equatable {
        case pending
        case strong(MatchCandidate)
        case weak(MatchCandidate)
        case noMatch
        case failed(String)
        /// Terminal: the whole pass halted (`fatalError` was set) before
        /// this row got a chance to resolve. Distinct from `.pending`
        /// (still queued, the pass is still running) so the view never
        /// renders an abandoned row as "Looking up…" forever.
        case stopped(String)
    }

    /// Below this, a resolved candidate is `.weak`; at or above, `.strong`.
    /// `.noMatch` is reserved for "AcoustID found nothing usable" — a low
    /// score still resolves to `.weak`, never `.noMatch`, since a
    /// candidate did in fact resolve and the user can still inspect it.
    private static let strongScoreThreshold = 0.9

    private static let noAPIKeyConfiguredMessage =
        "No AcoustID API key is configured. Add one in Settings to use the auto-tagger."

    @Published private(set) var rows: [Int64: RowState] = [:]
    /// Set only when the whole pass has been halted (bad API key, or the
    /// lookup server itself is down) — as opposed to a single row's
    /// `.failed`, which leaves the rest of the pass running.
    @Published private(set) var fatalError: String?

    private let database: LibraryDatabase
    private let acoustIDClient: AcoustIDLookupClient
    private let musicBrainzClient: MusicBrainzLookupClient
    private let keyStore: AcoustIDKeyProviding
    private let fingerprintFunction: FingerprintWorker.FingerprintFunction
    private let audioTagsReader: AudioTagsReading

    private var runTask: Task<Void, Never>?

    init(
        database: LibraryDatabase,
        acoustIDClient: AcoustIDLookupClient,
        musicBrainzClient: MusicBrainzLookupClient,
        keyStore: AcoustIDKeyProviding = AcoustIDKeyStore(),
        fingerprintFunction: @escaping FingerprintWorker.FingerprintFunction = { try fingerprintAudioFile(filePath: $0) },
        audioTagsReader: @escaping AudioTagsReading = { try readAudioTags(filePath: $0) }
    ) {
        self.database = database
        self.acoustIDClient = acoustIDClient
        self.musicBrainzClient = musicBrainzClient
        self.keyStore = keyStore
        self.fingerprintFunction = fingerprintFunction
        self.audioTagsReader = audioTagsReader
    }

    func candidate(for fileID: Int64) -> MatchCandidate? {
        switch rows[fileID] {
        case let .strong(candidate), let .weak(candidate):
            return candidate
        case .pending, .noMatch, .failed, .stopped, .none:
            return nil
        }
    }

    /// Cancels the in-flight pass, if any. Already-resolved rows in `rows`
    /// are left as they are; only unresolved files stop getting processed.
    func cancel() {
        runTask?.cancel()
    }

    /// Runs the lookup pipeline for `fileIDs`, publishing each row's result
    /// to `rows` as it resolves. Replaces any previously in-flight run.
    func run(fileIDs: [Int64]) async {
        runTask?.cancel()
        fatalError = nil

        let apiKey: String
        do {
            guard let loadedKey = try keyStore.load(), !loadedKey.isEmpty else {
                fatalError = Self.noAPIKeyConfiguredMessage
                stopUnresolvedRows(among: fileIDs, message: Self.noAPIKeyConfiguredMessage)
                return
            }
            apiKey = loadedKey
        } catch {
            let message = "Could not read the AcoustID API key from the Keychain: \(error)"
            fatalError = message
            stopUnresolvedRows(among: fileIDs, message: message)
            return
        }

        for fileID in fileIDs {
            rows[fileID] = .pending
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.processAll(fileIDs: fileIDs, apiKey: apiKey)
        }
        runTask = task
        await task.value
    }

    private func processAll(fileIDs: [Int64], apiKey: String) async {
        for fileID in fileIDs {
            if Task.isCancelled {
                return
            }

            do {
                rows[fileID] = try await resolveRow(fileID: fileID, apiKey: apiKey)
            } catch let lookupError as LookupError {
                // Only reached for .unauthorized/.server — resolveRow
                // converts every other LookupError into a per-row .failed
                // before it ever gets here.
                let message = "Auto-tag pass stopped: \(Self.describe(lookupError))"
                fatalError = message
                stopUnresolvedRows(among: fileIDs, message: message)
                return
            } catch {
                rows[fileID] = .failed(String(describing: error))
            }
        }
    }

    /// Transitions every fileID among `fileIDs` that is still unresolved —
    /// absent from `rows` entirely (the no-key/keychain early-return,
    /// before `run`'s `.pending` initialization loop runs) or still
    /// `.pending` (a mid-pass fatal halt, for files not yet reached) — to
    /// `.stopped(message)`. Already-resolved rows (`.strong`, `.weak`,
    /// `.noMatch`, `.failed`) are left exactly as they are.
    private func stopUnresolvedRows(among fileIDs: [Int64], message: String) {
        for fileID in fileIDs {
            switch rows[fileID] {
            case nil, .pending:
                rows[fileID] = .stopped(message)
            case .strong, .weak, .noMatch, .failed, .stopped:
                break
            }
        }
    }

    /// Resolves one file's row, or rethrows a `LookupError` that should
    /// halt the whole pass (`.unauthorized`/`.server`). Every other failure
    /// — a bad fingerprint, a missing duration tag, `.rateLimited`,
    /// `.transport` — is caught here and returned as `.failed`, isolating
    /// it to this row.
    private func resolveRow(fileID: Int64, apiKey: String) async throws -> RowState {
        do {
            return try await lookUpCandidate(fileID: fileID, apiKey: apiKey)
        } catch let lookupError as LookupError {
            switch lookupError {
            case .unauthorized, .server:
                throw lookupError
            case .rateLimited, .transport:
                return .failed(Self.describe(lookupError))
            }
        }
    }

    private func lookUpCandidate(fileID: Int64, apiKey: String) async throws -> RowState {
        guard let file = try await fetchFile(fileID: fileID) else {
            throw AutoTaggerRowFailure("file \(fileID) not found in the library")
        }

        let fingerprintBytes = try await currentFingerprint(for: file)
        guard let fingerprintBase64 = FingerprintEncoder.base64(fromStoredBytes: fingerprintBytes) else {
            throw AutoTaggerRowFailure("empty or corrupt fingerprint for file \(fileID)")
        }

        let tags = try await runOffMainActor { [audioTagsReader] in try audioTagsReader(file.path) }
        guard let durationSeconds = tags.durationSeconds else {
            throw AutoTaggerRowFailure("missing audio duration for file \(fileID)")
        }

        let acoustIDResults = try await acoustIDClient.lookup(
            fingerprintBase64: fingerprintBase64,
            durationSeconds: Int(durationSeconds),
            apiKey: apiKey
        )

        guard let topResult = acoustIDResults.first(where: { !$0.recordingIDs.isEmpty }),
              let recordingMBID = topResult.recordingIDs.first
        else {
            return .noMatch
        }

        let recording = try await musicBrainzClient.recording(mbid: recordingMBID)

        guard let chosenRelease = ReleaseSelector.defaultRelease(from: recording.releases, existingAlbum: file.album) else {
            throw AutoTaggerRowFailure("MusicBrainz recording \(recordingMBID) has no releases")
        }

        let artistCredit = recording.artistCredit.first
        let candidate = MatchCandidate(
            fileID: fileID,
            score: topResult.score,
            acoustID: topResult.id,
            recordingMBID: recordingMBID,
            artistMBID: artistCredit?.artist.id,
            fingerprintHash: Data(SHA256.hash(data: fingerprintBytes)),
            chosenRelease: chosenRelease,
            availableReleases: recording.releases,
            isrc: recording.isrcs.first,
            proposedArtist: recording.creditedArtistName,
            proposedTitle: recording.title,
            proposedAlbum: chosenRelease.title,
            proposedYear: recording.releaseGroup?.firstReleaseDate.flatMap(Self.year(fromMusicBrainzDate:)),
            currentFileYear: tags.year.map(Int.init)
        )

        return Self.classify(candidate)
    }

    private static func classify(_ candidate: MatchCandidate) -> RowState {
        candidate.score >= strongScoreThreshold ? .strong(candidate) : .weak(candidate)
    }

    /// A MusicBrainz partial date's leading year (`"1988-05-09"` → `1988`).
    private static func year(fromMusicBrainzDate dateString: String) -> Int? {
        Int(dateString.prefix(4))
    }

    private static func describe(_ error: LookupError) -> String {
        switch error {
        case .unauthorized:
            return "the AcoustID API key was rejected (401 Unauthorized)"
        case .rateLimited:
            return "the lookup was rate-limited and retries were exhausted"
        case .server:
            return "the lookup server returned repeated errors"
        case let .transport(message):
            return message
        }
    }

    // MARK: - Fingerprint on demand

    /// Returns the file's stored fingerprint bytes, computing and
    /// persisting one first if the background `FingerprintWorker` hasn't
    /// processed this file yet. The Chromaprint decode is CPU-bound, so it
    /// runs off the main actor to keep the UI responsive.
    private func currentFingerprint(for file: FileRecord) async throws -> Data {
        if file.fingerprintStatus == .done, let existing = file.chromaprintFingerprint {
            return existing
        }
        guard let fileID = file.id else {
            throw AutoTaggerRowFailure("file has no row id")
        }

        let path = file.path
        do {
            let hashes = try await runOffMainActor { [fingerprintFunction] in try fingerprintFunction(path) }
            let serialized = FingerprintEncoder.serialize(hashes)
            try await persistFingerprint(fileID: fileID, bytes: serialized, status: .done)
            return serialized
        } catch {
            try? await persistFingerprint(fileID: fileID, bytes: nil, status: .failed)
            throw AutoTaggerRowFailure("failed to compute fingerprint for file \(fileID): \(error)")
        }
    }

    /// Runs a blocking closure off the main actor so CPU-bound FFI calls
    /// (Chromaprint decode, tag parsing) never stall the UI.
    private func runOffMainActor<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await Task.detached(priority: .userInitiated) {
            try work()
        }.value
    }

    // MARK: - Database

    private func fetchFile(fileID: Int64) async throws -> FileRecord? {
        try await database.writer.read { db in
            try FileRecord.fetchOne(db, key: fileID)
        }
    }

    private func persistFingerprint(fileID: Int64, bytes: Data?, status: FingerprintStatus) async throws {
        try await database.writer.write { db in
            try FingerprintPersistence.write(fileID: fileID, fingerprint: bytes, status: status, in: db)
        }
    }
}

/// A resolution failure local to one file (not found, no fingerprint, no
/// releases, etc.) — distinct from `LookupError`, which is reserved for the
/// remote lookup clients. Its `description` is what callers show for that
/// row's `.failed` reason.
private struct AutoTaggerRowFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

/// Reads a file's audio tags (used here for `durationSeconds`). Production
/// default is the `readAudioTags` FFI call; tests inject a stub so no real
/// audio file is required.
typealias AudioTagsReading = @Sendable (String) throws -> AudioTags

/// Seam over `AcoustIDClient.lookup` so tests can stub AcoustID without a
/// real network call.
protocol AcoustIDLookupClient: Sendable {
    func lookup(fingerprintBase64: String, durationSeconds: Int, apiKey: String) async throws -> [AcoustIDResult]
}

extension AcoustIDClient: AcoustIDLookupClient {}

/// Seam over `MusicBrainzClient.recording` so tests can stub MusicBrainz
/// without a real network call.
protocol MusicBrainzLookupClient: Sendable {
    func recording(mbid: String) async throws -> MBRecording
}

extension MusicBrainzClient: MusicBrainzLookupClient {}

/// Seam over `AcoustIDKeyStore.load` so tests can control "no key
/// configured" / "key present" / "keychain error" deterministically,
/// without touching the real system Keychain.
protocol AcoustIDKeyProviding: Sendable {
    func load() throws -> String?
}

extension AcoustIDKeyStore: AcoustIDKeyProviding {}
