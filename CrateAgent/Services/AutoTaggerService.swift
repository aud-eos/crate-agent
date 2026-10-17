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
/// year via Ruling F) → classify by AcoustID confidence. When AcoustID
/// answers successfully with no recordings and the file has both embedded
/// artist and title tags, MusicBrainz is searched by that text instead;
/// those candidates are always `.weak` and never bulk-approvable.
///
/// A single file's failure (a bad fingerprint, a transport error, a rate
/// limit) never aborts the rest of the pass — it becomes that row's
/// `.failed(reason)` and the loop continues (no-silent-failures: the reason
/// is visible in `rows`, not swallowed). An `.unauthorized`, `.server`, or
/// `.offline` `LookupError` is different in kind — it means every remaining
/// lookup in this pass would fail too — so it halts the whole pass and
/// surfaces `haltReason` instead of failing every remaining row individually.
@MainActor
final class AutoTaggerService: ObservableObject {
    enum RowState: Equatable {
        case pending
        case strong(MatchCandidate)
        case weak(MatchCandidate)
        case noMatch
        case failed(String)
        /// Terminal: the whole pass halted (`haltReason` was set) before
        /// this row got a chance to resolve. Distinct from `.pending`
        /// (still queued, the pass is still running) so the view never
        /// renders an abandoned row as "Looking up…" forever.
        case stopped(String)
    }

    /// Below this, a resolved candidate is `.weak`; at or above, `.strong`.
    /// `.noMatch` is reserved for "AcoustID found nothing usable" — a low
    /// score still resolves to `.weak`, never `.noMatch`, since a
    /// candidate did in fact resolve and the user can still inspect it.
    private static let strongScoreThreshold = RecordingMatchAssessment.strongScoreThreshold

    private static let noAPIKeyConfiguredMessage =
        "No AcoustID API key is configured. Add one in Settings to use the auto-tagger."
    private static let musicBrainzUnauthorizedMessage = "MusicBrainz rejected the metadata request (HTTP 401)"

    @Published private(set) var rows: [Int64: RowState] = [:]
    @Published private(set) var recordingAlternatives: [Int64: RecordingAlternatives] = [:]
    @Published private(set) var recordingDetails: [Int64: [String: MBRecordingDetails]] = [:]

    private struct LookupBaseline {
        let fileID: Int64
        let membershipToken: FileMembershipToken
        let fingerprintHash: Data
        let freshness: FileFreshnessSnapshot
        let tags: AudioTags
    }

    private var lookupBaselines: [Int64: LookupBaseline] = [:]
    /// Set only when the whole pass has been halted (bad API key, or the
    /// lookup server itself is down) — as opposed to a single row's
    /// `.failed`, which leaves the rest of the pass running.
    @Published private(set) var haltReason: String?

    private let readiness: LibrarySyncReadiness?
    private var syncAuthorization: LibrarySyncReadiness.Authorization?
    private let database: LibraryDatabase
    private let acoustIDClient: AcoustIDLookupClient
    private let musicBrainzClient: MusicBrainzLookupClient
    private let keyStore: AcoustIDKeyProviding
    private let fingerprintFunction: FingerprintWorker.FingerprintFunction
    private let audioTagsReader: AudioTagsReading
    private let fileFreshnessReader: FileFreshnessReading

    private var runTask: Task<Void, Never>?
    /// Bumped on every `run`. A pass captures the value at start; before it
    /// mutates shared state (`rows`/`haltReason`) after any `await`, it
    /// confirms it's still the current generation. Cooperative cancellation
    /// is checked only between rows, so an in-flight fingerprint/lookup can
    /// finish and publish after a New Scan has already reset or resolved the
    /// same file — this generation token makes a superseded pass inert.
    private var runGeneration = 0

    init(
        database: LibraryDatabase,
        acoustIDClient: AcoustIDLookupClient,
        musicBrainzClient: MusicBrainzLookupClient,
        keyStore: AcoustIDKeyProviding = AcoustIDKeyStore(),
        fingerprintFunction: @escaping FingerprintWorker.FingerprintFunction = { try fingerprintAudioFile(filePath: $0) },
        audioTagsReader: @escaping AudioTagsReading = { try readAudioTags(filePath: $0) },
        fileFreshnessReader: @escaping FileFreshnessReading = { path in
            FileMetadataCollector.collect(at: path).map {
                FileFreshnessSnapshot(fileSize: $0.fileSize, mtime: $0.mtime)
            }
        },
        readiness: LibrarySyncReadiness? = nil
    ) {
        self.readiness = readiness
        self.database = database
        self.acoustIDClient = acoustIDClient
        self.musicBrainzClient = musicBrainzClient
        self.keyStore = keyStore
        self.fingerprintFunction = fingerprintFunction
        self.audioTagsReader = audioTagsReader
        self.fileFreshnessReader = fileFreshnessReader
    }

    func candidate(for fileID: Int64) -> MatchCandidate? {
        switch rows[fileID] {
        case let .strong(candidate), let .weak(candidate):
            candidate
        case .pending, .noMatch, .failed, .stopped, .none:
            nil
        }
    }

    /// Offsets address the original ranked IDs, so learning that two entries
    /// are aliases cannot skip the next page. Failures stay attached to their ID.
    func loadAlternativeDetails(fileID: Int64, offset: Int, limit: Int = 10) async throws -> [RecordingAlternativeDetailResult] {
        let authorization = try readiness?.capture()
        guard offset >= 0, limit > 0, limit <= 10 else {
            throw AutoTaggerRowFailure("Recording detail pages require a nonnegative offset and a limit from 1 to 10")
        }
        guard let alternatives = recordingAlternatives[fileID] else {
            throw AutoTaggerRowFailure("No recording alternatives for file \(fileID) — scan it first")
        }
        let generation = runGeneration
        var results: [RecordingAlternativeDetailResult] = []
        for alternative in alternatives.entries.dropFirst(offset).prefix(limit) {
            try ensureCurrent(generation: generation, authorization: authorization)
            do {
                let details: MBRecordingDetails = if let loaded = recordingDetails[fileID]?[alternative.recordingID] {
                    loaded
                } else {
                    try await musicBrainzClient.recordingDetails(mbid: alternative.recordingID)
                }
                try ensureCurrent(generation: generation, authorization: authorization)
                recordingDetails[fileID, default: [:]][alternative.recordingID] = details
                results.append(RecordingAlternativeDetailResult(alternative: alternative, state: .loaded(details)))
            } catch {
                try ensureCurrent(generation: generation, authorization: authorization)
                if error is CancellationError {
                    throw error
                }
                results.append(RecordingAlternativeDetailResult(alternative: alternative, state: .failed(Self.metadataFailureDescription(error))))
            }
        }
        try ensureCurrent(generation: generation, authorization: authorization)
        return results
    }

    /// Returns a complete replacement; editable review state belongs to the
    /// session, which checks selection identity before committing it.
    func resolveAlternative(fileID: Int64, recordingID: String) async throws -> MatchCandidate {
        let authorization = try readiness?.capture()
        guard let baseline = lookupBaselines[fileID],
              let alternative = recordingAlternatives[fileID]?.alternative(
                  for: recordingID, details: recordingDetails[fileID] ?? [:]
              )
        else {
            throw AutoTaggerRowFailure("Recording \(recordingID) was not returned by this file's scan")
        }
        let generation = runGeneration
        try ensureCurrent(generation: generation, authorization: authorization)
        let recording = try await loadRecording(mbid: alternative.recordingID)
        try ensureCurrent(generation: generation, authorization: authorization)
        try await requireCurrent(baseline.membershipToken, authorization: authorization)
        try ensureCurrent(generation: generation, authorization: authorization)
        recordingDetails[fileID, default: [:]][alternative.recordingID] = MBRecordingDetails(recording: recording, requestedID: alternative.recordingID)
        return try Self.assembleCandidate(alternative: alternative, recording: recording, baseline: baseline)
    }

    /// Nil for metadata-search candidates: an assessment describes audio
    /// evidence, and its absence keeps them out of bulk approval.
    func matchAssessment(fileID: Int64, recordingID: String) -> RecordingMatchAssessment? {
        guard let alternatives = recordingAlternatives[fileID],
              let alternative = alternatives.alternative(for: recordingID, details: recordingDetails[fileID] ?? [:]),
              !alternative.evidence.isMetadataSearch else { return nil }
        return alternatives.assessment(for: alternative, details: recordingDetails[fileID] ?? [:])
    }

    func matchAssessment(for candidate: MatchCandidate) -> RecordingMatchAssessment? {
        guard case let .fingerprint(_, score) = candidate.evidence,
              let assessment = matchAssessment(fileID: candidate.fileID, recordingID: candidate.recordingMBID) else { return nil }
        return RecordingMatchAssessment(score: score, plausibleRecordingCount: assessment.plausibleRecordingCount)
    }

    private func ensureCurrent(generation: Int, authorization: LibrarySyncReadiness.Authorization? = nil) throws {
        try Task.checkCancellation()
        guard generation == runGeneration else { throw CancellationError() }
        try (authorization ?? syncAuthorization)?.check()
    }

    private static func metadataFailureDescription(_ error: Error) -> String {
        if case LookupError.unauthorized = error {
            return musicBrainzUnauthorizedMessage
        }
        if let lookupError = error as? LookupError {
            return describe(lookupError)
        }
        return String(describing: error)
    }

    /// Cancels the in-flight pass, if any. Already-resolved rows in `rows`
    /// are left as they are; only unresolved files stop getting processed.
    func cancel() {
        runTask?.cancel()
        runGeneration += 1
        stopUnresolvedRows(among: Array(rows.keys), message: "Scan stopped", generation: runGeneration)
    }

    func reset() {
        cancel()
        rows = [:]
        recordingAlternatives = [:]
        recordingDetails = [:]
        lookupBaselines = [:]
        haltReason = nil
    }

    /// Runs the lookup pipeline for `fileIDs`, publishing each row's result
    /// to `rows` as it resolves. Replaces any previously in-flight run.
    func run(fileIDs: [Int64]) async {
        runTask?.cancel()
        runGeneration += 1
        let generation = runGeneration
        haltReason = nil
        recordingAlternatives = [:]
        recordingDetails = [:]
        lookupBaselines = [:]

        // E-J: reset every requested row to .pending BEFORE validating the
        // key. `stopUnresolvedRows` deliberately preserves terminal states
        // (.strong/.weak/.noMatch/.failed) so a mid-pass fatal halt doesn't
        // clobber rows already resolved THIS pass — but that same rule
        // means a no-key/keychain failure below would otherwise find these
        // IDs still carrying a STALE result from a PRIOR pass and leave it
        // standing. Resetting first ensures the only thing left standing
        // for a keyless pass is .stopped, for every requested row.
        rows = Dictionary(fileIDs.map { ($0, RowState.pending) }, uniquingKeysWith: { first, _ in first })

        do { syncAuthorization = try readiness?.capture() }
        catch {
            haltReason = error.localizedDescription
            stopUnresolvedRows(among: fileIDs, message: error.localizedDescription, generation: generation)
            return
        }

        let apiKey: String
        do {
            guard let loadedKey = try keyStore.load(), !loadedKey.isEmpty else {
                haltReason = Self.noAPIKeyConfiguredMessage
                stopUnresolvedRows(among: fileIDs, message: Self.noAPIKeyConfiguredMessage, generation: generation)
                return
            }
            apiKey = loadedKey
        } catch {
            let message = "Could not read the AcoustID API key from the Keychain: \(error)"
            haltReason = message
            stopUnresolvedRows(among: fileIDs, message: message, generation: generation)
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await processAll(fileIDs: fileIDs, apiKey: apiKey, generation: generation)
        }
        runTask = task
        await task.value
    }

    private func processAll(fileIDs: [Int64], apiKey: String, generation: Int) async {
        for fileID in fileIDs {
            if Task.isCancelled {
                return
            }

            let resolved: RowState
            do {
                resolved = try await resolveRow(fileID: fileID, apiKey: apiKey, generation: generation)
            } catch let lookupError as LookupError {
                // Only reached for .unauthorized/.server/.offline — resolveRow
                // converts every other LookupError into a per-row .failed
                // before it ever gets here. Guard after the await: a New Scan
                // may have superseded this pass while the lookup was in
                // flight, and its fresh rows/banner must not be clobbered by
                // this abandoned pass's fatal halt. The banner phrases the
                // halt ("Auto-tag pass stopped: …"); each stopped row carries
                // only the bare reason, since the view already prefixes it
                // with "Stopped — ".
                guard generation == runGeneration else { return }
                let reason = Self.describe(lookupError)
                haltReason = "Auto-tag pass stopped: \(reason)"
                stopUnresolvedRows(among: fileIDs, message: reason, generation: generation)
                return
            } catch let conflict as SeratoPathConflictError {
                guard generation == runGeneration else { return }
                rows[fileID] = .failed(conflict.localizedDescription)
                continue
            } catch is LibrarySyncReadinessError {
                stopUnresolvedRows(among: fileIDs, message: "Library synchronization superseded this scan. Scan again after sync finishes.", generation: generation)
                return
            } catch is CancellationError {
                // The pass was cancelled — a New Scan superseded it, or the user
                // left Auto-Tag. Now that backoff sleeps propagate cancellation
                // (finding #4001501076), stop the pass silently: never stamp a
                // spurious `.failed` on the in-flight row. A New Scan resets rows
                // itself; a plain cancel leaves already-resolved rows as-is.
                return
            } catch {
                guard generation == runGeneration else { return }
                rows[fileID] = .failed(String(describing: error))
                continue
            }
            // The lookup completed; only publish if a newer scan hasn't taken
            // over in the meantime.
            guard generation == runGeneration else { return }
            rows[fileID] = resolved
        }
    }

    /// Transitions every fileID among `fileIDs` that is still `.pending` —
    /// either the no-key/keychain early-return (E-J: `run` resets every
    /// requested row to `.pending` before validating the key, so a stale
    /// prior-pass result never survives a keyless re-scan) or a mid-pass
    /// fatal halt, for files not yet reached — to `.stopped(message)`.
    /// Already-resolved rows (`.strong`, `.weak`, `.noMatch`, `.failed`)
    /// from THIS pass are left exactly as they are. `nil` is handled only
    /// as defensive belt-and-suspenders — every requested id is always
    /// `.pending` by the time this runs. A no-op when `generation` is no
    /// longer current: a superseded pass must not stamp `.stopped` over the
    /// rows a newer scan has already reset.
    private func stopUnresolvedRows(among fileIDs: [Int64], message: String, generation: Int) {
        guard generation == runGeneration else { return }
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
    private func resolveRow(fileID: Int64, apiKey: String, generation: Int) async throws -> RowState {
        do {
            return try await lookUpCandidate(fileID: fileID, apiKey: apiKey, generation: generation)
        } catch let lookupError as LookupError {
            switch lookupError {
            case .unauthorized, .server, .offline:
                // Connection-wide or credential/server failures make every
                // remaining lookup pointless — halt the whole pass instead of
                // failing (and re-hammering) each file individually.
                throw lookupError
            case .rateLimited, .transport:
                return .failed(Self.describe(lookupError))
            }
        }
    }

    private func lookUpCandidate(fileID: Int64, apiKey: String, generation: Int) async throws -> RowState {
        guard let file = try await fetchFile(fileID: fileID) else {
            throw AutoTaggerRowFailure("file \(fileID) not found in the library")
        }
        try FileProcessingEligibility.requireProcessable(file)
        try syncAuthorization?.check(target: .file(file))
        let membershipToken = FileMembershipToken(fileId: fileID, revision: file.membershipRevision)

        let (fingerprintBytes, fingerprintBasis) = try await currentFingerprint(for: file)
        guard let fingerprintBase64 = FingerprintEncoder.base64(fromStoredBytes: fingerprintBytes) else {
            throw AutoTaggerRowFailure("empty or corrupt fingerprint for file \(fileID)")
        }

        let tags = try await runOffMainActor { [audioTagsReader] in try audioTagsReader(file.path) }
        guard let durationSeconds = tags.durationSeconds else {
            throw AutoTaggerRowFailure("missing audio duration for file \(fileID)")
        }

        // D-A: snapshot the file's ACTUAL on-disk identity as the lookup
        // sees it now — not the DB-indexed `FileRecord.fileSize`/`mtime`,
        // which no in-place edit ever updates. This is what apply-time
        // revalidation (`staleFileIDs`) re-checks against. Falls back to the
        // indexed values only if the stat fails (the file was just read for
        // tags, so that's degenerate).
        let lookupFreshness = await onDiskFreshness(ofFileAt: file.path)
            ?? FileFreshnessSnapshot(fileSize: file.fileSize, mtime: file.mtime)

        // Reject the row if the file changed between when the fingerprint was
        // taken (its basis) and this lookup snapshot — including the
        // cached-fingerprint path, which the mid-decode guard doesn't cover.
        // Otherwise the candidate would pair the OLD fingerprint's recording
        // with the NEW file's captured size/mtime as its expected identity, and
        // apply-time revalidation would pass and write that match onto the new
        // audio (finding #4000405424). A nil basis (stat failed at fingerprint
        // time) can't prove a change, so we proceed.
        if let fingerprintBasis, fingerprintBasis != lookupFreshness {
            throw AutoTaggerRowFailure(
                "file \(fileID) changed on disk between fingerprinting and lookup — re-scan to match the current audio"
            )
        }

        try await requireCurrent(membershipToken)
        let acoustIDResults = try await acoustIDClient.lookup(
            fingerprintBase64: fingerprintBase64,
            durationSeconds: Int(durationSeconds),
            apiKey: apiKey
        )

        try ensureCurrent(generation: generation)
        try await requireCurrent(membershipToken)
        var alternatives = RecordingAlternatives(results: acoustIDResults)
        var selected: RecordingAlternative?
        if let firstRecordingID = acoustIDResults.first(where: { result in !result.recordingIDs.isEmpty })?.recordingIDs.first {
            selected = alternatives.entries.first { alternative in alternative.recordingID == firstRecordingID }
        } else if let query = MetadataSearchQuery(artist: tags.artist, title: tags.title) {
            // A successful AcoustID answer with no recordings; failures threw above.
            let hits = try await withMusicBrainzErrors { [musicBrainzClient] in
                try await musicBrainzClient.searchRecordings(artist: query.artist, title: query.baseTitle)
            }
            try ensureCurrent(generation: generation)
            try await requireCurrent(membershipToken)
            for hit in hits {
                recordingDetails[fileID, default: [:]][hit.id] = hit
            }
            alternatives = RecordingAlternatives(metadataMatches: MetadataMatchRanker.rank(hits, for: query))
            selected = alternatives.entries.first
        }
        recordingAlternatives[fileID] = alternatives
        let baseline = LookupBaseline(fileID: fileID, membershipToken: membershipToken, fingerprintHash: Data(SHA256.hash(data: fingerprintBytes)),
                                      freshness: lookupFreshness, tags: tags)
        lookupBaselines[fileID] = baseline
        guard let selected else { return .noMatch }

        let recording = try await loadRecording(mbid: selected.recordingID)
        try ensureCurrent(generation: generation)
        try await requireCurrent(membershipToken)
        recordingDetails[fileID, default: [:]][selected.recordingID] = MBRecordingDetails(recording: recording, requestedID: selected.recordingID)
        let candidate = try Self.assembleCandidate(alternative: selected, recording: recording, baseline: baseline)
        let assessment = alternatives.assessment(for: selected, details: recordingDetails[fileID] ?? [:])
        return Self.classify(candidate, ambiguousRecording: assessment.hasMultiplePlausibleRecordings)
    }

    private func loadRecording(mbid: String) async throws -> MBRecording {
        try await withMusicBrainzErrors { [musicBrainzClient] in try await musicBrainzClient.recording(mbid: mbid) }
    }

    /// A MusicBrainz 401 must not read as a rejected AcoustID key, which
    /// would halt the pass; it fails only this row.
    private func withMusicBrainzErrors<Value: Sendable>(_ request: @Sendable () async throws -> Value) async throws -> Value {
        do {
            return try await request()
        } catch LookupError.unauthorized {
            throw LookupError.transport(Self.musicBrainzUnauthorizedMessage)
        }
    }

    private static func assembleCandidate(alternative: RecordingAlternative, recording: MBRecording, baseline: LookupBaseline) throws -> MatchCandidate {
        // Release defaults must use the same embedded-tag baseline as review;
        // the indexed Serato album can name a different pressing (#4000261459).
        guard let chosenRelease = ReleaseSelector.defaultRelease(from: recording.releases, existingAlbum: baseline.tags.album) else {
            throw AutoTaggerRowFailure("MusicBrainz recording \(alternative.recordingID) has no releases")
        }

        let artistCredit = recording.artistCredit.first
        return MatchCandidate(
            fileID: baseline.fileID,
            evidence: alternative.evidence,
            recordingMBID: recording.id ?? alternative.recordingID,
            artistMBID: artistCredit?.artist.id,
            fingerprintHash: baseline.fingerprintHash,
            expectedFileSize: baseline.freshness.fileSize,
            expectedMtime: baseline.freshness.mtime,
            chosenRelease: chosenRelease,
            availableReleases: recording.releases,
            isrc: recording.isrcs.first,
            // E-A: nothing to propose when the assembled display name is
            // empty — nil, never "", so a sparse match can never default
            // to blanking an existing artist on Confirm-All. Checked on
            // the assembled STRING, not just `artistCredit.isEmpty`: a
            // non-empty credit array whose entries all resolve to empty
            // names would otherwise still produce proposedArtist == "".
            proposedArtist: recording.creditedArtistName.isEmpty ? nil : recording.creditedArtistName,
            proposedTitle: recording.title,
            proposedAlbum: chosenRelease.title,
            proposedYear: recording.releaseGroup?.firstReleaseDate.flatMap(Self.year(fromMusicBrainzDate:)),
            currentFileYear: baseline.tags.year.map(Int.init),
            currentFileArtist: baseline.tags.artist,
            currentFileTitle: baseline.tags.title,
            currentFileAlbum: baseline.tags.album
        )
    }

    /// Metadata-search candidates are always `.weak`: text similarity is
    /// never strong evidence.
    private static func classify(_ candidate: MatchCandidate, ambiguousRecording: Bool = false) -> RowState {
        guard case let .fingerprint(_, score) = candidate.evidence else { return .weak(candidate) }
        return (score >= strongScoreThreshold && !ambiguousRecording) ? .strong(candidate) : .weak(candidate)
    }

    /// A MusicBrainz partial date's leading year (`"1988-05-09"` → `1988`).
    private static func year(fromMusicBrainzDate dateString: String) -> Int? {
        Int(dateString.prefix(4))
    }

    private static func describe(_ error: LookupError) -> String {
        switch error {
        case .unauthorized:
            "the AcoustID API key was rejected (401 Unauthorized)"
        case .rateLimited:
            "the lookup was rate-limited and retries were exhausted"
        case .server:
            "the lookup server returned repeated errors"
        case let .offline(message):
            "the network is unavailable (\(message))"
        case let .transport(message):
            message
        }
    }

    // MARK: - Fingerprint on demand

    /// Returns the file's stored fingerprint bytes, computing and
    /// persisting one first if the background `FingerprintWorker` hasn't
    /// processed this file yet. The Chromaprint decode is CPU-bound, so it
    /// runs off the main actor to keep the UI responsive.
    private func currentFingerprint(for file: FileRecord) async throws -> (bytes: Data, basis: FileFreshnessSnapshot?) {
        let authorization = syncAuthorization
        try authorization?.check()
        if file.fingerprintStatus == .done, let existing = file.chromaprintFingerprint,
           await storedFingerprintIsFresh(for: file)
        {
            // The on-disk stat this stored fingerprint corresponds to (its
            // freshness basis); `storedFingerprintIsFresh` just confirmed the
            // live file still matches it. Returned so `lookUpCandidate` can
            // reject a candidate whose file changes between here and the lookup
            // snapshot (finding #4000405424).
            let basis = FileFreshnessSnapshot(
                fileSize: file.fingerprintedSize ?? file.fileSize,
                mtime: file.fingerprintedMtime ?? file.mtime
            )
            return (existing, basis)
        }
        guard let fileID = file.id else {
            throw AutoTaggerRowFailure("file has no row id")
        }

        let path = file.path
        // Capture the freshness basis BEFORE the decode reads the file, not
        // after. A stat taken after the read could reflect a modification that
        // happened during/just after the read: the basis would then match the
        // POST-modification file while the fingerprint bytes describe the
        // PRE-modification audio, and every future scan would see
        // `live == basis` and trust a stale fingerprint forever. Capturing it
        // first means any change from here on makes the next scan's stat differ
        // and correctly triggers one more recompute (finding #3999114461).
        let freshnessBasis = await onDiskFreshness(ofFileAt: path)
        do {
            let hashes = try await runOffMainActor { [fingerprintFunction] in try fingerprintFunction(path) }
            let serialized = FingerprintEncoder.serialize(hashes)
            // Re-stat AFTER the decode and reject the fingerprint if the file
            // changed while it was being read: the bytes would then describe
            // old-or-mixed content, but `lookUpCandidate` goes on to read the
            // NEW file's tags and capture its post-change size/mtime as the
            // candidate's expected identity — so apply-time revalidation would
            // pass and write the OLD recording's match onto the NEW audio
            // (finding #4000261453). Failing the row is the safe outcome; a
            // re-scan fingerprints the settled file. (A nil stat on either side
            // means we can't prove a change, so we proceed — the imminent tag
            // read fails loudly if the file is genuinely gone.)
            let postDecodeFreshness = await onDiskFreshness(ofFileAt: path)
            if let before = freshnessBasis, let after = postDecodeFreshness, before != after {
                throw AutoTaggerRowFailure(
                    "file \(fileID) changed on disk while its fingerprint was being computed — re-scan to fingerprint the current audio"
                )
            }
            // Persist the pre-decode on-disk stat as the fingerprint's freshness
            // basis, so the NEXT scan trusts this fingerprint without
            // re-decoding the audio. Without this, a recompute updated only the
            // bytes and left the basis pinned to the stale index snapshot, so
            // every later scan of an edited file failed the freshness check and
            // re-decoded up to 120s of audio. If the file can't be stat'd we
            // omit the basis rather than record a wrong one — the fallback to
            // the index snapshot then applies.
            try await persistFingerprint(fileID: fileID, bytes: serialized, status: .done, freshnessBasis: freshnessBasis,
                                         expectedMembershipToken: FileMembershipToken(fileId: fileID, revision: file.membershipRevision), authorization: authorization)
            return (serialized, freshnessBasis)
        } catch {
            let decodeError = error
            if decodeError is LibrarySyncReadinessError || decodeError is SeratoPathConflictError || decodeError is CancellationError {
                throw decodeError
            }
            do {
                try await persistFingerprintFailure(for: file, authorization: authorization)
            } catch {
                if error is LibrarySyncReadinessError || error is SeratoPathConflictError || error is CancellationError {
                    throw error
                }
                throw AutoTaggerRowFailure(
                    "failed to compute fingerprint for file \(fileID): \(decodeError); could not persist failure: \(error)"
                )
            }
            if let failure = decodeError as? AutoTaggerRowFailure {
                throw failure
            }
            throw AutoTaggerRowFailure("failed to compute fingerprint for file \(fileID): \(decodeError)")
        }
    }

    private func persistFingerprintFailure(for original: FileRecord, authorization: LibrarySyncReadiness.Authorization?) async throws {
        try await database.writer.write { db in
            var targets: [SeratoConflictTarget] = [.file(original)]
            if let fileID = original.id, let current = try FileRecord.fetchOne(db, key: fileID) {
                targets.append(.file(current))
            }
            try FingerprintPersistence.withAuthorization(authorization, targets: targets) {
                guard let fileID = original.id,
                      let current = try FileRecord.fetchOne(db, key: fileID),
                      current.path == original.path,
                      current.fileSize == original.fileSize,
                      current.mtime == original.mtime,
                      current.fingerprintStatus == original.fingerprintStatus,
                      current.chromaprintFingerprint == original.chromaprintFingerprint,
                      current.fingerprintedSize == original.fingerprintedSize,
                      current.fingerprintedMtime == original.fingerprintedMtime
                else { return }
                // Compare and write in one transaction: a failure of stale .done
                // bytes is real, but cannot erase a concurrent successful decode.
                try FingerprintPersistence.write(fileID: fileID, fingerprint: nil, status: .failed,
                                                 expectedMembershipToken: FileMembershipToken(fileId: fileID, revision: original.membershipRevision), in: db)
            }
        }
    }

    /// Whether the file's stored `.done` fingerprint can still be trusted for
    /// a lookup (findings D-B, #3999114461): true when the file's CURRENT
    /// on-disk size+mtime match the basis the fingerprint was computed from.
    /// That basis is the fingerprint's OWN recorded snapshot
    /// (`fingerprintedSize`/`fingerprintedMtime`), so a recompute re-syncs it
    /// and an edited-then-recomputed file stops re-decoding on every scan. For
    /// rows fingerprinted before migration #009 or by the background worker
    /// those columns are nil; there the index-time `fileSize`/`mtime` snapshot
    /// still IS the fingerprint's basis, so we fall back to it. When the file
    /// can't be stat'd we can't prove it changed, so the stored bytes are
    /// kept — the imminent tag read fails loudly if the file is genuinely gone.
    private func storedFingerprintIsFresh(for file: FileRecord) async -> Bool {
        guard let current = await onDiskFreshness(ofFileAt: file.path) else { return true }
        let basisSize = file.fingerprintedSize ?? file.fileSize
        let basisMtime = file.fingerprintedMtime ?? file.mtime
        return current.fileSize == basisSize && current.mtime == basisMtime
    }

    /// Reads the file's current on-disk size+mtime off the main actor via
    /// the injected `fileFreshnessReader`. Nil when the file can't be
    /// stat'd (missing/unreadable). The single seam both the D-B fingerprint
    /// freshness check and the D-A apply-time revalidation read through.
    private func onDiskFreshness(ofFileAt path: String) async -> FileFreshnessSnapshot? {
        await Task.detached(priority: .userInitiated) { [fileFreshnessReader] in
            fileFreshnessReader(path)
        }.value
    }

    /// Runs a blocking closure off the main actor so CPU-bound FFI calls
    /// (Chromaprint decode, tag parsing) never stall the UI.
    private func runOffMainActor<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await Task.detached(priority: .userInitiated) {
            try work()
        }.value
    }

    // MARK: - Apply-time revalidation (D-A)

    /// Re-stat each confirmed candidate's file on disk NOW and compare to
    /// the on-disk snapshot captured at lookup (carried on the payload).
    /// Returns the fileIDs whose bytes changed — or whose file is now
    /// missing/unreadable, or whose row vanished — since review. The caller
    /// MUST exclude these from the apply and surface them (no silent drop):
    /// applying a reviewed MusicBrainz identity to audio that changed since
    /// review would mis-link a different recording. This is the REAL D-A
    /// guard; it lives here (not inside the engine's write transaction)
    /// because it needs file I/O, kept off the main actor.
    func staleFileIDs(for payloads: [ApplyMusicBrainzMatchPayload]) async throws -> Set<Int64> {
        guard !payloads.isEmpty else { return [] }
        let fileIDs = payloads.map(\.fileID)
        // Let a DB read failure propagate — swallowing it into an empty map
        // ("try?  ?? [:]") would mark every payload stale and tell the user
        // their audio files changed on disk, hiding an actual database error
        // (e.g. the SQLite file went missing or reports corruption) behind a
        // misleading recovery instruction. `applyConfirmed` reports it
        // distinctly.
        let originalTokens = membershipTokens(for: fileIDs)
        let pathByFileID = try await database.writer.read { db in
            try FileRecord.filter(keys: fileIDs).fetchAll(db)
                .reduce(into: [Int64: String]()) { accumulator, file in
                    if let id = file.id, file.libraryMembership == .active, file.fileAvailability == .available,
                       originalTokens[id].map({ $0.revision == file.membershipRevision }) != false
                    {
                        accumulator[id] = file.path
                    }
                }
        }

        var stale: Set<Int64> = []
        for payload in payloads {
            guard pathByFileID[payload.fileID] != nil else { stale.insert(payload.fileID); continue }
            guard let expectedFileSize = payload.expectedFileSize,
                  let expectedMtime = payload.expectedMtime
            else {
                // Legacy event journaled before D-A captured the on-disk
                // snapshot — nothing to revalidate against, and it predates
                // the check by definition. Treat as not stale.
                continue
            }
            guard let path = pathByFileID[payload.fileID] else {
                stale.insert(payload.fileID) // row gone from the DB — can't apply
                continue
            }
            guard let current = await onDiskFreshness(ofFileAt: path) else {
                stale.insert(payload.fileID) // file missing/unreadable now
                continue
            }
            if current.fileSize != expectedFileSize || current.mtime != expectedMtime {
                stale.insert(payload.fileID) // edited/replaced since review
            }
        }
        return stale
    }

    // MARK: - Database

    func membershipTokens(for fileIDs: [Int64]) -> [Int64: FileMembershipToken] {
        Dictionary(uniqueKeysWithValues: fileIDs.compactMap { fileID in
            lookupBaselines[fileID].map { (fileID, $0.membershipToken) }
        })
    }

    private func requireCurrent(_ token: FileMembershipToken, authorization: LibrarySyncReadiness.Authorization? = nil) async throws {
        let authorization = authorization ?? syncAuthorization
        try authorization?.check()
        try await database.writer.read { database in
            try authorization?.check()
            let current = try FileProcessingEligibility.currentFile(token, in: database)
            try authorization?.check(target: .file(current))
        }
        try authorization?.check()
    }

    private func fetchFile(fileID: Int64) async throws -> FileRecord? {
        try await database.writer.read { db in
            try FileRecord.fetchOne(db, key: fileID)
        }
    }

    private func persistFingerprint(
        fileID: Int64,
        bytes: Data?,
        status: FingerprintStatus,
        freshnessBasis: FileFreshnessSnapshot? = nil,
        requirePendingStatus: Bool = false,
        expectedMembershipToken: FileMembershipToken,
        authorization: LibrarySyncReadiness.Authorization?
    ) async throws {
        try await database.writer.write { db in
            let current = try FileProcessingEligibility.currentFile(expectedMembershipToken, in: db)
            try FingerprintPersistence.withAuthorization(authorization, targets: [.file(current)]) {
                try FileProcessingEligibility.requireCurrent(expectedMembershipToken, in: db)
                try FingerprintPersistence.write(
                    fileID: fileID, fingerprint: bytes, status: status, freshnessBasis: freshnessBasis,
                    requirePendingStatus: requirePendingStatus, expectedMembershipToken: expectedMembershipToken, in: db
                )
            }
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

/// Reads a file's current on-disk size + mtime, used to decide whether a
/// stored `.done` fingerprint is still valid for the file's current bytes
/// (finding D-B). Production reads via `FileMetadataCollector` (same `stat`
/// path that captured the indexed snapshot, so the units match); tests
/// inject a stub. Returns nil when the file can't be stat'd.
public typealias FileFreshnessReading = @Sendable (String) -> FileFreshnessSnapshot?

/// A file's current on-disk identity, in the same units as
/// `FileRecord.fileSize`/`mtime` (bytes; mtime seconds since the epoch).
public struct FileFreshnessSnapshot: Equatable, Sendable {
    public let fileSize: Int64
    public let mtime: Int64

    public init(fileSize: Int64, mtime: Int64) {
        self.fileSize = fileSize
        self.mtime = mtime
    }
}

/// Seam over `AcoustIDClient.lookup` so tests can stub AcoustID without a
/// real network call.
protocol AcoustIDLookupClient: Sendable {
    func lookup(fingerprintBase64: String, durationSeconds: Int, apiKey: String) async throws -> [AcoustIDResult]
}

extension AcoustIDClient: AcoustIDLookupClient {}

/// Seam over `MusicBrainzClient` so tests can stub MusicBrainz
/// without a real network call.
protocol MusicBrainzLookupClient: Sendable {
    func recording(mbid: String) async throws -> MBRecording
    func recordingDetails(mbid: String) async throws -> MBRecordingDetails
    func searchRecordings(artist: String, title: String) async throws -> [MBRecordingDetails]
}

extension MusicBrainzLookupClient {
    func recordingDetails(mbid: String) async throws -> MBRecordingDetails {
        try await MBRecordingDetails(recording: recording(mbid: mbid), requestedID: mbid)
    }
}

extension MusicBrainzClient: MusicBrainzLookupClient {}

/// Seam over `AcoustIDKeyStore.load` so tests can control "no key
/// configured" / "key present" / "keychain error" deterministically,
/// without touching the real system Keychain.
protocol AcoustIDKeyProviding: Sendable {
    func load() throws -> String?
}

extension AcoustIDKeyStore: AcoustIDKeyProviding {}
