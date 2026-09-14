import Combine
import Foundation
import GRDB

/// The "apply track mutation" primitive — every state-changing
/// operation in crate-agent routes through this actor. Holding the
/// chokepoint here guarantees:
///   1. mutations apply atomically (SQLite transaction)
///   2. every mutation produces a journal event with both forward
///      payload and inverse payload (enables undo + per-file history)
///   3. writes to Serato library files are gated on
///      `seratoWatchdog.isSeratoRunning` — when Serato is running, the
///      Serato-side write is queued and replayed when Serato exits.
///      Database state is updated immediately either way, so the UI
///      always reflects the user's intent even when Serato hasn't
///      seen the change yet.
///
/// Mutations supported in SP-1:
///   - `indexNewFile`              : insert a file row, log event
///   - `renameFile`                : update path, rewrite Serato refs
///   - `removeFile`                : delete a file row (does NOT touch
///                                   Serato — used as the inverse of
///                                   `indexNewFile` during undo).
///   - `setMetadata`               : update file's metadata snapshot
///                                   from Serato (no Serato write —
///                                   used by the reload flow)
///   - `commitMetadataToSerato`    : write metadata into Serato's
///                                   database V2 (no DB update —
///                                   assumes DB is already current).
///                                   Gated by SeratoWatchdog like
///                                   renames.
///   - `addTrackToSerato`          : insert a new otrk entry into
///                                   Serato's database V2 (drag-drop
///                                   import). Gated by SeratoWatchdog.
public actor OperationEngine {

    /// Injectable audio-file tag writer. Production wires in the
    /// Rust `writeAudioTags` FFI; tests inject a no-op (or recording)
    /// closure so they can exercise the mutation pipeline without
    /// real audio files on disk.
    public typealias FileTagWriter = @Sendable (String, AudioTagUpdate) throws -> Void

    /// Injectable database-V2 metadata batch writer. Production wires
    /// in the Rust `batchUpdateDatabaseRecords` FFI (one file read +
    /// one file write covering every track in the batch); tests inject
    /// a counter to assert that an N-row apply coalesces into ONE V2
    /// rewrite rather than N (issue C2b / #3998713590). Returns the
    /// number of otrks actually changed.
    public typealias SeratoMetadataBatchWriter =
        @Sendable (_ databasePath: String, _ updates: [SeratoTrackMetadataUpdate]) throws -> UInt32

    /// Injectable file-to-Trash mover. Production uses
    /// `FileManager.trashItem`; tests inject a no-op or recorder so
    /// the resolution flow can be exercised without actually moving
    /// files into the user's Trash.
    public typealias FileTrasher = @Sendable (String) throws -> Void

    private let readiness: LibrarySyncReadiness?
    private let database: LibraryDatabase
    private let seratoWatchdog: SeratoWatchdog
    private let seratoLocator: SeratoLibraryLocator
    private let fileTagWriter: FileTagWriter
    private let seratoMetadataBatchWriter: SeratoMetadataBatchWriter
    private let fileTrasher: FileTrasher
    private let activityLog: ActivityLog?

    /// Pending writes to Serato library files. Either a path
    /// rewrite or a metadata update. Drained when Serato exits via
    /// `drainPendingSeratoUpdates`.
    private var pendingSeratoWrites: [GuardedSeratoWrite] = []
    private var observedSeratoMetadata: [FileMembershipToken: SeratoMetadata] = [:]
    private var pendingFieldConflicts = Set<Int64>()
    private var pendingDuplicateCleanups: [Int64: PendingDuplicateCleanup] = [:]
    private var duplicateCleanupResults: [Int64: DuplicateCleanupResult] = [:]
    private var isDraining = false

    private enum ExternalWriteInterruption: Error {
        case deferred
        case superseded(Set<Int64>)
    }

    /// Backing subject for `queueDepthPublisher`. CurrentValueSubject
    /// emits the latest value on subscribe, so UI bindings render
    /// with the correct depth at mount time rather than waiting for
    /// the next mutation.
    ///
    /// `nonisolated(unsafe)`: the subject is read from
    /// `queueDepthPublisher` (a nonisolated computed property used by
    /// SwiftUI) and written from inside the actor. Combine subjects
    /// are internally thread-safe; `CurrentValueSubject` just doesn't
    /// carry a `Sendable` conformance in the current SDK. Localized
    /// opt-out is tighter than asserting Sendable on Apple's class.
    private nonisolated(unsafe) let queueDepthSubject = CurrentValueSubject<Int, Never>(0)

    /// Observable stream of `pendingSeratoWrites.count`. Emits a new
    /// value after every enqueue and every drain step. UI subscribers
    /// (e.g., the menu bar status item) display "N changes pending."
    public nonisolated var queueDepthPublisher: AnyPublisher<Int, Never> {
        queueDepthSubject.eraseToAnyPublisher()
    }

    public init(
        database: LibraryDatabase,
        seratoWatchdog: SeratoWatchdog,
        seratoLocator: SeratoLibraryLocator,
        fileTagWriter: @escaping FileTagWriter = { path, update in
            try writeAudioTags(filePath: path, update: update)
        },
        seratoMetadataBatchWriter: @escaping SeratoMetadataBatchWriter = { databasePath, updates in
            try batchUpdateDatabaseRecords(databasePath: databasePath, updates: updates)
        },
        fileTrasher: @escaping FileTrasher = { path in
            let url = URL(fileURLWithPath: path)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        },
        activityLog: ActivityLog? = nil,
        readiness: LibrarySyncReadiness? = nil
    ) {
        self.readiness = readiness
        self.database = database
        self.seratoWatchdog = seratoWatchdog
        self.seratoLocator = seratoLocator
        self.fileTagWriter = fileTagWriter
        self.seratoMetadataBatchWriter = seratoMetadataBatchWriter
        self.fileTrasher = fileTrasher
        self.activityLog = activityLog
    }

    private func note(_ message: String) async {
        guard let log = activityLog else { return }
        await log.log(message, category: .sync)
    }

    /// Apply a mutation with an auto-generated batch identifier. Use
    /// `apply(_:batchId:)` when grouping multiple mutations into a
    /// single user-initiated operation (so undo can replay them all).
    @discardableResult
    public func apply(_ mutation: TrackMutation) async throws -> Int64? {
        try await apply(mutation, batchId: UUID().uuidString)
    }

    /// Apply a mutation under a caller-supplied batch identifier. All
    /// mutations sharing a batch_id are treated as a single
    /// transaction for undo purposes.
    /// Returns nil when an observation confirms an unchanged state.
    @discardableResult
    public func apply(_ mutation: TrackMutation, batchId: String) async throws -> Int64? {
        let authorization = try readinessAuthorization(for: [mutation])
        let executionResult: GuardedExecutionResult = try await PhysicalFileMoveTransaction.write(to: database.writer, batchId: batchId) { db, moves in
            try authorization?.check()
            let result = try Self.executeAndLog(mutation: mutation, batchId: batchId, in: db, physicalMoves: moves)
            try authorization?.check()
            return result
        }

        try await routeSeratoWrites(executionResult.seratoWrites, batchId: batchId)

        return executionResult.eventId
    }

    @discardableResult
    public func apply(_ mutation: TrackMutation, expectedMembershipToken: FileMembershipToken, batchId: String = UUID().uuidString) async throws -> Int64? {
        let authorization = try readinessAuthorization(for: [mutation])
        let result = try await PhysicalFileMoveTransaction.write(to: database.writer, batchId: batchId) { database, moves in
            try authorization?.check()
            try Self.requireCurrentToken(expectedMembershipToken, mutation: mutation, in: database)
            let result = try Self.executeAndLog(mutation: mutation, batchId: batchId, in: database, physicalMoves: moves)
            try authorization?.check()
            return result
        }
        try await routeSeratoWrites(result.seratoWrites, batchId: batchId)
        return result.eventId
    }

    private static func requireCurrentToken(_ token: FileMembershipToken, mutation: TrackMutation, in database: GRDB.Database) throws {
        guard mutation.tokenFileID == token.fileId,
              let file = try FileRecord.fetchOne(database, key: token.fileId),
              file.membershipRevision == token.revision
        else {
            throw FileProcessingEligibilityError.superseded(fileId: token.fileId)
        }
    }

    func resolveDuplicate(target: FileRecord, keeper: FileRecord, batchID: String) async throws -> DuplicateCleanupResult {
        let intent = try PendingDuplicateCleanup(target: FileActionAuthority(target), keeper: FileActionAuthority(keeper), batchID: batchID)
        let fileID = intent.target.token.fileId
        if pendingDuplicateCleanups[fileID] != nil {
            return duplicateCleanupResults[fileID] ?? .pending
        }
        try await database.writer.read { database in
            try intent.target.validate(in: database)
            try intent.keeper.validate(in: database)
        }
        pendingDuplicateCleanups[fileID] = intent
        duplicateCleanupResults[fileID] = .pending
        await advanceDuplicateCleanup(fileID)
        return duplicateCleanupResults[fileID] ?? .failed("Cleanup lost its completion state.")
    }

    private func advanceDuplicateCleanup(_ fileID: Int64) async {
        while var intent = pendingDuplicateCleanups[fileID], intent.waitingEventID == nil {
            do {
                let mutation = intent.mutations[intent.step]
                let drain = LibrarySyncReadiness.drainAuthorization
                let authorization = drain == nil ? try readiness?.capture() : nil
                let readiness = readiness
                let stepIntent = intent
                let result = try await database.writer.write { database in
                    try authorization?.check()
                    if drain != nil, readiness?.permitsExternalWrites(drain: drain) == false {
                        throw LibrarySyncReadinessError.synchronizationRequired
                    }
                    try stepIntent.target.validate(in: database, audioWasTrashed: stepIntent.step == 3)
                    try stepIntent.keeper.validate(in: database)
                    let result = try Self.executeAndLog(mutation: mutation, batchId: stepIntent.batchID, in: database)
                    try authorization?.check()
                    return result
                }
                let writes = result.seratoWrites.map { write in
                    var guarded = write
                    guarded.requiredKeeper = intent.keeper
                    guarded.cleanupReceipt = intent.receipt
                    return guarded
                }
                let outcome: ResyncOutcome
                do {
                    outcome = try await routeSeratoWrites(writes, batchId: intent.batchID)
                } catch {
                    intent.waitingEventID = result.eventId
                    pendingDuplicateCleanups[fileID] = intent
                    pendingSeratoWrites.append(contentsOf: writes)
                    queueDepthSubject.send(pendingSeratoWrites.count)
                    duplicateCleanupResults[fileID] = .failed(Self.duplicateCleanupFailureMessage(intent, error: error))
                    await note(failedDuplicateCleanupMessage ?? error.localizedDescription)
                    return
                }
                if outcome.supersededCount > 0 {
                    throw FileProcessingEligibilityError.superseded(fileId: fileID)
                }
                if outcome.queuedCount > 0 {
                    duplicateCleanupResults[fileID] = .pending
                    intent.waitingEventID = result.eventId
                    pendingDuplicateCleanups[fileID] = intent
                    await note("Duplicate cleanup for \((intent.target.identity.path as NSString).lastPathComponent) is pending; its file row is retained until all external steps finish.")
                    return
                }
                try await completeDuplicateStep(&intent)
                if intent.step == intent.mutations.count {
                    await finishDuplicateCleanup(intent)
                    return
                }
                pendingDuplicateCleanups[fileID] = intent
            } catch {
                pendingDuplicateCleanups.removeValue(forKey: fileID)
                let message = error.localizedDescription
                duplicateCleanupResults[fileID] = error is FileProcessingEligibilityError ? .superseded(message) : .failed(message)
                await note("Duplicate cleanup stopped for file \(fileID): \(message)")
                return
            }
        }
    }

    private func completeDuplicateStep(_ intent: inout PendingDuplicateCleanup) async throws {
        if intent.step == 0, !intent.receipt.removedV2 {
            throw OperationEngineError.seratoRewriteFailed(path: seratoLocator.databaseV2Url.path, underlying: "Duplicate reference removal did not complete.")
        }
        intent.step = intent.receipt.removedRow ? intent.mutations.count : intent.step + 1
        intent.waitingEventID = nil
    }

    private static func duplicateCleanupFailureMessage(_ intent: PendingDuplicateCleanup, error: Error) -> String {
        "Cleanup stopped at step \(intent.step + 1) for \((intent.target.identity.path as NSString).lastPathComponent): \(error.localizedDescription). Fix the cause, then choose Retry Sync."
    }

    private func finishQueuedDuplicateStep(eventID: Int64, succeeded: Bool) async throws {
        guard var intent = pendingDuplicateCleanups.values.first(where: { $0.waitingEventID == eventID }) else { return }
        let fileID = intent.target.token.fileId
        guard succeeded else {
            pendingDuplicateCleanups.removeValue(forKey: fileID)
            duplicateCleanupResults[fileID] = .superseded("Duplicate cleanup was superseded; its remaining steps were cancelled.")
            return
        }
        try await completeDuplicateStep(&intent)
        duplicateCleanupResults[fileID] = .pending
        if intent.step == intent.mutations.count {
            await finishDuplicateCleanup(intent)
            return
        }
        pendingDuplicateCleanups[fileID] = intent
        await advanceDuplicateCleanup(fileID)
    }

    private func finishDuplicateCleanup(_ intent: PendingDuplicateCleanup) async {
        pendingDuplicateCleanups.removeValue(forKey: intent.target.token.fileId)
        duplicateCleanupResults[intent.target.token.fileId] = .completed
        await note("Duplicate cleanup completed for \((intent.target.identity.path as NSString).lastPathComponent).")
    }

    func pendingCleanupOwnsRemoval(of file: FileRecord) async throws -> Bool {
        guard let fileID = file.id, let intent = pendingDuplicateCleanups[fileID], intent.receipt.removedV2 else { return false }
        do {
            try await database.writer.read { database in
                try intent.target.validate(in: database)
                try intent.keeper.validate(in: database)
            }
            return true
        } catch is FileProcessingEligibilityError {
            pendingDuplicateCleanups.removeValue(forKey: fileID)
            duplicateCleanupResults[fileID] = .superseded("Duplicate cleanup was superseded by a changed keeper or target.")
            return false
        }
    }

    func supersedeReappearedCleanup(fileID: Int64) {
        pendingDuplicateCleanups.removeValue(forKey: fileID)
        duplicateCleanupResults[fileID] = .superseded("Duplicate cleanup was superseded because Serato re-added the file after removal.")
    }

    var duplicateCleanupMessage: String? {
        guard !duplicateCleanupResults.isEmpty else { return nil }
        let values = Array(duplicateCleanupResults.values)
        let completed = values.filter { $0 == .completed }.count
        let pending = values.filter { $0 == .pending }.count
        let failed = values.filter {
            if case .failed = $0 {
                true
            } else {
                false
            }
        }.count
        let superseded = values.count - completed - pending - failed
        return "Duplicate cleanup: \(completed) completed · \(pending) pending · \(failed) failed · \(superseded) superseded (see activity log)"
    }

    var failedDuplicateCleanupMessage: String? {
        duplicateCleanupResults.keys.sorted().compactMap { fileID -> String? in
            guard pendingDuplicateCleanups[fileID] != nil,
                  case let .failed(message) = duplicateCleanupResults[fileID] else { return nil }
            return message
        }.first
    }

    /// Apply many mutations under a single batch identifier, atomically.
    /// Returned event IDs omit unchanged observations and preserve input order.
    ///
    /// One SQLite write transaction covers every mutation's DB-side
    /// work — if any throws, none persist. External writes carry the
    /// transaction's membership revision and recheck lifecycle and
    /// Serato state before each write group. This is the path
    /// any caller that produces N>1 related mutations should take —
    /// for N renames the cost goes from N writer transactions and N
    /// actor hops to one of each.
    @discardableResult
    public func applyBatch(
        _ mutations: [TrackMutation],
        batchId: String,
        expectedMembershipTokens: [Int64: FileMembershipToken]? = nil
    ) async throws -> [Int64] {
        try await executeBatch(mutations, batchId: batchId, expectedMembershipTokens: expectedMembershipTokens)
    }

    func applyFilesystemObservations(_ mutations: [TrackMutation], batchId: String,
                                     moveExpectation: FilesystemMoveExpectation? = nil) async throws -> [Int64]
    {
        for mutation in mutations {
            switch mutation {
            case .setFileLibraryState, .observeFileLocation: break
            case let .renameFile(payload) where payload.physicalMove != true: break
            default: throw LibrarySyncReadinessError.synchronizationRequired
            }
        }
        return try await executeBatch(mutations, batchId: batchId, filesystemObservation: true, moveExpectation: moveExpectation)
    }

    private func readinessAuthorization(for mutations: [TrackMutation]) throws -> LibrarySyncReadiness.Authorization? {
        let requiresReady = mutations.contains { mutation in
            switch mutation {
            case .indexNewFile, .beginFileImport, .addTrackToSerato: false
            default: true
            }
        }
        return requiresReady ? try readiness?.capture() : nil
    }

    private func executeBatch(_ mutations: [TrackMutation], batchId: String,
                              expectedMembershipTokens: [Int64: FileMembershipToken]? = nil,
                              filesystemObservation: Bool = false,
                              moveExpectation: FilesystemMoveExpectation? = nil) async throws -> [Int64]
    {
        guard !mutations.isEmpty else { return [] }
        let authorization = filesystemObservation ? nil : try readinessAuthorization(for: mutations)
        let executionResults: [GuardedExecutionResult] = try await PhysicalFileMoveTransaction.write(to: database.writer, batchId: batchId) { db, moves in
            try authorization?.check()
            try moveExpectation?.validate(in: db)
            let results = try mutations.map { mutation in
                if let expectedMembershipTokens, let fileID = mutation.tokenFileID {
                    guard let token = expectedMembershipTokens[fileID] else {
                        throw FileProcessingEligibilityError.superseded(fileId: fileID)
                    }
                    try Self.requireCurrentToken(token, mutation: mutation, in: db)
                }
                return try Self.executeAndLog(mutation: mutation, batchId: batchId, in: db, physicalMoves: moves)
            }
            try moveExpectation?.validatePhysicalTargets()
            try authorization?.check()
            return results
        }

        let pendingWrites = executionResults.flatMap { $0.seratoWrites }
        try await routeSeratoWrites(pendingWrites, batchId: batchId)

        return executionResults.compactMap(\.eventId)
    }

    func organizeFiles(_ plans: [LibraryOrganizer.Plan], batchId: String) async throws -> LibraryOrganizer.Outcome {
        let authorization = try readiness?.capture()
        var results: [GuardedExecutionResult] = []
        var errors: [String] = []
        for plan in plans {
            do {
                let result = try await PhysicalFileMoveTransaction.write(to: database.writer, batchId: batchId) { database, moves in
                    try authorization?.check()
                    let token = FileMembershipToken(fileId: plan.id, revision: plan.membershipRevision)
                    try FileProcessingEligibility.requireCurrent(token, in: database)
                    let result = try Self.executeAndLog(mutation: .renameFile(.init(fileId: plan.id, newPath: plan.destinationPath,
                                                                              previousPath: plan.sourcePath, physicalMove: true)), batchId: batchId, in: database, physicalMoves: moves)
                    try authorization?.check()
                    return result
                }
                results.append(result)
            } catch let error as OperationEngineError {
                if case .externalSyncIncomplete = error {
                    throw error
                }
                errors.append(error.localizedDescription)
            } catch {
                errors.append("\((plan.sourcePath as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        try await routeSeratoWrites(results.flatMap(\.seratoWrites), batchId: batchId)
        return LibraryOrganizer.Outcome(batchId: batchId, movedCount: results.count, failureCount: errors.count, errors: errors)
    }

    func applyObservedBatch(_ mutations: [TrackMutation], authorization: SeratoSnapshotAuthorization,
                            expectedFiles: [FileObservationExpectation] = [], batchId: String = UUID().uuidString) async throws -> [Int64]
    {
        try await database.writer.write { connection in
            try authorization.check()
            for expected in expectedFiles {
                try expected.validate(in: connection)
            }
            let results = try mutations.map { mutation in
                try Self.validateObservedIdentity(mutation, in: connection)
                let result = try Self.executeAndLog(mutation: mutation, batchId: batchId, in: connection)
                guard result.seratoWrites.isEmpty else { throw SeratoMembershipSnapshotError.unsupportedSource }
                return result
            }
            try authorization.check()
            return results.compactMap(\.eventId)
        }
    }

    func observeSnapshotMetadata(_ payload: ObserveFileIdentityPayload, authorization: SeratoSnapshotAuthorization) async throws -> [Int64] {
        guard let observed = payload.metadata else { throw SeratoMembershipSnapshotError.unsupportedSource }
        let token = FileMembershipToken(fileId: payload.fileId, revision: payload.expectedRevision)
        let currentFields = Self.metadataFieldMap(observed)
        let captured = pendingSeratoWrites.filter { $0.token == token }
        var replacements: [(GuardedSeratoWrite, GuardedSeratoWrite?)] = []
        var overlay = observed
        var conflicts = Set<Int64>()
        var uncertainFields = Set<String>()
        for guarded in captured {
            guard case let .metadataUpdate(update) = guarded.write else { continue }
            let baseline = guarded.externalBaseline.map(Self.metadataFieldMap)
            let desired = Self.metadataFieldMap(update.metadata)
            let permitted = Set(desired.keys.filter { field in
                let saved = currentFields[field].flatMap { $0.isEmpty ? nil : $0 }
                let prior = baseline?[field].flatMap { $0.isEmpty ? nil : $0 }
                let intended = desired[field].flatMap { $0.isEmpty ? nil : $0 }
                return (baseline != nil && saved == prior) || saved == intended
            })
            if permitted.count != desired.count {
                conflicts.insert(guarded.eventId)
            }
            if baseline == nil {
                uncertainFields.formUnion(Set(desired.keys).subtracting(permitted))
            }
            let kept = Self.reducedMetadata(update.metadata, keeping: permitted)
            overlay = Self.overlayMetadata(kept, on: overlay)
            var replacement = guarded
            replacement.write = .metadataUpdate(.init(absolutePath: update.absolutePath, metadata: kept))
            replacements.append((guarded, permitted.isEmpty ? nil : replacement))
        }
        var observation = payload
        observation.metadata = overlay
        observation.observedMetadata = observed
        observation.previousObservedMetadata = observedSeratoMetadata[token]
        observation.uncertainV2Fields = uncertainFields.isEmpty ? nil : uncertainFields.sorted()
        let events = try await applyObservedBatch([.observeFileIdentity(observation)], authorization: authorization)
        observedSeratoMetadata[token] = observed
        pendingSeratoWrites = pendingSeratoWrites.compactMap { current in
            if let replacement = replacements.first(where: { $0.0 == current }) {
                return replacement.1
            }
            return current
        }
        pendingFieldConflicts.formUnion(conflicts)
        queueDepthSubject.send(pendingSeratoWrites.count)
        if !conflicts.isEmpty {
            await note("Queued metadata for \((payload.identity.path as NSString).lastPathComponent) was superseded in \(conflicts.count) change(s): saved Serato fields changed or their original external baseline is unknown. Other fields remain queued.")
        }
        return events
    }

    private static func overlayMetadata(_ update: SeratoMetadata, on original: SeratoMetadata) -> SeratoMetadata {
        SeratoMetadata(artist: update.artist ?? original.artist, title: update.title ?? original.title,
                       album: update.album ?? original.album, genre: update.genre ?? original.genre,
                       bpm: update.bpm ?? original.bpm, musicalKey: update.musicalKey ?? original.musicalKey,
                       comment: update.comment ?? original.comment, length: update.length ?? original.length,
                       label: update.label ?? original.label)
    }

    private static func validateObservedIdentity(_ mutation: TrackMutation, in database: GRDB.Database) throws {
        switch mutation {
        case let .indexNewFile(payload):
            let expected = FileMetadata(path: payload.path, volumeUuid: payload.volumeUuid, inode: payload.inode, fileSize: payload.fileSize, mtime: payload.mtime, lightweightHash: payload.lightweightHash)
            guard try FileMetadataCollector.collectVerified(at: payload.path) == expected else { throw SeratoMembershipSnapshotError.sourceChanged }
        case let .setFileLibraryState(payload) where payload.state.availability == .available:
            guard let file = try FileRecord.fetchOne(database, key: payload.fileId),
                  try !FileIdentityObservationMutation.isReplacement(file, identity: FileMetadataCollector.collectVerified(at: file.path))
            else {
                throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
            }
        case let .observeFileLocation(payload):
            let identity = try FileMetadataCollector.collectVerified(at: payload.path)
            guard let file = try FileRecord.fetchOne(database, key: payload.fileId),
                  identity.inode == payload.inode, identity.volumeUuid == payload.volumeUuid,
                  identity.fileSize == file.fileSize,
                  file.lightweightHash.map({ hash in hash == identity.lightweightHash }) ?? (file.mtime == identity.mtime)
            else {
                throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
            }
        default: break
        }
    }

    /// Route a committed batch's Serato-side writes: queue them if
    /// Serato is running (they drain on Serato exit — invariant #3),
    /// otherwise apply them now (coalesced — see
    /// `applyConsecutiveSeratoWrites`).
    ///
    /// The DB transaction has ALREADY committed by the time this runs:
    /// the mutations ARE applied and journaled. The SQLite commit and
    /// the external file writes are physically separate and cannot join
    /// one transaction, so a post-commit external-write failure can
    /// never mean "nothing happened." It is surfaced as a DISTINCT typed
    /// error — `.externalSyncIncomplete`, carrying the batchId — so the
    /// caller treats the batch as applied and finishes the external side
    /// via `resyncSeratoForBatch(batchId)`, NEVER a re-`applyBatch`
    /// (which would re-journal against the already-mutated rows and
    /// corrupt the undo baseline — invariant #2, issue #836). The queued
    /// (Serato-running) path never throws for external writes; only the
    /// Serato-not-running, write-throws path does.
    @discardableResult
    private func routeSeratoWrites(
        _ writes: [GuardedSeratoWrite],
        batchId: String
    ) async throws -> ResyncOutcome {
        let writes = writes.map { write in
            var captured = write
            captured.externalBaseline = observedSeratoMetadata[write.token]
            return captured
        }
        guard !writes.isEmpty else { return ResyncOutcome(appliedCount: 0, queuedCount: 0) }
        let isSeratoRunning = await seratoWatchdog.isSeratoRunning
        if isSeratoRunning || readiness?.permitsExternalWrites == false {
            pendingSeratoWrites.append(contentsOf: writes)
            queueDepthSubject.send(pendingSeratoWrites.count)
            return ResyncOutcome(appliedCount: 0, queuedCount: Set(writes.map(\.eventId)).count)
        }
        do {
            let outcome = try await applyGuardedSeratoWrites(writes)
            if outcome.supersededCount > 0 {
                await note(outcome.summaryMessage)
            }
            return outcome
        } catch {
            throw OperationEngineError.externalSyncIncomplete(
                batchId: batchId,
                underlying: String(describing: error)
            )
        }
    }

    /// Number of Serato library writes (renames + metadata updates)
    /// currently queued because Serato was running at apply time.
    /// Surfaced for UI ("M changes pending").
    public var pendingSeratoWriteCount: Int {
        pendingSeratoWrites.count
    }

    /// Reverse every event in `batchId` in newest-first order, applying
    /// each inverse mutation under a single fresh `undo:<originalBatchId>:<uuid>`
    /// batch. The new batch is itself journaled, so "undo of undo"
    /// (redo) is just another `undoBatch` call against the returned id.
    ///
    /// Failure modes:
    /// - empty batch → `batchNotFound`
    /// - batch contains an event whose inverse isn't supported (today:
    ///   `metadataCommittedToSerato`, `trackAddedToSerato`) →
    ///   `undoNotSupported`, thrown **before** any inverse runs, so
    ///   the DB stays in its pre-undo state
    /// - apply-time drift (e.g. the file was removed in a later batch
    ///   so renameFile can't find it) → bubbles up as `fileNotFound`
    ///   with partial undo state already applied — caller can issue
    ///   a follow-up undo of the partial undo batch to revert
    ///
    /// Returns the new batch id so the caller (UI) can offer "Undo the
    /// undo" without having to scan the events table.

    /// Replay a batch's Serato-side writes from the journaled forward
    /// events. Forward-recovery primitive for two cases:
    ///
    /// - The original external write failed mid-flight (a corrupted
    ///   .crate aborted a rename rewrite; a read-only file rejected a
    ///   tag write) after the DB transaction had already committed —
    ///   see `routeSeratoWrites` / `.externalSyncIncomplete` (issue
    ///   #836). The rows are already mutated in the DB; this brings the
    ///   Serato library + audio tags back in step with that DB state.
    /// - A user manually re-syncs from the History view.
    ///
    /// Covers `fileRenamed` (path rewrites) and `musicBrainzMatchApplied`
    /// (a `database V2` metadata update + an audio file-tag write,
    /// reconstructed from the forward payload + the file's CURRENT path
    /// in the DB — the DB is the source of truth). Other event types
    /// have no reconstructable Serato projection here and are skipped.
    ///
    /// Idempotent — re-writing a tag or record that already holds the
    /// target value is a no-op (the Rust writers return 0 and skip the
    /// file write), so re-journaling never happens: replay reads the
    /// journal, it never appends to it.
    ///
    /// Reuses the same coalescing write path as `applyBatch` (renames
    /// batched, metadata updates collapsed into ONE `database V2`
    /// rewrite, tag writes per-file) and honors the Serato-running guard
    /// exactly (invariant #3): when Serato is running the replay queues
    /// in memory and drains on Serato exit. Reports applied vs queued
    /// counts (per replayed event) so the UI can tell the user whether
    /// anything actually landed on disk — "Re-sync complete" while
    /// nothing did bit a user before (issue #64).
    @discardableResult
    public func resyncSeratoForBatch(_ batchId: String) async throws -> ResyncOutcome {
        let events: [EventRecord] = try await database.writer.read { db in
            try EventRecord
                .filter(Column("batch_id") == batchId)
                .order(Column("event_id").asc)
                .fetchAll(db)
        }
        guard !events.isEmpty else {
            throw OperationEngineError.batchNotFound(batchId: batchId)
        }

        await note("Re-syncing Serato library for batch — \(events.count) event\(events.count == 1 ? "" : "s") to inspect")

        let (writes, replayedEventCount, supersededCount) = try await reconstructResyncWrites(from: events)
        guard !writes.isEmpty else {
            let outcome = ResyncOutcome(appliedCount: 0, queuedCount: 0, supersededCount: supersededCount)
            await note(outcome.summaryMessage)
            return outcome
        }

        let isSeratoRunning = await seratoWatchdog.isSeratoRunning
        let outcome: ResyncOutcome
        if isSeratoRunning || readiness?.permitsExternalWrites == false {
            pendingSeratoWrites.append(contentsOf: writes)
            queueDepthSubject.send(pendingSeratoWrites.count)
            outcome = ResyncOutcome(appliedCount: 0, queuedCount: replayedEventCount, supersededCount: supersededCount)
        } else {
            let routed = try await applyGuardedSeratoWrites(writes)
            outcome = ResyncOutcome(appliedCount: routed.appliedCount, queuedCount: routed.queuedCount,
                                    supersededCount: supersededCount + routed.supersededCount)
        }
        await note(outcome.summaryMessage)
        return outcome
    }

    /// Rebuild the Serato-side writes for a batch's replayable events
    /// from their journaled forward payloads. Returns the writes (in
    /// event order) plus the count of events that contributed at least
    /// one write, which drives the applied/queued figures in
    /// `ResyncOutcome`.
    private func reconstructResyncWrites(
        from events: [EventRecord]
    ) async throws -> (writes: [GuardedSeratoWrite], replayedEventCount: Int, supersededCount: Int) {
        // Every replay except a rename needs the file's CURRENT absolute
        // path (the DB is the source of truth — the file may have been
        // renamed since; a rename carries both paths in its own payload).
        // Batch-read every referenced file row once rather than per event.
        let pathDependentFileIds = events.compactMap(\.fileId)
        let filesByID = try await database.writer.read { db in
            try Self.fetchFiles(fileIDs: pathDependentFileIds, in: db).reduce(into: [Int64: FileRecord]()) { files, file in
                if let fileID = file.id {
                    files[fileID] = file
                }
            }
        }
        let pathByFileId: [Int64: String]
        if pathDependentFileIds.isEmpty {
            pathByFileId = [:]
        } else {
            pathByFileId = filesByID.mapValues(\.path)
        }

        // Re-sync must project each file's CURRENT external state, not blindly
        // replay this batch's journaled writes. A batch may have been undone or
        // a file re-matched since, and Serato's `database V2` and the audio tag
        // are INDEPENDENT stores whose FIELDS different events patch separately.
        // A journaled write is a per-FIELD cherry-picked patch, so supersession
        // is tracked per (file, target, field): we keep each replayed write's
        // field only when this event is the latest to have actually written
        // that field. So a failed earlier title write survives a later
        // artist-only write to the same target (finding #4000806481), while an
        // undone/superseded field is dropped — and each kept field carries its
        // exact value (including "" clears) straight from the journaled payload.
        let (latestV2FieldWriter, latestTagFieldWriter) =
            try await latestFieldWriterEventIds(pathByFileId: pathByFileId)

        var writes: [GuardedSeratoWrite] = []
        var replayedEventCount = 0
        var supersededCount = 0
        let decoder = JSONDecoder()
        for event in events {
            let reconstructed = try Self.resyncWrites(
                for: event, pathByFileId: pathByFileId, decoder: decoder
            )
            guard event.eventType.hasReplayableSeratoProjection else { continue }
            guard let fileId = event.fileId, let eventId = event.eventId,
                  let file = filesByID[fileId],
                  let token = try SeratoWriteEligibility.replayToken(event: event, file: file),
                  reconstructed.allSatisfy({ SeratoWriteEligibility.permits($0, file: file) })
            else {
                supersededCount += 1
                continue
            }
            let kept = reconstructed.compactMap {
                Self.reduceWriteToCurrentFields(
                    $0, eventId: eventId, fileId: fileId,
                    latestV2FieldWriter: latestV2FieldWriter,
                    latestTagFieldWriter: latestTagFieldWriter
                )
            }
            if kept != reconstructed {
                supersededCount += 1
            }
            if !kept.isEmpty {
                writes.append(contentsOf: kept.map { GuardedSeratoWrite(token: token, write: $0, eventId: eventId, originalIdentity: file.identity, externalBaseline: observedSeratoMetadata[token]) })
                replayedEventCount += 1
            }
        }
        return (writes, replayedEventCount, supersededCount)
    }

    /// Event types whose journaled payload can reconstruct a Serato/audio-tag
    /// write (the same set `resyncWrites` handles, minus rename which is a
    /// path-only transition, projected to the current path rather than ranked).
    private static let metadataOrTagProjectingEventTypes: Set<EventType> = [
        .musicBrainzMatchApplied, .musicBrainzMatchReverted,
        .metadataCommittedToSerato, .fileTagsWritten,
    ]

    /// Event types that determine which event is the latest to OWN a field,
    /// for re-sync supersession. A superset of the projecting types above:
    /// it also includes `.metadataSet` — a Serato-authoritative import (the
    /// scanner importing a user's in-Serato edit) or hygiene merge. Such an
    /// event emits no outbound write of its own (`resyncWrites` returns [] for
    /// it), but it IS the newest authoritative value of the database-V2 field
    /// it set, so it must supersede an older MusicBrainz match's V2 write —
    /// otherwise re-syncing that older batch clobbers the user's newer Serato
    /// value (finding #4001251164). It claims V2 ownership only: a Serato edit
    /// does not rewrite the audio file's embedded tags, so the match keeps
    /// ownership of the audio-tag field.
    private static let fieldOwnershipEventTypes: Set<EventType> =
        metadataOrTagProjectingEventTypes.union([.metadataSet, .fileIdentityObserved])

    /// The non-nil fields of a `SeratoMetadata`, keyed by a stable field name.
    /// An empty-string value (a clear) is a real value and IS included.
    private static func metadataFieldMap(_ metadata: SeratoMetadata) -> [String: String] {
        var result: [String: String] = [:]
        if let value = metadata.artist { result["artist"] = value }
        if let value = metadata.title { result["title"] = value }
        if let value = metadata.album { result["album"] = value }
        if let value = metadata.genre { result["genre"] = value }
        if let value = metadata.bpm { result["bpm"] = value }
        if let value = metadata.musicalKey { result["key"] = value }
        if let value = metadata.comment { result["comment"] = value }
        if let value = metadata.length { result["length"] = value }
        if let value = metadata.label { result["label"] = value }
        return result
    }

    /// A copy of `metadata` with only the fields in `keep`; every other field
    /// becomes nil (leave-unchanged for the writers).
    private static func reducedMetadata(_ metadata: SeratoMetadata, keeping keep: Set<String>) -> SeratoMetadata {
        SeratoMetadata(
            artist: keep.contains("artist") ? metadata.artist : nil,
            title: keep.contains("title") ? metadata.title : nil,
            album: keep.contains("album") ? metadata.album : nil,
            genre: keep.contains("genre") ? metadata.genre : nil,
            bpm: keep.contains("bpm") ? metadata.bpm : nil,
            musicalKey: keep.contains("key") ? metadata.musicalKey : nil,
            comment: keep.contains("comment") ? metadata.comment : nil,
            length: keep.contains("length") ? metadata.length : nil,
            label: keep.contains("label") ? metadata.label : nil
        )
    }

    /// Reduce one reconstructed write to only the fields this event still owns
    /// (is the latest writer of) for the write's target; returns nil if none
    /// survive. Path-only writes pass through unchanged.
    private static func reduceWriteToCurrentFields(
        _ write: SeratoPendingWrite,
        eventId: Int64,
        fileId: Int64,
        latestV2FieldWriter: [Int64: [String: Int64]],
        latestTagFieldWriter: [Int64: [String: Int64]]
    ) -> SeratoPendingWrite? {
        switch write {
        case .metadataUpdate(let update):
            let latest = latestV2FieldWriter[fileId] ?? [:]
            let keep = Set(metadataFieldMap(update.metadata).keys.filter { latest[$0] == eventId })
            guard !keep.isEmpty else { return nil }
            return .metadataUpdate(SeratoPendingMetadataUpdate(
                absolutePath: update.absolutePath,
                metadata: reducedMetadata(update.metadata, keeping: keep)
            ))
        case .fileTagWrite(let tagWrite):
            let latest = latestTagFieldWriter[fileId] ?? [:]
            let keep = Set(metadataFieldMap(tagWrite.metadata).keys.filter { latest[$0] == eventId })
            let keepYear = (tagWrite.year != nil || tagWrite.clearYear) && latest["year"] == eventId
            guard !keep.isEmpty || keepYear else { return nil }
            return .fileTagWrite(SeratoPendingFileTagWrite(
                absolutePath: tagWrite.absolutePath,
                metadata: reducedMetadata(tagWrite.metadata, keeping: keep),
                year: keepYear ? tagWrite.year : nil,
                clearYear: keepYear ? tagWrite.clearYear : false
            ))
        case .rename, .addTrack, .removeFromDatabase, .removeFromCrates, .trashFile:
            return write
        }
    }

    private static func fileIDChunks(_ fileIDs: [Int64]) -> [[Int64]] {
        let uniqueIDs = Array(Set(fileIDs)).sorted()
        // Leave room for event-type bindings even on a 999-variable SQLite.
        let chunkSize = 900
        return stride(from: 0, to: uniqueIDs.count, by: chunkSize).map { start in
            Array(uniqueIDs[start..<min(start + chunkSize, uniqueIDs.count)])
        }
    }

    private static func fetchFiles(fileIDs: [Int64], in db: GRDB.Database) throws -> [FileRecord] {
        try fileIDChunks(fileIDs).flatMap { chunk in try FileRecord.filter(keys: chunk).fetchAll(db) }
    }

    private static func fetchFileEvents(
        fileIDs: [Int64], eventTypes: Set<EventType>, in db: GRDB.Database
    ) throws -> [EventRecord] {
        let typeValues = eventTypes.map(\.rawValue)
        return try fileIDChunks(fileIDs).flatMap { chunk in
            try EventRecord.fetchAll(db, sql: """
                SELECT * FROM events
                WHERE file_id IN (\(databaseQuestionMarks(count: chunk.count)))
                  AND event_type IN (\(databaseQuestionMarks(count: typeValues.count)))
                ORDER BY event_id ASC
                """, arguments: StatementArguments(chunk) + StatementArguments(typeValues))
        }
    }

    /// For each file in `pathByFileId`, the latest event id that actually wrote
    /// each FIELD, per target (Serato V2 and the audio tag), across EVERY batch.
    /// Ranking per field (not per whole target) is what lets a still-current
    /// title survive a later artist-only write to the same target.
    private func latestFieldWriterEventIds(
        pathByFileId: [Int64: String]
    ) async throws -> (v2: [Int64: [String: Int64]], tag: [Int64: [String: Int64]]) {
        let fileIds = Array(pathByFileId.keys)
        guard !fileIds.isEmpty else { return ([:], [:]) }
        let history = try await database.writer.read { db in
            try Self.fetchFileEvents(fileIDs: fileIds, eventTypes: Self.fieldOwnershipEventTypes, in: db)
        }

        var v2: [Int64: [String: Int64]] = [:]
        var tag: [Int64: [String: Int64]] = [:]
        let decoder = JSONDecoder()
        for event in history {
            guard let fileId = event.fileId, let eventId = event.eventId else { continue }
            // A Serato-authoritative import/set claims the database-V2 field it
            // wrote (so a later such edit supersedes an older match's V2 write)
            // but emits no outbound write and never claims the audio-TAG field —
            // a Serato edit doesn't touch the file's embedded tags
            // (finding #4001251164). It claims ownership only of the fields it
            // actually CHANGED (`metadata` vs `previousMetadata`), NOT every
            // field in its snapshot: the scanner imports a FULL snapshot of the
            // V2 row whenever any one field drifts, so claiming the whole
            // snapshot would wrongly strip the older match's ownership of
            // co-imported fields the user never touched — and with it their
            // re-sync restore path (independent-review concern on #4001251164).
            if event.eventType == .fileIdentityObserved {
                let payload = try Self.decodeEventPayload(ObserveFileIdentityPayload.self, event: event, decoder: decoder)
                guard let metadata = payload.metadata else { continue }
                for field in payload.uncertainV2Fields ?? [] {
                    v2[fileId, default: [:]][field] = eventId
                }
                if let observed = payload.observedMetadata {
                    if let previous = payload.previousObservedMetadata {
                        Self.claimChangedV2Fields(metadata: observed, previous: previous, fileID: fileId, eventID: eventId, owners: &v2)
                    }
                    continue
                }
                let previous = try decoder.decode(FileRecord.self, from: Data(event.inversePayloadJson.utf8))
                Self.claimChangedV2Fields(metadata: metadata, previous: previous.seratoMetadata, fileID: fileId, eventID: eventId, owners: &v2)
                continue
            }
            if event.eventType == .metadataSet {
                let payload = try Self.decodeEventPayload(SetMetadataPayload.self, event: event, decoder: decoder)
                // Legacy undo batches predate the explicit authority flag.
                // Their metadata snapshots only restored SQLite; the paired
                // commit event owns the outbound V2 restore.
                guard payload.isSeratoAuthoritative ?? !event.batchId.hasPrefix("undo:") else { continue }
                Self.claimChangedV2Fields(metadata: payload.metadata, previous: payload.previousMetadata, fileID: fileId, eventID: eventId, owners: &v2)
                continue
            }
            // ASC order → the last event to write a field wins for that field.
            for write in try Self.resyncWrites(for: event, pathByFileId: pathByFileId, decoder: decoder) {
                switch write {
                case .metadataUpdate(let update):
                    for key in Self.metadataFieldMap(update.metadata).keys { v2[fileId, default: [:]][key] = eventId }
                case .fileTagWrite(let tagWrite):
                    for key in Self.metadataFieldMap(tagWrite.metadata).keys { tag[fileId, default: [:]][key] = eventId }
                    if tagWrite.year != nil || tagWrite.clearYear { tag[fileId, default: [:]]["year"] = eventId }
                case .rename, .addTrack, .removeFromDatabase, .removeFromCrates, .trashFile:
                    break
                }
            }
        }
        return (v2, tag)
    }

    private static func claimChangedV2Fields(metadata: SeratoMetadata, previous: SeratoMetadata, fileID: Int64, eventID: Int64, owners: inout [Int64: [String: Int64]]) {
        for key in changedMetadataFields(metadata, previous: previous) {
            owners[fileID, default: [:]][key] = eventID
        }
    }

    nonisolated static func changedMetadataFields(_ metadata: SeratoMetadata, previous: SeratoMetadata) -> Set<String> {
        let newFields = metadataFieldMap(metadata)
        let previousFields = metadataFieldMap(previous)
        return Set(newFields.keys).union(previousFields.keys).filter { newFields[$0] != previousFields[$0] }
    }

    /// Whether an event's Serato writes are reconstructed against the
    /// file's CURRENT path (looked up in the DB) rather than paths
    /// carried in the event's own payload. Renames carry both paths, so
    /// they don't need the lookup; every other replayable type does.
    private static func eventNeedsCurrentFilePath(_ eventType: EventType) -> Bool {
        switch eventType {
        case .musicBrainzMatchApplied, .metadataCommittedToSerato, .fileTagsWritten,
             .musicBrainzMatchReverted, .fileRenamed:
            // Renames are re-targeted to the file's CURRENT path on resync (see
            // `resyncWrites`), so they need the DB lookup too.
            return true
        case .trackImported, .fileRemoved, .metadataSet,
             .trackAddedToSerato, .fileTrashed, .trackRemovedFromSerato,
             .fileRemovedFromCrates, .fileLibraryStateChanged, .fileLocationObserved, .fileIdentityObserved, .fileImportRequested:
            return false
        }
    }

    private static func decodeEventPayload<Payload: Decodable>(
        _ type: Payload.Type, event: EventRecord, decoder: JSONDecoder
    ) throws -> Payload {
        do {
            return try decoder.decode(type, from: Data(event.payloadJson.utf8))
        } catch {
            throw OperationEngineError.eventPayloadDecodingFailed(
                eventId: event.eventId, batchId: event.batchId,
                eventType: event.eventType, underlying: String(describing: error)
            )
        }
    }

    /// Reconstruct one event's Serato writes from its forward payload.
    /// The single "event → pending Serato writes" mapping every replay
    /// flows through — `resyncSeratoForBatch` then routes the result
    /// through the shared `applyConsecutiveSeratoWrites` coalescing path
    /// (invariant #3 guard, idempotent, no re-journaling). Covers the five
    /// event types that project onto Serato/audio-tag writes: `fileRenamed`,
    /// `musicBrainzMatchApplied`, `metadataCommittedToSerato`, `fileTagsWritten`,
    /// and `musicBrainzMatchReverted` (which re-emits an undo's restore writes).
    /// Malformed payloads throw before any writes run. Empty for event types
    /// with no replayable Serato projection. Kept in sync with
    /// `EventType.hasReplayableSeratoProjection`.
    private static func resyncWrites(
        for event: EventRecord,
        pathByFileId: [Int64: String],
        decoder: JSONDecoder
    ) throws -> [SeratoPendingWrite] {
        switch event.eventType {
        case .fileRenamed:
            let payload = try decodeEventPayload(RenameFilePayload.self, event: event, decoder: decoder)
            // Missing `previousPath` (older events before this field was
            // always populated) leaves no source path to rewrite from.
            guard !payload.previousPath.isEmpty else { return [] }
            // Re-target to the file's CURRENT path, not this event's journaled
            // `newPath`. A file renamed twice (/old→/mid then /mid→/new) whose
            // first Serato rewrite failed would otherwise be replayed only as
            // /old→/mid, leaving Serato at /mid while the DB/file are at /new
            // (finding #4000668519). Rewriting every journaled old-path to the
            // current path means whichever prior path Serato is stuck at is
            // moved to the current one; the non-matching ones no-op. Falls back
            // to the journaled newPath if the current path is unavailable.
            let currentPath = event.fileId.flatMap { pathByFileId[$0] } ?? payload.newPath
            return [.rename(SeratoPendingRename(
                oldAbsolutePath: payload.previousPath,
                newAbsolutePath: currentPath
            ))]
        case .musicBrainzMatchApplied:
            let payload = try decodeEventPayload(ApplyMusicBrainzMatchPayload.self, event: event, decoder: decoder)
            guard let fileId = event.fileId,
                  let absolutePath = pathByFileId[fileId] else { return [] }
            return musicBrainzSeratoWrites(
                absolutePath: absolutePath,
                artist: payload.artist,
                title: payload.title,
                album: payload.album,
                year: payload.year
            )
        case .metadataCommittedToSerato:
            // Hygiene / importer path: re-emit the database-V2 metadata
            // update the forward `commitMetadataToSerato` produced.
            let payload = try decodeEventPayload(CommitMetadataToSeratoPayload.self, event: event, decoder: decoder)
            guard let fileId = event.fileId,
                  let absolutePath = pathByFileId[fileId] else { return [] }
            return [.metadataUpdate(SeratoPendingMetadataUpdate(
                absolutePath: absolutePath, metadata: payload.metadata
            ))]
        case .fileTagsWritten:
            // Hygiene / importer path: re-emit the audio file-tag write the
            // forward `writeFileTags` produced. Year rides through the
            // audio-tag frames Serato itself doesn't store; the forward
            // mutation carried none here (its pending write left year nil),
            // so the replay mirrors that.
            let payload = try decodeEventPayload(WriteFileTagsPayload.self, event: event, decoder: decoder)
            guard let fileId = event.fileId,
                  let absolutePath = pathByFileId[fileId] else { return [] }
            return [.fileTagWrite(SeratoPendingFileTagWrite(
                absolutePath: absolutePath, metadata: payload.metadata
            ))]
        case .musicBrainzMatchReverted:
            // Re-emit the RESTORE writes an undo produced, so a tag restore
            // that failed mid-`undoBatch` has a recovery path (#3999974011).
            // The event's forward payload IS the RevertMusicBrainzMatchPayload;
            // its `.applied` carries the captured pre-match tags to restore.
            let payload = try decodeEventPayload(RevertMusicBrainzMatchPayload.self, event: event, decoder: decoder)
            guard let fileId = event.fileId,
                  let absolutePath = pathByFileId[fileId] else { return [] }
            return musicBrainzRevertSeratoWrites(applied: payload.applied, absolutePath: absolutePath)
        case .trackImported, .fileRemoved, .metadataSet, .trackAddedToSerato,
             .fileTrashed, .trackRemovedFromSerato, .fileRemovedFromCrates, .fileLibraryStateChanged, .fileLocationObserved, .fileIdentityObserved, .fileImportRequested:
            return []
        }
    }

    @discardableResult
    public func undoBatch(_ batchId: String) async throws -> String {
        let authorization = try readiness?.capture()
        let events: [EventRecord] = try await database.writer.read { db in
            try EventRecord
                .filter(Column("batch_id") == batchId)
                .order(Column("event_id").desc)
                .fetchAll(db)
        }

        guard !events.isEmpty else {
            throw OperationEngineError.batchNotFound(batchId: batchId)
        }

        // Out-of-order undo guard (finding #3999974010 / follow-up). A
        // MusicBrainz match in this batch cannot be cleanly reverted if the
        // same file was re-matched — or reverted — by a LATER event in a
        // DIFFERENT batch: undoing it would unlink the file from its current
        // match and rewrite its audio tags past that match. The authoritative
        // signal is the event log, NOT the fingerprint row's identity/reference
        // state — a same-batch sibling (a different file sharing the row) and a
        // cross-batch re-match of THIS file (even to the same recording, a
        // different release) leave identical row state, yet one must undo and
        // the other must be rejected. Checked before any mutation so the atomic
        // undo fails clean, and History surfaces it so the user undoes the
        // newer match first (LIFO).
        try await assertNoLaterMatchSupersedes(events: events, batchId: batchId)

        // Pre-decode every inverse before mutating anything. If any
        // event in the batch is non-reversible, we fail clean — no
        // partial undo state lands in the DB.
        let inverseMutations = try events.map { event in
            try Self.decodeInverseMutation(event: event)
        }

        let undoBatchId = "undo:\(batchId):\(UUID().uuidString)"
        // One transaction for every inverse mutation in the batch.
        // Undo is conceptually atomic: either the whole batch
        // reverts or none of it does. With N transactions (the
        // pre-batch shape) we'd risk leaving the DB half-undone if
        // one inverse hit a fileNotFound mid-loop.
        let results = try await PhysicalFileMoveTransaction.write(to: database.writer, batchId: undoBatchId) { database, moves in
            try authorization?.check()
            for event in events {
                guard let fileID = event.fileId else { continue }
                guard let file = try FileRecord.fetchOne(database, key: fileID),
                      file.libraryMembership != .retired,
                      try SeratoWriteEligibility.replayToken(event: event, file: file) != nil
                else {
                    throw FileProcessingEligibilityError.superseded(fileId: fileID)
                }
            }
            let results = try inverseMutations.map { mutation in
                try Self.executeAndLog(mutation: mutation, batchId: undoBatchId, in: database, physicalMoves: moves)
            }
            try authorization?.check()
            return results
        }
        try await routeSeratoWrites(results.flatMap(\.seratoWrites), batchId: undoBatchId)
        return undoBatchId
    }

    /// Throws `undoSupersededByLaterMatch` if any match-affecting event in the
    /// batch would be reverted OUT OF ORDER — i.e. it is not the file's current
    /// effective match state.
    ///
    /// The signal must be the file's *net current* state, not the mere presence
    /// of later log rows: a later match that was itself undone leaves the log
    /// row behind but is no longer live, and counting it kept the original
    /// match un-undoable forever even after the LIFO recovery the guard is meant
    /// to enable (finding #4000668517). So per file we replay its match events
    /// as a LIFO stack (`musicBrainzMatchApplied` pushes, `musicBrainzMatchReverted`
    /// pops):
    ///  - Undoing an APPLY is in order iff that apply is the stack top (the
    ///    file's current match). A later apply still on the stack (live re-match,
    ///    same or different recording/release) blocks it; a later apply that was
    ///    popped by its own revert does not (finding #3999974010, #4000261010).
    ///  - Undoing a REVERT is a REDO (re-applying the reverted match); it is in
    ///    order iff that revert is the file's LAST match event — anything after
    ///    it (a newer match or revert) means the redo is out of order
    ///    (finding #4000261463).
    ///
    /// Additionally, undoing an APPLY is rejected if the file's CURRENT value of
    /// a field the match applied differs from what the match applied — a later
    /// edit changed it, and the inverse would restore the match's pre-apply
    /// value and clobber that edit (finding #4000806477). This compares the
    /// current VALUE (not the mere presence of a later event), so an edit that
    /// was itself undone, or that merely re-affirmed the match's value (as
    /// `LibraryScanner`'s drift `setMetadata` does — it re-writes the full
    /// artist/title/album snapshot on any field's drift), does not block the
    /// undo (the presence-based check would have — review of #4000806477).
    ///
    /// The redo direction (undoing a REVERT re-applies the match's values) is
    /// guarded symmetrically: it is rejected when a field the match touched no
    /// longer holds the value the revert restored, since redoing would write
    /// the match value back over a later edit.
    private func assertNoLaterMatchSupersedes(events: [EventRecord], batchId _: String) async throws {
        let matchEvents = events.filter {
            $0.eventType == .musicBrainzMatchApplied || $0.eventType == .musicBrainzMatchReverted
        }
        guard !matchEvents.isEmpty else { return }
        let fileIds = Array(Set(matchEvents.compactMap(\.fileId)))
        guard !fileIds.isEmpty else { return }

        // Per-file MATCH-event history (for the LIFO stack), plus each file's
        // CURRENT row (for the value comparison), read together.
        let (history, currentFiles): ([EventRecord], [Int64: FileRecord]) = try await database.writer.read { db in
            let history = try Self.fetchFileEvents(fileIDs: fileIds,
                                                  eventTypes: [.musicBrainzMatchApplied, .musicBrainzMatchReverted], in: db)
            let files = try Self.fetchFiles(fileIDs: fileIds, in: db)
                .reduce(into: [Int64: FileRecord]()) { accumulator, file in
                    if let id = file.id { accumulator[id] = file }
                }
            return (history, files)
        }
        var historyByFile: [Int64: [EventRecord]] = [:]
        for event in history {
            if let fileId = event.fileId { historyByFile[fileId, default: []].append(event) }
        }
        let decoder = JSONDecoder()

        for event in matchEvents {
            guard let fileId = event.fileId, let eventId = event.eventId else { continue }
            let fileHistory = historyByFile[fileId] ?? []
            if event.eventType == .musicBrainzMatchApplied {
                var stack: [Int64] = []
                for historyEvent in fileHistory {
                    if historyEvent.eventType == .musicBrainzMatchApplied {
                        if let id = historyEvent.eventId { stack.append(id) }
                    } else if !stack.isEmpty {
                        stack.removeLast()
                    }
                }
                if stack.last != eventId {
                    throw OperationEngineError.undoSupersededByLaterMatch(fileId: fileId)
                }
                // Value comparison against the current row: a field the match
                // applied that no longer holds the applied value has been
                // changed since, so undoing would clobber that change.
                let applied = try Self.decodeEventPayload(ApplyMusicBrainzMatchPayload.self, event: event, decoder: decoder)
                if let file = currentFiles[fileId] {
                    let clobbersLaterEdit =
                        (applied.artist != nil && file.artist != applied.artist)
                        || (applied.title != nil && file.title != applied.title)
                        || (applied.album != nil && file.album != applied.album)
                    if clobbersLaterEdit {
                        throw OperationEngineError.undoSupersededByLaterMatch(fileId: fileId)
                    }
                }
            } else {
                // Redo (undoing a revert re-applies the match's values). It is
                // in order only if the revert is the file's LAST match event…
                if fileHistory.last?.eventId != eventId {
                    throw OperationEngineError.undoSupersededByLaterMatch(fileId: fileId)
                }
                // …and safe only if each field the match touched still holds
                // the value the revert RESTORED (its pre-apply value). If a
                // later edit changed it after the revert, redoing would write
                // the match value back over that edit — the same clobber the
                // apply branch guards, in the opposite direction.
                let revert = try Self.decodeEventPayload(RevertMusicBrainzMatchPayload.self, event: event, decoder: decoder)
                if let restored = revert.applied.previousMetadata,
                   let file = currentFiles[fileId] {
                    let applied = revert.applied
                    let clobbersLaterEdit =
                        (applied.artist != nil && file.artist != restored.artist)
                        || (applied.title != nil && file.title != restored.title)
                        || (applied.album != nil && file.album != restored.album)
                    if clobbersLaterEdit {
                        throw OperationEngineError.undoSupersededByLaterMatch(fileId: fileId)
                    }
                }
            }
        }
    }

    private static func decodeInverseMutation(event: EventRecord) throws -> TrackMutation {
        guard let inverseJsonData = event.inversePayloadJson.data(using: .utf8) else {
            throw OperationEngineError.payloadEncodingFailed
        }
        let decoder = JSONDecoder()
        switch event.eventType {
        case .fileRenamed:
            let payload = try decoder.decode(RenameFilePayload.self, from: inverseJsonData)
            return .renameFile(payload)
        case .metadataSet:
            let payload = try decoder.decode(SetMetadataPayload.self, from: inverseJsonData)
            return .setMetadata(SetMetadataPayload(
                fileId: payload.fileId, metadata: payload.metadata,
                previousMetadata: payload.previousMetadata, isSeratoAuthoritative: false
            ))
        case .trackImported:
            let payload = try decoder.decode(RemoveFilePayload.self, from: inverseJsonData)
            return .removeFile(payload)
        case .fileRemoved:
            let payload = try decoder.decode(IndexNewFilePayload.self, from: inverseJsonData)
            return .indexNewFile(payload)
        case .metadataCommittedToSerato:
            // Undoable when the original caller supplied
            // `previousMetadata` (the values Serato held before the
            // forward commit). Old / minimal callers that don't
            // capture previous state journal an inverse with
            // previousMetadata == nil and remain non-undoable.
            let payload = try decoder.decode(
                CommitMetadataToSeratoPayload.self, from: inverseJsonData
            )
            if payload.previousMetadata == nil {
                throw OperationEngineError.undoNotSupported(eventType: event.eventType)
            }
            return .commitMetadataToSerato(payload)
        case .trackAddedToSerato:
            // Reversing this requires a `removeTrackFromSerato` FFI
            // we don't have yet. Document as unsupported rather
            // than half-undo.
            throw OperationEngineError.undoNotSupported(eventType: event.eventType)
        case .fileLibraryStateChanged, .fileLocationObserved, .fileIdentityObserved, .fileImportRequested:
            // Observation inverses preserve audit evidence, not permission to
            // reverse an external Serato decision or re-add its membership.
            throw OperationEngineError.undoNotSupported(eventType: event.eventType)
        case .fileTrashed, .trackRemovedFromSerato, .fileRemovedFromCrates:
            // Resolution-flow events are deliberately not undoable.
            // Recovery: Finder Trash "Put Back" for the file +
            // manual re-add to Serato. Future work could add an
            // automated restore path if the user demands it.
            throw OperationEngineError.undoNotSupported(eventType: event.eventType)
        case .fileTagsWritten:
            // Undoable when previousMetadata was captured at forward
            // time. Same gate as commitMetadataToSerato.
            let payload = try decoder.decode(
                WriteFileTagsPayload.self, from: inverseJsonData
            )
            if payload.previousMetadata == nil {
                throw OperationEngineError.undoNotSupported(eventType: event.eventType)
            }
            return .writeFileTags(payload)
        case .musicBrainzMatchApplied:
            // Inverse restores prior state from the snapshots captured
            // at apply time (invariant #2). The forward apply always
            // captures them, so the match is unconditionally undoable.
            let payload = try decoder.decode(
                RevertMusicBrainzMatchPayload.self, from: inverseJsonData
            )
            return .revertMusicBrainzMatch(payload)
        case .musicBrainzMatchReverted:
            // Redo (undo of the undo): re-issue the original forward
            // match. The forward apply re-captures fresh snapshots.
            let payload = try decoder.decode(
                ApplyMusicBrainzMatchPayload.self, from: inverseJsonData
            )
            return .applyMusicBrainzMatch(payload)
        }
    }

    /// Apply every queued Serato write. Call this when Serato has
    /// just exited (the SeratoSyncCoordinator drives this). Drains
    /// the queue oldest-first and stops at the first failure, leaving
    /// the remaining entries queued for retry.
    @discardableResult
    public func drainPendingSeratoUpdates(retryingFailedCleanup: Bool = false) async throws -> ResyncOutcome {
        guard readiness?.permitsExternalWrites != false else { throw LibrarySyncReadinessError.synchronizationRequired }
        if !retryingFailedCleanup, let message = failedDuplicateCleanupMessage {
            throw OperationEngineError.externalSyncIncomplete(batchId: "duplicate-cleanup", underlying: message)
        }
        guard !isDraining else {
            return ResyncOutcome(appliedCount: 0, queuedCount: Set(pendingSeratoWrites.map(\.eventId)).count)
        }
        isDraining = true
        defer { isDraining = false }
        var applied = Set<Int64>()
        var superseded = pendingFieldConflicts
        pendingFieldConflicts.removeAll()
        while let queued = pendingSeratoWrites.first {
            let next = try await eligibleWrites([queued]).first ?? queued
            guard !(await seratoWatchdog.isSeratoRunning) else { break }
            if try await isEligible(next) {
                do {
                    try await requireExternalWriteEligibility([next])
                    try await applySeratoWrite(next.write, guardedWrites: [next])
                    applied.insert(next.eventId)
                } catch ExternalWriteInterruption.superseded {
                    superseded.insert(next.eventId)
                } catch ExternalWriteInterruption.deferred {
                    if try await isEligible(next) {
                        break
                    }
                    superseded.insert(next.eventId)
                } catch {
                    if let intent = pendingDuplicateCleanups.values.first(where: { $0.waitingEventID == next.eventId }) {
                        duplicateCleanupResults[intent.target.token.fileId] = .failed(Self.duplicateCleanupFailureMessage(intent, error: error))
                    }
                    throw error
                }
            } else {
                superseded.insert(next.eventId)
            }
            pendingSeratoWrites.removeFirst()
            queueDepthSubject.send(pendingSeratoWrites.count)
            try await finishQueuedDuplicateStep(eventID: next.eventId, succeeded: applied.contains(next.eventId))
        }
        let outcome = ResyncOutcome(appliedCount: applied.count,
                                    queuedCount: Set(pendingSeratoWrites.map(\.eventId)).count, supersededCount: superseded.count)
        await note(outcome.summaryMessage)
        return outcome
    }

    private func isEligible(_ write: GuardedSeratoWrite) async throws -> Bool {
        try await eligibleWrites([write]).count == 1
    }

    private func eligibleWrites(_ writes: [GuardedSeratoWrite]) async throws -> [GuardedSeratoWrite] {
        try await database.writer.read { database in
            try Self.eligibleWrites(writes, in: database)
        }
    }

    private static func eligibleWrites(_ writes: [GuardedSeratoWrite], in database: GRDB.Database) throws -> [GuardedSeratoWrite] {
        let files = try fetchFiles(fileIDs: writes.map { $0.token.fileId }, in: database)
            .reduce(into: [Int64: FileRecord]()) { files, file in
                if let fileID = file.id {
                    files[fileID] = file
                }
            }
        return writes.compactMap { write in
            guard let file = files[write.token.fileId], SeratoWriteEligibility.permits(write, file: file) else { return nil }
            return SeratoWriteEligibility.resolved(write, file: file)
        }
    }

    private func performExternalWrite<Result: Sendable>(
        _ writes: [GuardedSeratoWrite], operation: @escaping @Sendable (GRDB.Database) throws -> Result
    ) async throws -> Result {
        let watchdog = seratoWatchdog
        let readiness = readiness
        let drainAuthorization = LibrarySyncReadiness.drainAuthorization
        // Releasing writer serialization before I/O lets retirement commit against old authorization.
        return try await database.writer.write { database in
            guard try Self.eligibleWrites(writes, in: database).count == writes.count,
                  !watchdog.isRunningForExternalWrite,
                  readiness?.permitsExternalWrites(drain: drainAuthorization) != false
            else {
                throw ExternalWriteInterruption.deferred
            }
            var superseded = Set<Int64>()
            for write in writes {
                guard let file = try FileRecord.fetchOne(database, key: write.token.fileId) else {
                    superseded.insert(write.eventId)
                    continue
                }
                do { try SeratoWriteEligibility.requirePhysicalTarget(write, file: file, in: database) }
                catch is FileProcessingEligibilityError { superseded.insert(write.eventId) }
            }
            if !superseded.isEmpty {
                throw ExternalWriteInterruption.superseded(superseded)
            }
            guard !watchdog.isRunningForExternalWrite,
                  readiness?.permitsExternalWrites(drain: drainAuthorization) != false else { throw ExternalWriteInterruption.deferred }
            return try operation(database)
        }
    }

    private func requireExternalWriteEligibility(_ writes: [GuardedSeratoWrite]) async throws {
        let eligible = try await eligibleWrites(writes)
        guard eligible.count == writes.count, !(await seratoWatchdog.isSeratoRunning), readiness?.permitsExternalWrites != false else {
            throw ExternalWriteInterruption.deferred
        }
    }

    private func applyGuardedSeratoWrites(_ writes: [GuardedSeratoWrite]) async throws -> ResyncOutcome {
        var metadata: [GuardedSeratoWrite] = []
        var remaining: [GuardedSeratoWrite] = []
        for write in writes {
            if case .metadataUpdate = write.write {
                metadata.append(write)
            } else {
                remaining.append(write)
            }
        }
        var groups: [[GuardedSeratoWrite]] = metadata.isEmpty ? [] : [metadata]
        for write in remaining {
            if case .rename = write.write, let last = groups.last?.last, case .rename = last.write {
                groups[groups.count - 1].append(write)
            } else {
                groups.append([write])
            }
        }
        var applied = Set<Int64>()
        var superseded = Set<Int64>()
        for (index, group) in groups.enumerated() {
            guard !(await seratoWatchdog.isSeratoRunning) else {
                let remainder = groups[index...].flatMap { $0 }
                pendingSeratoWrites.append(contentsOf: remainder)
                queueDepthSubject.send(pendingSeratoWrites.count)
                return ResyncOutcome(appliedCount: applied.count,
                                     queuedCount: Set(remainder.map(\.eventId)).count, supersededCount: superseded.count)
            }
            var eligible = try await eligibleWrites(group)
            superseded.formUnion(Set(group.map(\.eventId)).subtracting(eligible.map(\.eventId)))
            while !eligible.isEmpty {
                do {
                    try await requireExternalWriteEligibility(eligible)
                    try await applyConsecutiveSeratoWrites(eligible.map(\.write), guardedWrites: eligible)
                } catch let ExternalWriteInterruption.superseded(rejectedEvents) {
                    superseded.formUnion(rejectedEvents)
                    let survivors = eligible.filter { !rejectedEvents.contains($0.eventId) }
                    eligible = try await eligibleWrites(survivors)
                    superseded.formUnion(Set(survivors.map(\.eventId)).subtracting(eligible.map(\.eventId)))
                    continue
                } catch ExternalWriteInterruption.deferred {
                    let interrupted = eligible + groups.dropFirst(index + 1).flatMap { $0 }
                    let remainder = try await eligibleWrites(interrupted)
                    superseded.formUnion(Set(interrupted.map(\.eventId)).subtracting(remainder.map(\.eventId)))
                    pendingSeratoWrites.append(contentsOf: remainder)
                    queueDepthSubject.send(pendingSeratoWrites.count)
                    return ResyncOutcome(appliedCount: applied.count,
                                         queuedCount: Set(remainder.map(\.eventId)).count, supersededCount: superseded.count)
                }
                applied.formUnion(eligible.map(\.eventId))
                break
            }
        }
        return ResyncOutcome(appliedCount: applied.count, queuedCount: 0, supersededCount: superseded.count)
    }

    private func applySeratoWrite(_ write: SeratoPendingWrite, guardedWrites: [GuardedSeratoWrite]) async throws {
        switch write {
        case let .rename(rename):
            try await applySeratoRename(rename, guardedWrites: guardedWrites)
        case let .metadataUpdate(update):
            try await applySeratoMetadataUpdate(update, guardedWrites: guardedWrites)
        case let .addTrack(add):
            try await applySeratoAddTrack(add, guardedWrites: guardedWrites)
            guard let guardedWrite = guardedWrites.first else {
                throw OperationEngineError.insertDidNotReturnRowId
            }
            let libraryID = try seratoLocator.supportedLibraryIdentity()
            try await database.writer.write { database in
                guard let file = try FileRecord.fetchOne(database, key: guardedWrite.token.fileId),
                      SeratoWriteEligibility.permits(guardedWrite, file: file)
                else {
                    throw FileProcessingEligibilityError.superseded(fileId: guardedWrite.token.fileId)
                }
                _ = try FileLibraryStateMutation.apply(
                    SetFileLibraryStatePayload(fileId: guardedWrite.token.fileId, expectedRevision: guardedWrite.token.revision,
                                               state: FileLibraryState(membership: .active, availability: file.fileAvailability, libraryID: libraryID, retiredAt: nil)),
                    batchId: "import-confirmed:\(guardedWrite.eventId)", timestamp: Int64(Date().timeIntervalSince1970 * 1000), in: database
                )
            }
        case let .fileTagWrite(write):
            try await applyFileTagWrite(write, guardedWrites: guardedWrites)
        case let .removeFromDatabase(removal):
            try await applySeratoDatabaseRemoval(removal, guardedWrites: guardedWrites)
        case let .removeFromCrates(removal):
            try await applySeratoCrateSweepRemoval(removal, guardedWrites: guardedWrites)
        case let .trashFile(trash):
            try await applyTrashFileOperation(trash, guardedWrites: guardedWrites)
        }
    }

    private func applyTrashFileOperation(_ trash: SeratoPendingTrash, guardedWrites: [GuardedSeratoWrite]) async throws {
        let trasher = fileTrasher
        try await performExternalWrite(guardedWrites) { database in
            do {
                try trasher(trash.absolutePath)
            } catch {
                throw OperationEngineError.trashFailed(path: trash.absolutePath, underlying: String(describing: error))
            }
            if let receipt = guardedWrites.first?.cleanupReceipt {
                try receipt.target.validate(in: database, audioWasTrashed: true)
                try receipt.keeper.validate(in: database)
                let removal = TrackMutation.removeFile(.init(fileId: receipt.target.token.fileId))
                try Self.requireCurrentToken(receipt.target.token, mutation: removal, in: database)
                _ = try Self.executeAndLog(mutation: removal, batchId: receipt.batchID, in: database)
                receipt.confirmRowRemoval()
            }
        }
    }

    private func applySeratoDatabaseRemoval(_ removal: SeratoPendingRemoval, guardedWrites: [GuardedSeratoWrite]) async throws {
        let databaseV2Path = seratoLocator.databaseV2Url.path
        guard FileManager.default.fileExists(atPath: databaseV2Path) else {
            // No database V2 yet — nothing to remove from. Same
            // tolerant behavior as applySeratoMetadataUpdate.
            return
        }
        let seratoRelativePath = SeratoLibraryLocator.seratoRelativePath(
            fromAbsolute: removal.absolutePath
        )
        do {
            _ = try await performExternalWrite(guardedWrites) { _ in
                let removed = try removeTrackFromDatabase(databasePath: databaseV2Path, trackPath: seratoRelativePath)
                if let receipt = guardedWrites.first?.cleanupReceipt {
                    guard try !readDatabaseRecordsStrict(databasePath: databaseV2Path).contains(where: { SeratoPath.normalized($0.path) == SeratoPath.normalized(removal.absolutePath) }) else {
                        throw OperationEngineError.seratoRewriteFailed(path: databaseV2Path, underlying: "Duplicate reference removal did not complete.")
                    }
                    receipt.confirmV2Removal()
                }
                return removed
            }
        } catch let error as ExternalWriteInterruption {
            throw error
        } catch {
            throw OperationEngineError.seratoRewriteFailed(
                path: databaseV2Path,
                underlying: String(describing: error)
            )
        }
    }

    private func applySeratoCrateSweepRemoval(_ removal: SeratoPendingRemoval, guardedWrites: [GuardedSeratoWrite]) async throws {
        let seratoRelativePath = SeratoLibraryLocator.seratoRelativePath(
            fromAbsolute: removal.absolutePath
        )
        let displayFilename = (removal.absolutePath as NSString).lastPathComponent
        let crateFiles: [URL]
        do {
            crateFiles = try seratoLocator.enumerateCrateFiles()
        } catch {
            await note("Failed to enumerate Subcrates directory while removing \(displayFilename): \(error.localizedDescription)")
            throw OperationEngineError.seratoEnumerationFailed(
                directory: seratoLocator.subcratesDirectoryUrl.path,
                underlying: String(describing: error)
            )
        }
        // Per-crate fault tolerance: one bad crate file can't
        // block removing the file's reference from every other
        // crate. Symmetric with `applySeratoRename`.
        var perCrateFailures: [(URL, Error)] = []
        for crateFile in crateFiles {
            try await requireExternalWriteEligibility(guardedWrites)
            do {
                _ = try await performExternalWrite(guardedWrites) { _ in try removePathFromCrate(
                    cratePath: crateFile.path,
                    trackPath: seratoRelativePath
                ) }
            } catch let error as ExternalWriteInterruption {
                throw error
            } catch {
                perCrateFailures.append((crateFile, error))
                let crateName = crateFile.lastPathComponent
                await note("Skipped crate \(crateName) while removing \(displayFilename): \(error.localizedDescription)")
            }
        }
        // Cleanup cannot advance to Trash until every reference store completes.
        if !perCrateFailures.isEmpty {
            let firstFailure = perCrateFailures[0]
            throw OperationEngineError.seratoRewriteFailed(
                path: firstFailure.0.path,
                underlying: String(describing: firstFailure.1)
            )
        }
    }

    private func applyFileTagWrite(_ write: SeratoPendingFileTagWrite, guardedWrites: [GuardedSeratoWrite]) async throws {
        let update = AudioTagUpdate(
            artist: write.metadata.artist,
            title: write.metadata.title,
            album: write.metadata.album,
            genre: write.metadata.genre,
            bpm: write.metadata.bpm,
            musicalKey: write.metadata.musicalKey,
            comment: write.metadata.comment,
            label: write.metadata.label,
            // Year lives on the pending write, not on SeratoMetadata:
            // Serato's database V2 has no year field, so the MusicBrainz
            // match routes year to the file tags only. `writeFileTags`
            // leaves it nil.
            year: write.year.flatMap { $0 >= 0 ? UInt32($0) : nil },
            clearYear: write.clearYear
        )
        let tagWriter = fileTagWriter
        do {
            try await performExternalWrite(guardedWrites) { database in
                guard let guardedWrite = guardedWrites.first,
                      let file = try FileRecord.fetchOne(database, key: guardedWrite.token.fileId)
                else {
                    throw OperationEngineError.insertDidNotReturnRowId
                }
                try tagWriter(write.absolutePath, update)
                let identity = try FileMetadataCollector.collectVerified(at: write.absolutePath)
                try FileIdentityObservationMutation.recordOwnedTagWrite(previous: file, identity: identity, eventID: guardedWrite.eventId, in: database)
            }
        } catch let error as ExternalWriteInterruption {
            throw error
        } catch {
            throw OperationEngineError.fileTagWriteFailed(
                path: write.absolutePath,
                underlying: String(describing: error)
            )
        }
    }

    private func applySeratoAddTrack(_ add: SeratoPendingAddTrack, guardedWrites: [GuardedSeratoWrite]) async throws {
        let databaseV2Path = seratoLocator.databaseV2Url.path
        let seratoRelativePath = SeratoLibraryLocator.seratoRelativePath(
            fromAbsolute: add.absolutePath
        )

        let seratoDirectory = seratoLocator.seratoDirectory
        let bootstrapBytes = freshDatabaseV2Bytes(withTrackPath: seratoRelativePath, metadata: add.metadata)
        do {
            try await performExternalWrite(guardedWrites) { _ in
                if !FileManager.default.fileExists(atPath: databaseV2Path) {
                    try FileManager.default.createDirectory(at: seratoDirectory, withIntermediateDirectories: true)
                    try bootstrapBytes.write(to: URL(fileURLWithPath: databaseV2Path))
                    return
                }
                _ = try addTrackToDatabase(
                    databasePath: databaseV2Path,
                    trackPath: seratoRelativePath,
                    metadata: SeratoMetadataUpdate(
                        artist: add.metadata.artist,
                        title: add.metadata.title,
                        album: add.metadata.album,
                        genre: add.metadata.genre,
                        bpm: add.metadata.bpm,
                        key: add.metadata.musicalKey,
                        comment: add.metadata.comment,
                        length: add.metadata.length,
                        label: add.metadata.label
                    )
                )
            }
        } catch let error as ExternalWriteInterruption {
            throw error
        } catch {
            throw OperationEngineError.seratoRewriteFailed(
                path: databaseV2Path,
                underlying: String(describing: error)
            )
        }
    }

    /// Build the byte layout of a brand-new `database V2` containing
    /// exactly one otrk for the supplied path + metadata. Used when
    /// a user drops a file but Serato has never run on this machine
    /// (the database V2 file doesn't exist yet).
    private func freshDatabaseV2Bytes(
        withTrackPath seratoRelativePath: String,
        metadata: SeratoMetadata
    ) -> Data {
        var bytes = Data()

        // vrsn header: 4-byte tag + 4-byte BE length + UTF-16BE payload
        let versionString = "2.0/Serato Scratch LIVE Database"
        let versionPayload = utf16BeBytes(of: versionString)
        bytes.append(contentsOf: "vrsn".utf8)
        bytes.append(contentsOf: uint32BeBytes(of: UInt32(versionPayload.count)))
        bytes.append(versionPayload)

        // otrk container with pfil + any t* metadata fields
        var otrkPayload = Data()
        appendTlv(tag: "pfil", payload: utf16BeBytes(of: seratoRelativePath), to: &otrkPayload)
        if let value = metadata.artist {
            appendTlv(tag: "tart", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.title {
            appendTlv(tag: "tsng", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.album {
            appendTlv(tag: "talb", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.genre {
            appendTlv(tag: "tgen", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.bpm {
            appendTlv(tag: "tbpm", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.musicalKey {
            appendTlv(tag: "tkey", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.comment {
            appendTlv(tag: "tcom", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.length {
            appendTlv(tag: "tlen", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.label {
            appendTlv(tag: "tlbl", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }

        bytes.append(contentsOf: "otrk".utf8)
        bytes.append(contentsOf: uint32BeBytes(of: UInt32(otrkPayload.count)))
        bytes.append(otrkPayload)
        return bytes
    }

    private func appendTlv(tag: String, payload: Data, to data: inout Data) {
        precondition(tag.utf8.count == 4)
        data.append(contentsOf: tag.utf8)
        data.append(contentsOf: uint32BeBytes(of: UInt32(payload.count)))
        data.append(payload)
    }

    private func utf16BeBytes(of string: String) -> Data {
        var data = Data()
        for codeUnit in string.utf16 {
            data.append(UInt8(codeUnit >> 8))
            data.append(UInt8(codeUnit & 0xFF))
        }
        return data
    }

    private func uint32BeBytes(of value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private func applySeratoRename(_ rename: SeratoPendingRename, guardedWrites: [GuardedSeratoWrite]) async throws {
        let oldSeratoPath = SeratoLibraryLocator.seratoRelativePath(
            fromAbsolute: rename.oldAbsolutePath
        )
        let newSeratoPath = SeratoLibraryLocator.seratoRelativePath(
            fromAbsolute: rename.newAbsolutePath
        )
        let displayFilename = (rename.newAbsolutePath as NSString).lastPathComponent

        // Database V2 first, then crates. Database V2 is the source
        // of truth for Serato's "All" view — the thing the user
        // actually sees and drags from. If a single corrupted
        // .crate file throws (rare but real on user libraries
        // that have accumulated cruft), we still need V2 updated;
        // otherwise tracks move on disk and Serato keeps the old
        // path forever (the bug PR fixed).
        var databaseV2Rewrites: UInt32 = 0
        var databaseV2Error: Error?
        let databaseV2Path = seratoLocator.databaseV2Url.path
        if FileManager.default.fileExists(atPath: databaseV2Path) {
            do {
                databaseV2Rewrites = try await performExternalWrite(guardedWrites) { _ in try rewriteDatabasePath(
                    databasePath: databaseV2Path,
                    oldPath: oldSeratoPath,
                    newPath: newSeratoPath
                ) }
                if databaseV2Rewrites == 0 {
                    // Old path wasn't in database V2. Surprising —
                    // surface so the user can see something is off
                    // (e.g., Unicode normalization mismatch, prior
                    // failed sync, or the track was never in
                    // Serato to begin with).
                    await note("⚠️ database V2 had no entry for \(oldSeratoPath) — \(displayFilename) won't appear in Serato until re-imported.")
                }
            } catch let error as ExternalWriteInterruption {
                throw error
            } catch {
                databaseV2Error = error
                await note("Failed to update database V2 for \(displayFilename): \(error.localizedDescription)")
            }
        }

        let crateFiles: [URL]
        do {
            crateFiles = try seratoLocator.enumerateCrateFiles()
        } catch {
            // Enumeration failure is symmetric with the V2 failure
            // — both surface, neither stops the other.
            await note("Failed to enumerate Subcrates directory: \(error.localizedDescription)")
            if databaseV2Error != nil {
                throw OperationEngineError.seratoEnumerationFailed(
                    directory: seratoLocator.subcratesDirectoryUrl.path,
                    underlying: String(describing: error)
                )
            }
            return
        }

        var perCrateFailures: [(URL, Error)] = []
        for crateFile in crateFiles {
            try await requireExternalWriteEligibility(guardedWrites)
            do {
                _ = try await performExternalWrite(guardedWrites) { _ in try rewriteCratePath(
                    cratePath: crateFile.path,
                    oldPath: oldSeratoPath,
                    newPath: newSeratoPath
                ) }
            } catch let error as ExternalWriteInterruption {
                throw error
            } catch {
                // Per-crate fault tolerance: log and continue. A
                // single bad crate file can't poison the entire
                // sync for the rest of the user's library.
                perCrateFailures.append((crateFile, error))
                let crateName = crateFile.lastPathComponent
                await note("Skipped crate \(crateName) while renaming \(displayFilename): \(error.localizedDescription)")
            }
        }

        // Throw only if both V2 and every crate failed — at that
        // point we genuinely couldn't sync anything and the caller
        // (e.g., the organizer) needs to know the file move on
        // disk has no matching library update.
        let everyCrateFailed = !crateFiles.isEmpty
            && perCrateFailures.count == crateFiles.count
        if databaseV2Error != nil, everyCrateFailed || crateFiles.isEmpty {
            throw OperationEngineError.seratoRewriteFailed(
                path: databaseV2Path,
                underlying: String(describing: databaseV2Error!)
            )
        }
    }

    /// Bulk variant of `applySeratoRename`. One Rust FFI call to
    /// rewrite the `database V2` file for every rename in the batch,
    /// then one FFI call per crate file. Same failure semantics as
    /// the single-rename path — V2 errors are recorded but don't
    /// stop the crate sweep; a final throw only fires if V2 failed
    /// AND every crate failed (or there were no crates).
    ///
    /// Falls back to the per-rename path for batches of size 1 to
    /// preserve the more granular "⚠️ no entry for X" diagnostic
    /// (the batch FFI returns a single aggregate count and can't
    /// distinguish "0 renames applied" from "all renames missed").
    private func applySeratoRenameBatch(_ renames: [SeratoPendingRename], guardedWrites: [GuardedSeratoWrite]) async throws {
        guard renames.count > 1 else {
            if let single = renames.first {
                try await applySeratoRename(single, guardedWrites: guardedWrites)
            }
            return
        }

        let pairs = renames.map { rename in
            SeratoPathRename(
                oldPath: SeratoLibraryLocator.seratoRelativePath(
                    fromAbsolute: rename.oldAbsolutePath
                ),
                newPath: SeratoLibraryLocator.seratoRelativePath(
                    fromAbsolute: rename.newAbsolutePath
                )
            )
        }

        var databaseV2Error: Error?
        let databaseV2Path = seratoLocator.databaseV2Url.path
        if FileManager.default.fileExists(atPath: databaseV2Path) {
            do {
                _ = try await performExternalWrite(guardedWrites) { _ in try batchRewriteDatabasePaths(
                    databasePath: databaseV2Path,
                    renames: pairs
                ) }
            } catch let error as ExternalWriteInterruption {
                throw error
            } catch {
                databaseV2Error = error
                await note("Failed to update database V2 for \(renames.count) renames: \(error.localizedDescription)")
            }
        }

        let crateFiles: [URL]
        do {
            crateFiles = try seratoLocator.enumerateCrateFiles()
        } catch {
            await note("Failed to enumerate Subcrates directory: \(error.localizedDescription)")
            if databaseV2Error != nil {
                throw OperationEngineError.seratoEnumerationFailed(
                    directory: seratoLocator.subcratesDirectoryUrl.path,
                    underlying: String(describing: error)
                )
            }
            return
        }

        var perCrateFailures: [(URL, Error)] = []
        for crateFile in crateFiles {
            try await requireExternalWriteEligibility(guardedWrites)
            do {
                _ = try await performExternalWrite(guardedWrites) { _ in try batchRewriteCratePaths(
                    cratePath: crateFile.path,
                    renames: pairs
                ) }
            } catch let error as ExternalWriteInterruption {
                throw error
            } catch {
                perCrateFailures.append((crateFile, error))
                await note("Skipped crate \(crateFile.lastPathComponent) during batch rename: \(error.localizedDescription)")
            }
        }

        let everyCrateFailed = !crateFiles.isEmpty
            && perCrateFailures.count == crateFiles.count
        if databaseV2Error != nil, everyCrateFailed || crateFiles.isEmpty {
            throw OperationEngineError.seratoRewriteFailed(
                path: databaseV2Path,
                underlying: String(describing: databaseV2Error!)
            )
        }
    }

    /// Apply a batch's Serato writes with the two full-`database V2`
    /// rewrite kinds coalesced into one read+write pass each:
    ///
    /// - Renames: consecutive `.rename` runs → one `applySeratoRenameBatch`.
    /// - Metadata updates: EVERY `.metadataUpdate` in the batch → one
    ///   `applySeratoMetadataUpdateBatch`. A MusicBrainz match emits a
    ///   `.metadataUpdate` + `.fileTagWrite` pair per row, so the
    ///   metadata updates arrive interleaved with tag writes, not
    ///   consecutively — hence they're hoisted out by kind rather than
    ///   coalesced by adjacency. Metadata touches only `t*` fields keyed
    ///   by path, independent of renames (`pfil`) and per-file tag
    ///   writes, so applying them first is order-safe (issue C2b).
    ///
    /// Without this, a 200-row Auto-Tag apply would trigger 200 serial
    /// full-library `database V2` rewrites.
    private func applyConsecutiveSeratoWrites(
        _ writes: [SeratoPendingWrite], guardedWrites: [GuardedSeratoWrite]
    ) async throws {
        var metadataUpdates: [SeratoPendingMetadataUpdate] = []
        var remaining: [SeratoPendingWrite] = []
        for write in writes {
            if case let .metadataUpdate(update) = write {
                metadataUpdates.append(update)
            } else {
                remaining.append(write)
            }
        }

        if !metadataUpdates.isEmpty {
            try await applySeratoMetadataUpdateBatch(metadataUpdates, guardedWrites: guardedWrites)
        }

        var index = 0
        while index < remaining.count {
            if case .rename = remaining[index] {
                var renames: [SeratoPendingRename] = []
                while index < remaining.count, case let .rename(rename) = remaining[index] {
                    renames.append(rename)
                    index += 1
                }
                try await applySeratoRenameBatch(renames, guardedWrites: guardedWrites)
            } else {
                try await applySeratoWrite(remaining[index], guardedWrites: guardedWrites)
                index += 1
            }
        }
    }

    /// Single-update entry point — used by the queued-write drain path
    /// (`drainPendingSeratoUpdates` → `applySeratoWrite`), which
    /// processes one queued write at a time. Delegates to the batch
    /// writer so every `database V2` metadata write goes through one
    /// seam.
    private func applySeratoMetadataUpdate(_ update: SeratoPendingMetadataUpdate, guardedWrites: [GuardedSeratoWrite]) async throws {
        try await applySeratoMetadataUpdateBatch([update], guardedWrites: guardedWrites)
    }

    /// Write every metadata update in one `database V2` read+rewrite
    /// pass via the injected `seratoMetadataBatchWriter`. Tolerant of a
    /// missing `database V2` (Serato never ran here) the same way the
    /// single-update path always was — nothing for Serato to "see" yet.
    private func applySeratoMetadataUpdateBatch(
        _ updates: [SeratoPendingMetadataUpdate], guardedWrites: [GuardedSeratoWrite]
    ) async throws {
        guard !updates.isEmpty else { return }
        let databaseV2Path = seratoLocator.databaseV2Url.path
        guard FileManager.default.fileExists(atPath: databaseV2Path) else { return }

        let trackUpdates = updates.map { update in
            SeratoTrackMetadataUpdate(
                trackPath: SeratoLibraryLocator.seratoRelativePath(
                    fromAbsolute: update.absolutePath
                ),
                update: SeratoMetadataUpdate(
                    artist: update.metadata.artist,
                    title: update.metadata.title,
                    album: update.metadata.album,
                    genre: update.metadata.genre,
                    bpm: update.metadata.bpm,
                    key: update.metadata.musicalKey,
                    comment: update.metadata.comment,
                    length: update.metadata.length,
                    label: update.metadata.label
                )
            )
        }

        let metadataWriter = seratoMetadataBatchWriter
        do {
            _ = try await performExternalWrite(guardedWrites) { _ in try metadataWriter(databaseV2Path, trackUpdates) }
            for guarded in guardedWrites {
                guard case let .metadataUpdate(update) = guarded.write,
                      let previous = observedSeratoMetadata[guarded.token] else { continue }
                observedSeratoMetadata[guarded.token] = Self.overlayMetadata(update.metadata, on: previous)
            }
        } catch let error as ExternalWriteInterruption {
            throw error
        } catch {
            throw OperationEngineError.seratoRewriteFailed(
                path: databaseV2Path,
                underlying: String(describing: error)
            )
        }
    }

    // MARK: - Synchronous SQL apply

    private struct ExecutionResult: Sendable {
        let eventId: Int64?
        /// Serato-gated writes this mutation produced, applied in order.
        /// Most mutations emit zero or one; `applyMusicBrainzMatch`
        /// emits two (a database-V2 metadata update and a file-tag
        /// write).
        let seratoWrites: [SeratoPendingWrite]
    }

    private static func executeAndLog(
        mutation: TrackMutation,
        batchId: String,
        in database: GRDB.Database,
        physicalMoves: PhysicalFileMoveTransaction? = nil
    ) throws -> GuardedExecutionResult {
        if let fileID = mutation.processingFileID {
            guard let file = try FileRecord.fetchOne(database, key: fileID) else {
                throw OperationEngineError.fileNotFound(fileId: fileID)
            }
            if case .addTrackToSerato = mutation {
                guard file.libraryMembership == .pendingImport, file.fileAvailability == .available else {
                    throw FileProcessingEligibilityError.superseded(fileId: fileID)
                }
            } else {
                try FileProcessingEligibility.requireProcessable(file)
            }
        }
        var effectiveMutation = mutation
        if case let .renameFile(payload) = mutation, payload.physicalMove == true {
            guard let physicalMoves, let file = try FileRecord.fetchOne(database, key: payload.fileId) else {
                throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
            }
            let moved = try physicalMoves.move(payload, file: file)
            effectiveMutation = .renameFile(RenameFilePayload(fileId: payload.fileId, newPath: payload.newPath,
                                                              previousPath: payload.previousPath, newVolumeUuid: moved.volumeUuid, newInode: moved.inode, physicalMove: true))
        }
        let result = try executeMutation(mutation: effectiveMutation, batchId: batchId, in: database)
        guard !result.seratoWrites.isEmpty else {
            return GuardedExecutionResult(eventId: result.eventId, seratoWrites: [])
        }
        guard let eventID = result.eventId,
              let event = try EventRecord.fetchOne(database, key: eventID),
              let fileID = event.fileId,
              let file = try FileRecord.fetchOne(database, key: fileID)
        else {
            throw OperationEngineError.insertDidNotReturnRowId
        }
        let token = FileMembershipToken(fileId: fileID, revision: file.membershipRevision)
        return GuardedExecutionResult(eventId: result.eventId, seratoWrites: result.seratoWrites.map {
            GuardedSeratoWrite(token: token, write: $0, eventId: eventID, originalIdentity: file.identity)
        })
    }

    private struct GuardedExecutionResult: Sendable {
        let eventId: Int64?
        let seratoWrites: [GuardedSeratoWrite]
    }

    private static func executeMutation(
        mutation: TrackMutation,
        batchId: String,
        in db: GRDB.Database
    ) throws -> ExecutionResult {
        let timestampMillis = Int64(Date().timeIntervalSince1970 * 1000)
        switch mutation {
        case .indexNewFile(let payload):
            let eventId = try applyIndexNewFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case .renameFile(let payload):
            let (eventId, seratoRename) = try applyRenameFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.rename(seratoRename)]
            )
        case .removeFile(let payload):
            let eventId = try applyRemoveFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case let .observeFileLocation(payload):
            let eventId = try FileLocationObservationMutation.apply(payload, batchId: batchId, timestamp: timestampMillis, in: db)
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case let .observeFileIdentity(payload):
            let eventId = try FileIdentityObservationMutation.apply(payload, batchId: batchId, timestamp: timestampMillis, in: db)
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case let .setFileLibraryState(payload):
            let eventId = try FileLibraryStateMutation.apply(payload, batchId: batchId, timestamp: timestampMillis, in: db)
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case let .beginFileImport(payload):
            let eventId = try FileLibraryStateMutation.beginImport(payload, batchId: batchId, timestamp: timestampMillis, in: db)
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case .setMetadata(let payload):
            let eventId = try applySetMetadata(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case .commitMetadataToSerato(let payload):
            let (eventId, seratoUpdate) = try applyCommitMetadataToSerato(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.metadataUpdate(seratoUpdate)]
            )
        case .addTrackToSerato(let payload):
            let (eventId, seratoAdd) = try applyAddTrackToSerato(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.addTrack(seratoAdd)]
            )
        case .writeFileTags(let payload):
            let (eventId, fileTagWrite) = try applyWriteFileTags(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.fileTagWrite(fileTagWrite)]
            )
        case .trashFile(let payload):
            let (eventId, trash) = try applyTrashFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: [.trashFile(trash)])
        case .removeTrackFromSerato(let payload):
            let (eventId, removal) = try applyRemoveTrackFromSerato(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.removeFromDatabase(removal)]
            )
        case .removeFileFromCrates(let payload):
            let (eventId, removal) = try applyRemoveFileFromCrates(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.removeFromCrates(removal)]
            )
        case .applyMusicBrainzMatch(let payload):
            let (eventId, seratoWrites) = try applyMusicBrainzMatch(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: seratoWrites)
        case .revertMusicBrainzMatch(let payload):
            let (eventId, seratoWrites) = try applyRevertMusicBrainzMatch(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: seratoWrites)
        }
    }

    private static func applyRemoveFile(
        _ payload: RemoveFilePayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> Int64 {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }

        // The inverse of a removal is a full reinsertion. Capture
        // every field the indexer needs so undo can rebuild the row
        // byte-for-byte (modulo the new auto-incremented id, which
        // isn't user-visible).
        let inversePayload = IndexNewFilePayload(
            path: fileRecord.path,
            volumeUuid: fileRecord.volumeUuid,
            inode: fileRecord.inode,
            fileSize: fileRecord.fileSize,
            mtime: fileRecord.mtime,
            lightweightHash: fileRecord.lightweightHash,
            bitrateKbps: fileRecord.bitrateKbps,
            metadata: SeratoMetadata(
                artist: fileRecord.artist,
                title: fileRecord.title,
                album: fileRecord.album,
                genre: fileRecord.genre,
                bpm: fileRecord.bpm,
                musicalKey: fileRecord.musicalKey,
                comment: fileRecord.comment,
                length: fileRecord.length,
                label: fileRecord.label
            )
        )

        // Insert the event BEFORE deleting the file: at delete time,
        // the schema's ON DELETE SET NULL cascade rewrites every
        // file_id referencing this row (including the event we just
        // inserted) to NULL. Per-file-history queries can't find the
        // event afterward, but the batch_id grouping is preserved
        // and the inverse payload carries everything undo needs.
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileRemoved,
            forwardPayload: payload,
            inversePayload: inversePayload,
            in: db
        )

        try fileRecord.delete(db)

        return eventId
    }

    private static func applyIndexNewFile(
        _ payload: IndexNewFilePayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> Int64 {
        var fileRecord = FileRecord(
            path: payload.path,
            volumeUuid: payload.volumeUuid,
            inode: payload.inode,
            fileSize: payload.fileSize,
            mtime: payload.mtime,
            lightweightHash: payload.lightweightHash,
            fingerprintStatus: .pending,
            bitrateKbps: payload.bitrateKbps,
            artist: payload.metadata.artist,
            title: payload.metadata.title,
            album: payload.metadata.album,
            genre: payload.metadata.genre,
            bpm: payload.metadata.bpm,
            musicalKey: payload.metadata.musicalKey,
            comment: payload.metadata.comment,
            length: payload.metadata.length,
            label: payload.metadata.label
        )
        try fileRecord.insert(db)
        guard let fileId = fileRecord.id else {
            throw OperationEngineError.insertDidNotReturnRowId
        }

        return try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: fileId,
            eventType: .trackImported,
            forwardPayload: payload,
            inversePayload: RemoveFilePayload(fileId: fileId),
            in: db
        )
    }

    private static func applySetMetadata(
        _ payload: SetMetadataPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> Int64 {
        guard var fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }

        let originalMetadata = SeratoMetadata(
            artist: fileRecord.artist,
            title: fileRecord.title,
            album: fileRecord.album,
            genre: fileRecord.genre,
            bpm: fileRecord.bpm,
            musicalKey: fileRecord.musicalKey,
            comment: fileRecord.comment,
            length: fileRecord.length,
            label: fileRecord.label
        )

        fileRecord.artist = payload.metadata.artist
        fileRecord.title = payload.metadata.title
        fileRecord.album = payload.metadata.album
        fileRecord.genre = payload.metadata.genre
        fileRecord.bpm = payload.metadata.bpm
        fileRecord.musicalKey = payload.metadata.musicalKey
        fileRecord.comment = payload.metadata.comment
        fileRecord.length = payload.metadata.length
        fileRecord.label = payload.metadata.label
        try fileRecord.update(db)

        let forwardPayload = SetMetadataPayload(
            fileId: payload.fileId,
            metadata: payload.metadata,
            previousMetadata: originalMetadata,
            isSeratoAuthoritative: payload.isSeratoAuthoritative
        )
        let inversePayload = SetMetadataPayload(
            fileId: payload.fileId,
            metadata: originalMetadata,
            previousMetadata: payload.metadata,
            isSeratoAuthoritative: false
        )

        return try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .metadataSet,
            forwardPayload: forwardPayload,
            inversePayload: inversePayload,
            in: db
        )
    }

    private static func applyRenameFile(
        _ payload: RenameFilePayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingRename) {
        guard var fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        let originalPath = fileRecord.path
        let originalVolumeUuid = fileRecord.volumeUuid
        let originalInode = fileRecord.inode

        fileRecord.path = payload.newPath
        if let newVolumeUuid = payload.newVolumeUuid {
            fileRecord.volumeUuid = newVolumeUuid
        }
        if let newInode = payload.newInode {
            fileRecord.inode = newInode
        }
        try fileRecord.update(db)

        let forwardPayload = RenameFilePayload(
            fileId: payload.fileId,
            newPath: payload.newPath,
            previousPath: originalPath,
            newVolumeUuid: payload.newVolumeUuid,
            newInode: payload.newInode,
            previousVolumeUuid: payload.newVolumeUuid == nil ? nil : originalVolumeUuid,
            previousInode: payload.newInode == nil ? nil : originalInode,
            physicalMove: payload.physicalMove
        )
        let inversePayload = RenameFilePayload(
            fileId: payload.fileId,
            newPath: originalPath,
            previousPath: payload.newPath,
            newVolumeUuid: payload.newVolumeUuid == nil ? nil : originalVolumeUuid,
            newInode: payload.newInode == nil ? nil : originalInode,
            previousVolumeUuid: payload.newVolumeUuid,
            previousInode: payload.newInode,
            physicalMove: payload.physicalMove
        )

        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileRenamed,
            forwardPayload: forwardPayload,
            inversePayload: inversePayload,
            in: db
        )
        let seratoRename = SeratoPendingRename(
            oldAbsolutePath: originalPath,
            newAbsolutePath: payload.newPath
        )
        return (eventId, seratoRename)
    }

    private static func applyAddTrackToSerato(
        _ payload: AddTrackToSeratoPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingAddTrack) {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }

        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .trackAddedToSerato,
            forwardPayload: payload,
            inversePayload: payload,
            in: db
        )

        let pending = SeratoPendingAddTrack(
            absolutePath: fileRecord.path,
            metadata: payload.metadata
        )
        return (eventId, pending)
    }

    private static func applyCommitMetadataToSerato(
        _ payload: CommitMetadataToSeratoPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingMetadataUpdate) {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }

        // Inverse is the "re-issue this commit with previous and
        // current swapped" mutation. Only meaningful when the caller
        // supplied `previousMetadata`; otherwise the inverse mirrors
        // the forward and the event is rejected by undoBatch
        // (decodeInverseMutation gates on inverse.previousMetadata
        // being non-nil).
        let inversePayload = CommitMetadataToSeratoPayload(
            fileId: payload.fileId,
            metadata: payload.previousMetadata ?? payload.metadata,
            previousMetadata: payload.previousMetadata == nil ? nil : payload.metadata
        )
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .metadataCommittedToSerato,
            forwardPayload: payload,
            inversePayload: inversePayload,
            in: db
        )

        let pending = SeratoPendingMetadataUpdate(
            absolutePath: fileRecord.path,
            metadata: payload.metadata
        )
        return (eventId, pending)
    }

    private static func applyWriteFileTags(
        _ payload: WriteFileTagsPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingFileTagWrite) {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }

        // Mirror commitMetadataToSerato's inverse pattern: when the
        // caller supplied `previousMetadata`, the inverse swaps
        // metadata ↔ previousMetadata. Without it, the inverse
        // mirrors the forward and the event is rejected by
        // decodeInverseMutation (callers without prior state forfeit
        // undo for this event).
        let inversePayload = WriteFileTagsPayload(
            fileId: payload.fileId,
            metadata: payload.previousMetadata ?? payload.metadata,
            previousMetadata: payload.previousMetadata == nil ? nil : payload.metadata
        )
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileTagsWritten,
            forwardPayload: payload,
            inversePayload: inversePayload,
            in: db
        )

        let pending = SeratoPendingFileTagWrite(
            absolutePath: fileRecord.path,
            metadata: payload.metadata
        )
        return (eventId, pending)
    }

    /// Sentinel stored in `inverse_payload_json` for events that
    /// are structurally non-undoable (trash, remove-from-Serato,
    /// remove-from-crates). Previously these events stored the
    /// forward payload twice — auditors couldn't distinguish "no
    /// inverse" from "inverse identical to forward," and a future
    /// engineer wiring up undo would decode garbage. The sentinel
    /// makes the events table self-describing: `inverse_payload_json`
    /// reading `{"reason":"non-undoable",…}` is the unambiguous
    /// signal that `decodeInverseMutation` will throw
    /// `undoNotSupported` for this row.
    private struct NonUndoableInverse: Codable {
        let reason: String
        let eventType: String
        let recoveryNote: String
    }

    private static func applyTrashFile(
        _ payload: TrashFilePayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingTrash) {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }

        // Capture path in the journal payload so even if the file
        // row gets deleted later in the same batch (ON DELETE SET
        // NULL cascade nulls the event's file_id), History still
        // records exactly what was trashed.
        struct ForwardPayload: Codable {
            let fileId: Int64
            let path: String
        }
        let forwardPayload = ForwardPayload(
            fileId: payload.fileId,
            path: fileRecord.path
        )
        let inverse = NonUndoableInverse(
            reason: "non-undoable",
            eventType: EventType.fileTrashed.rawValue,
            recoveryNote: "Restore from Finder Trash before it is emptied."
        )
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileTrashed,
            forwardPayload: forwardPayload,
            inversePayload: inverse,
            in: db
        )
        return (eventId, SeratoPendingTrash(absolutePath: fileRecord.path))
    }

    private static func applyRemoveTrackFromSerato(
        _ payload: RemoveTrackFromSeratoPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingRemoval) {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        struct ForwardPayload: Codable {
            let fileId: Int64
            let path: String
        }
        let forwardPayload = ForwardPayload(
            fileId: payload.fileId,
            path: fileRecord.path
        )
        let inverse = NonUndoableInverse(
            reason: "non-undoable",
            eventType: EventType.trackRemovedFromSerato.rawValue,
            recoveryNote: "Re-add the track to Serato's library via drag-drop or rescan."
        )
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .trackRemovedFromSerato,
            forwardPayload: forwardPayload,
            inversePayload: inverse,
            in: db
        )
        let pending = SeratoPendingRemoval(absolutePath: fileRecord.path)
        return (eventId, pending)
    }

    private static func applyRemoveFileFromCrates(
        _ payload: RemoveFileFromCratesPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingRemoval) {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        struct ForwardPayload: Codable {
            let fileId: Int64
            let path: String
        }
        let forwardPayload = ForwardPayload(
            fileId: payload.fileId,
            path: fileRecord.path
        )
        let inverse = NonUndoableInverse(
            reason: "non-undoable",
            eventType: EventType.fileRemovedFromCrates.rawValue,
            recoveryNote: "Re-add the path to each affected crate manually in Serato."
        )
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileRemovedFromCrates,
            forwardPayload: forwardPayload,
            inversePayload: inverse,
            in: db
        )
        let pending = SeratoPendingRemoval(absolutePath: fileRecord.path)
        return (eventId, pending)
    }

    /// The paired Serato-side writes a MusicBrainz match (or its
    /// revert) produces: a `database V2` metadata update and an audio
    /// file-tag write. Year rides only on the file-tag write —
    /// `SeratoMetadata`, and thus `database V2`, has no year field. This
    /// is the shared mechanic both the forward apply and the inverse
    /// revert call with different values (applied vs. restored).
    private static func musicBrainzSeratoWrites(
        absolutePath: String,
        artist: String?,
        title: String?,
        album: String?,
        year: Int?,
        clearFileYear: Bool = false
    ) -> [SeratoPendingWrite] {
        let metadata = SeratoMetadata(artist: artist, title: title, album: album)
        // An identity-only confirmation (the user kept every display field:
        // artist/title/album/year all nil, no year clear) has NOTHING to
        // project onto Serato or the audio file — the recording link lives in
        // the DB alone. Scheduling a file-tag write anyway is not harmless:
        // the Rust writer saves with `remove_others(true)` unconditionally
        // (tags.rs), so an empty patch still rewrites the file, bumps its
        // mtime, and can strip secondary ID3v1/APE tags. Emit each write only
        // when it actually carries a change.
        let hasSeratoMetadataFields = artist != nil || title != nil || album != nil
        let fileTagNeedsWrite = hasSeratoMetadataFields || year != nil || clearFileYear

        var writes: [SeratoPendingWrite] = []
        if hasSeratoMetadataFields {
            // Serato's database V2 has no year field, so `clearFileYear`
            // is irrelevant to the metadata update — it only affects the
            // file-tag write.
            writes.append(.metadataUpdate(SeratoPendingMetadataUpdate(
                absolutePath: absolutePath, metadata: metadata
            )))
        }
        if fileTagNeedsWrite {
            writes.append(.fileTagWrite(SeratoPendingFileTagWrite(
                absolutePath: absolutePath, metadata: metadata, year: year, clearYear: clearFileYear
            )))
        }
        return writes
    }

    private static func applyMusicBrainzDisplayFields(
        _ payload: ApplyMusicBrainzMatchPayload, to track: inout TrackRecord, seedKeptFields: Bool
    ) {
        if let artist = payload.artist ?? (seedKeptFields ? payload.currentFileArtist : nil) { track.artist = artist }
        if let title = payload.title ?? (seedKeptFields ? payload.currentFileTitle : nil) { track.title = title }
        if let album = payload.album ?? (seedKeptFields ? payload.currentFileAlbum : nil) { track.album = album }
        if let year = payload.year ?? (seedKeptFields ? payload.currentFileYear : nil) { track.year = year }
    }

    private static func applyMusicBrainzMatch(
        _ payload: ApplyMusicBrainzMatchPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, [SeratoPendingWrite]) {
        guard var fileRecord = try FileRecord.fetchOne(db, key: payload.fileID) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileID)
        }

        // D-A note: apply-time candidate staleness is enforced BEFORE this
        // transaction by `AutoTaggerService.staleFileIDs`, which re-stats the
        // file on disk and compares to the payload's on-disk-at-lookup
        // snapshot. It can't run here — this closure is inside the writer
        // transaction and must not do file I/O — and a DB-vs-DB comparison
        // would be a no-op anyway (nothing mutates `files.fileSize`/`mtime`
        // after indexing; see D-B).

        // Snapshot the file's Serato metadata + track link before
        // mutating, so the inverse can restore them exactly.
        let previousMetadata = SeratoMetadata(
            artist: fileRecord.artist,
            title: fileRecord.title,
            album: fileRecord.album,
            genre: fileRecord.genre,
            bpm: fileRecord.bpm,
            musicalKey: fileRecord.musicalKey,
            comment: fileRecord.comment,
            length: fileRecord.length,
            label: fileRecord.label
        )
        let previousTrackID = fileRecord.trackId

        // Upsert the canonical track row keyed by fingerprint (invariant
        // #4): identity fields always applied, display fields cherry-
        // picked (nil leaves the prior value).
        var previousTrackIdentifiers: TrackIdentifiers?
        let createdTrackRow: Bool
        let trackID: Int64

        if var existingTrack = try TrackRecord
            .filter(Column("fingerprint_hash") == payload.fingerprintHash)
            .fetchOne(db) {
            // D-C: a 120s-capped fingerprint can collide across two DIFFERENT
            // recordings. When the row already carries a recording MBID that
            // differs from the incoming one AND another file depends on that
            // row, overwriting would mis-link every one of those files
            // (invariant #4). Reject instead. A single file re-identifying
            // its OWN row (no other references) is a legitimate correction
            // and proceeds — the reference check is what distinguishes a
            // collision from a re-match.
            if let existingRecordingMBID = existingTrack.musicbrainzRecordingId,
               existingRecordingMBID != payload.recordingMBID {
                let otherFilesReferenceRow = try FileRecord.hasOtherFilesReferencingTrack(
                    existingTrack.id, excluding: payload.fileID, in: db
                )
                if otherFilesReferenceRow {
                    throw OperationEngineError.fingerprintRecordingConflict(
                        fileId: payload.fileID,
                        existingMBID: existingRecordingMBID,
                        incomingMBID: payload.recordingMBID
                    )
                }
            }
            previousTrackIdentifiers = TrackIdentifiers(
                acoustID: existingTrack.acoustidId,
                recordingMBID: existingTrack.musicbrainzRecordingId,
                releaseMBID: existingTrack.musicbrainzReleaseId,
                artistMBID: existingTrack.musicbrainzArtistId,
                isrc: existingTrack.isrc,
                artist: existingTrack.artist,
                title: existingTrack.title,
                album: existingTrack.album,
                year: existingTrack.year
            )
            createdTrackRow = false
            guard let existingId = existingTrack.id else {
                throw OperationEngineError.insertDidNotReturnRowId
            }
            // Undo retains an empty fingerprint row for FK stability. Reusing
            // that unreferenced row must seed kept fields just like creation.
            let isEmptyOrphan = try existingTrack == TrackRecord(id: existingId, fingerprintHash: payload.fingerprintHash)
                && FileRecord.filter(Column("track_id") == existingId).fetchCount(db) == 0
            existingTrack.acoustidId = payload.acoustID
            existingTrack.musicbrainzRecordingId = payload.recordingMBID
            existingTrack.musicbrainzReleaseId = payload.releaseMBID
            existingTrack.musicbrainzArtistId = payload.artistMBID
            existingTrack.isrc = payload.isrc
            applyMusicBrainzDisplayFields(payload, to: &existingTrack, seedKeptFields: isEmptyOrphan)
            try existingTrack.update(db)
            trackID = existingId
        } else {
            previousTrackIdentifiers = nil
            createdTrackRow = true
            // Seed a BRAND-NEW canonical row's display fields from the kept
            // on-disk values when the user left a field unchecked / chose Keep
            // (payload.<field> == nil). Otherwise a normal first confirmation
            // would create a recording with identifiers but a NULL
            // title/artist/album/year even though the kept value is known in the
            // payload's currentFile* snapshot (finding #4001501073). For an
            // occupied or nonempty existing row, nil still means leave-unchanged.
            var newTrack = TrackRecord(
                fingerprintHash: payload.fingerprintHash,
                acoustidId: payload.acoustID,
                musicbrainzRecordingId: payload.recordingMBID,
                musicbrainzReleaseId: payload.releaseMBID,
                musicbrainzArtistId: payload.artistMBID,
                isrc: payload.isrc
            )
            applyMusicBrainzDisplayFields(payload, to: &newTrack, seedKeptFields: true)
            try newTrack.insert(db)
            guard let newId = newTrack.id else {
                throw OperationEngineError.insertDidNotReturnRowId
            }
            trackID = newId
        }

        // Link the file and apply the cherry-picked display fields to
        // its Serato snapshot.
        fileRecord.trackId = trackID
        if let artist = payload.artist { fileRecord.artist = artist }
        if let title = payload.title { fileRecord.title = title }
        if let album = payload.album { fileRecord.album = album }
        try fileRecord.update(db)

        var forwardPayload = payload
        forwardPayload.previousTrackID = previousTrackID
        forwardPayload.previousMetadata = previousMetadata
        // D-D: undo rewrites the AUDIO FILE's tags back to what was actually
        // embedded before the match — captured on-disk at lookup time — not
        // the Serato-imported `files`-row snapshot (`previousMetadata`),
        // which can differ from the file's real tags. The DB-row restore
        // still uses `previousMetadata` (correct for the row); only this
        // file-tag restore uses the on-disk capture.
        forwardPayload.previousFileTags = SeratoMetadata(
            artist: payload.currentFileArtist,
            title: payload.currentFileTitle,
            album: payload.currentFileAlbum
        )
        forwardPayload.previousFileYear = payload.currentFileYear
        forwardPayload.previousTrackIdentifiers = previousTrackIdentifiers
        forwardPayload.createdTrackRow = createdTrackRow

        let inversePayload = RevertMusicBrainzMatchPayload(applied: forwardPayload)

        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileID,
            trackId: trackID,
            eventType: .musicBrainzMatchApplied,
            forwardPayload: forwardPayload,
            inversePayload: inversePayload,
            in: db
        )

        let seratoWrites = musicBrainzSeratoWrites(
            absolutePath: fileRecord.path,
            artist: payload.artist,
            title: payload.title,
            album: payload.album,
            year: payload.year
        )
        return (eventId, seratoWrites)
    }

    private static func applyRevertMusicBrainzMatch(
        _ payload: RevertMusicBrainzMatchPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, [SeratoPendingWrite]) {
        let applied = payload.applied
        guard var fileRecord = try FileRecord.fetchOne(db, key: applied.fileID) else {
            throw OperationEngineError.fileNotFound(fileId: applied.fileID)
        }

        // The canonical track row keyed by this file's fingerprint (the
        // forward created it or it pre-existed). Fetch and evaluate it BEFORE
        // mutating anything so an out-of-order undo can be rejected cleanly.
        let track = try TrackRecord
            .filter(Column("fingerprint_hash") == applied.fingerprintHash)
            .fetchOne(db)

        // Undoing batch A must never overwrite what a later batch B
        // established on the same fingerprint-keyed row (invariant #4:
        // FLAC+MP3 of one recording, or a re-encode, share a track row). A's
        // undo may touch the row's identity only when A still SOLELY owns it:
        // no other file references it (a later batch that adopted or kept the
        // row links its own file to it) AND its identity is still exactly what
        // A's forward wrote. Both guards are needed — when B re-matches to the
        // SAME recording the identity doesn't drift, so the reference count is
        // the only signal that B now owns the row.
        let otherFilesReferenceRow = try track.map { row in
            try FileRecord.hasOtherFilesReferencingTrack(row.id, excluding: applied.fileID, in: db)
        } ?? false
        let forwardIdentityStillOnRow = track.map { row in
            row.acoustidId == applied.acoustID
                && row.musicbrainzRecordingId == applied.recordingMBID
                && row.musicbrainzReleaseId == applied.releaseMBID
                && row.musicbrainzArtistId == applied.artistMBID
                && row.isrc == applied.isrc
        } ?? false
        let thisForwardStillSolelyOwnsRow = !otherFilesReferenceRow && forwardIdentityStillOnRow

        // Whether THIS file is the row's current identity owner. This
        // distinguishes the two cases the reference count conflates for a
        // PRE-EXISTING row (finding #4000261456): an OLDER file that already
        // referenced the row before this match — whose captured state is
        // exactly what `previousTrackIdentifiers` restores, so it must NOT
        // block restoration — versus a LATER batch that re-owned the row with
        // its own file's match, which must. (The out-of-order guard in
        // `undoBatch` already rejects the case where THIS file was itself
        // re-matched later, so a later event for this same file can't reach
        // here.) `nil` — no live matcher for the track (e.g. a row seeded
        // outside the match path) — falls back to the reference-count gate.
        //
        // The current matcher is the latest file to apply a match to this row
        // that is STILL linked to it — filtered on the file's live `track_id`,
        // NOT merely the latest historical apply. When two files sharing this
        // row are undone in one batch, reverting the newer sibling first clears
        // its row link (above, in its own inverse) but leaves its apply as the
        // latest historical apply in the log. A bare "latest apply" query would
        // then wrongly name that just-reverted sibling the owner, so the next
        // inverse (the older sibling's) would skip restoring its
        // `previousTrackIdentifiers` and leave the row's metadata changed after
        // the whole batch was undone (finding #4001251152). Requiring the
        // applier to still reference the row drops the reverted sibling —
        // reverts key their event to the file's PREVIOUS track, not this row,
        // so they can't be counted directly — and correctly names the older
        // file. THIS file is still linked here (it is unlinked below), so it
        // remains a candidate.
        let thisFileIsRowLatestMatcher: Bool? = try track.flatMap { row -> Bool? in
            guard let trackID = row.id else { return nil }
            let latestMatcherFileId = try Int64.fetchOne(db, sql: """
                SELECT events.file_id FROM events
                JOIN files ON files.id = events.file_id
                WHERE events.track_id = ? AND events.event_type = ?
                  AND files.track_id = ?
                ORDER BY events.event_id DESC LIMIT 1
                """, arguments: [trackID, EventType.musicBrainzMatchApplied.rawValue, trackID])
            return latestMatcherFileId.map { $0 == applied.fileID }
        }

        // The out-of-order undo guard (rejecting a revert whose file was
        // re-matched by a LATER batch) lives in `undoBatch`, keyed on the event
        // log — the authoritative signal. Row/reference state can't be used
        // here: a same-batch sibling (a different file sharing the row) and a
        // cross-batch re-match of THIS file to the same recording/different
        // release present identical row state (recording unchanged, release
        // drifted, no surviving reference), yet one must undo and the other
        // must be rejected (finding #3999974010). So this method assumes the
        // revert is in-order and only gates the shared-row teardown below.

        // Restore the file link + Serato snapshot for exactly the
        // display fields the forward changed.
        fileRecord.trackId = applied.previousTrackID
        if let previousMetadata = applied.previousMetadata {
            if applied.artist != nil { fileRecord.artist = previousMetadata.artist }
            if applied.title != nil { fileRecord.title = previousMetadata.title }
            if applied.album != nil { fileRecord.album = previousMetadata.album }
        }
        try fileRecord.update(db)

        // Restore or null the canonical track row, gated by the ownership
        // predicate computed above; the file itself has already been
        // unlinked. It always exists here in practice — the forward created
        // it or it pre-existed.
        if var track {
            if applied.createdTrackRow {
                // The forward created this row. Null what it set and leave
                // the now-orphaned row in place — but only while A solely
                // owns it; otherwise a later batch's match would be wiped.
                if thisForwardStillSolelyOwnsRow {
                    track.acoustidId = nil
                    track.musicbrainzRecordingId = nil
                    track.musicbrainzReleaseId = nil
                    track.musicbrainzArtistId = nil
                    track.isrc = nil
                    track.artist = nil
                    track.title = nil
                    track.album = nil
                    track.year = nil
                    try track.update(db)
                }
            } else if let previous = applied.previousTrackIdentifiers {
                // Restore the pre-existing row's captured identity — but only
                // while THIS file is still the row's latest matcher. If a later
                // batch re-owned the row with a different file's match,
                // restoring A's `previous` would clobber the identity that
                // later batch relies on; leave the row alone in that case. An
                // OLDER file that merely still references the row does NOT block
                // restoration — its state is precisely what `previous` restores
                // (finding #4000261456).
                //
                // OR-ed with the original sole-owner gate so a LIFO undo of two
                // batches that both adopted a pre-existing row still restores on
                // the SECOND undo: after the later batch is undone the row is
                // unlinked and back at this forward's identity, but the latest
                // `musicBrainzMatchApplied` still points at the (now-reverted)
                // later file, so the latest-matcher test alone would wrongly
                // block it. `thisForwardStillSolelyOwnsRow` (no surviving
                // reference AND identity intact) safely covers that case and
                // can't fire while a later owner is live, so it never
                // reintroduces the clobber it originally guarded against.
                if thisFileIsRowLatestMatcher == true || thisForwardStillSolelyOwnsRow {
                    track.acoustidId = previous.acoustID
                    track.musicbrainzRecordingId = previous.recordingMBID
                    track.musicbrainzReleaseId = previous.releaseMBID
                    track.musicbrainzArtistId = previous.artistMBID
                    track.isrc = previous.isrc
                    track.artist = previous.artist
                    track.title = previous.title
                    track.album = previous.album
                    track.year = previous.year
                    try track.update(db)
                }
            } else {
                // Unreachable: a pre-existing track row (createdTrackRow
                // == false) always captures previousTrackIdentifiers in
                // the forward apply. If this ever fires, the forward's
                // invariant broke silently, and no-oping here would
                // leave the row's identifiers unchanged instead of
                // restored — fail loudly instead.
                assertionFailure(
                    "applyRevertMusicBrainzMatch: pre-existing track row for file \(applied.fileID) has no previousTrackIdentifiers to restore"
                )
                throw OperationEngineError.missingPreviousTrackIdentifiers(fileId: applied.fileID)
            }
        }

        // Journal the revert; its inverse is the original forward match
        // so redo (undo of the undo) re-applies it.
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: applied.fileID,
            trackId: applied.previousTrackID,
            eventType: .musicBrainzMatchReverted,
            forwardPayload: payload,
            inversePayload: applied,
            in: db
        )

        let seratoWrites = Self.musicBrainzRevertSeratoWrites(applied: applied, absolutePath: fileRecord.path)
        return (eventId, seratoWrites)
    }

    /// The Serato/audio-tag writes that REVERT a MusicBrainz match: restore the
    /// audio file's tags to their exact pre-match values. For every text field
    /// the forward actually wrote, undo must rewrite it — to its captured
    /// pre-match value, or (when that was absent) an empty string so the Rust
    /// writer *clears* it; `nil` would leave the just-applied value in place.
    /// Year rides only on the file tag: restore the file's real pre-match year,
    /// or clear the frame outright if the match added one where none existed.
    ///
    /// Shared by `applyRevertMusicBrainzMatch` (undo) and `resyncWrites` (so a
    /// reverted event whose external restore write failed mid-undo can be
    /// re-synced — finding #3999974011).
    private static func musicBrainzRevertSeratoWrites(
        applied: ApplyMusicBrainzMatchPayload,
        absolutePath: String
    ) -> [SeratoPendingWrite] {
        // The two external targets restore from DIFFERENT snapshots: Serato's
        // database V2 (and the SQLite `files` row, already restored in
        // `applyRevertMusicBrainzMatch`) go back to `previousMetadata` — the
        // Serato-imported snapshot — while the audio file tag goes back to
        // `previousFileTags` — the file's real pre-match on-disk tag. Sharing
        // one snapshot for both left Serato and the sidecar DB inconsistent
        // after undo whenever they disagreed pre-match (finding #4000405427).
        // For each text field the forward wrote, restore that target's snapshot
        // value, or "" to clear a field the match added from empty.
        let dbSnapshot = applied.previousMetadata ?? .empty
        let fileSnapshot = applied.previousFileTags ?? applied.previousMetadata ?? .empty

        let v2Metadata = SeratoMetadata(
            artist: applied.artist != nil ? (dbSnapshot.artist ?? "") : nil,
            title: applied.title != nil ? (dbSnapshot.title ?? "") : nil,
            album: applied.album != nil ? (dbSnapshot.album ?? "") : nil
        )
        let fileMetadata = SeratoMetadata(
            artist: applied.artist != nil ? (fileSnapshot.artist ?? "") : nil,
            title: applied.title != nil ? (fileSnapshot.title ?? "") : nil,
            album: applied.album != nil ? (fileSnapshot.album ?? "") : nil
        )
        let forwardWroteYear = applied.year != nil
        let fileYear = forwardWroteYear ? applied.previousFileYear : nil
        let clearFileYear = forwardWroteYear && applied.previousFileYear == nil

        var writes: [SeratoPendingWrite] = []
        if v2Metadata.artist != nil || v2Metadata.title != nil || v2Metadata.album != nil {
            writes.append(.metadataUpdate(SeratoPendingMetadataUpdate(
                absolutePath: absolutePath, metadata: v2Metadata
            )))
        }
        if fileMetadata.artist != nil || fileMetadata.title != nil || fileMetadata.album != nil
            || fileYear != nil || clearFileYear
        {
            writes.append(.fileTagWrite(SeratoPendingFileTagWrite(
                absolutePath: absolutePath, metadata: fileMetadata, year: fileYear, clearYear: clearFileYear
            )))
        }
        return writes
    }

    static func insertEvent<ForwardPayload: Encodable, InversePayload: Encodable>(
        batchId: String,
        timestamp: Int64,
        fileId: Int64?,
        trackId: Int64? = nil,
        eventType: EventType,
        forwardPayload: ForwardPayload,
        inversePayload: InversePayload,
        in db: GRDB.Database
    ) throws -> Int64 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var forwardJsonData = try encoder.encode(forwardPayload)
        if let fileId, let file = try FileRecord.fetchOne(db, key: fileId) {
            guard var object = try JSONSerialization.jsonObject(with: forwardJsonData) as? [String: Any] else {
                throw OperationEngineError.payloadEncodingFailed
            }
            object["membershipRevision"] = file.membershipRevision
            forwardJsonData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        let inverseJsonData = try encoder.encode(inversePayload)

        guard let forwardJsonString = String(data: forwardJsonData, encoding: .utf8),
              let inverseJsonString = String(data: inverseJsonData, encoding: .utf8) else {
            throw OperationEngineError.payloadEncodingFailed
        }

        var event = EventRecord(
            batchId: batchId,
            timestamp: timestamp,
            fileId: fileId,
            trackId: trackId,
            eventType: eventType,
            payloadJson: forwardJsonString,
            inversePayloadJson: inverseJsonString
        )
        try event.insert(db)
        guard let eventId = event.eventId else {
            throw OperationEngineError.insertDidNotReturnRowId
        }
        return eventId
    }
}

// MARK: - Resync types

/// Result of `resyncSeratoForBatch`. Separates writes that
/// actually hit disk from writes that queued because Serato was
/// running (in-memory only, drain on Serato exit). The UI uses
/// this split to phrase the result honestly — "Re-sync complete"
/// when N actually landed vs "Queued N — quit Serato to apply"
/// when nothing did.
public struct ResyncOutcome: Sendable, Equatable {
    public let appliedCount: Int
    public let queuedCount: Int
    public let supersededCount: Int

    public init(appliedCount: Int, queuedCount: Int, supersededCount: Int = 0) {
        self.appliedCount = appliedCount
        self.queuedCount = queuedCount
        self.supersededCount = supersededCount
    }

    public var totalCount: Int { appliedCount + queuedCount }

    public var summaryMessage: String {
        if supersededCount > 0 {
            return "Re-sync wrote \(appliedCount), queued \(queuedCount), superseded \(supersededCount) changes whose original file or saved-field authority changed or could not be verified."
        }
        if totalCount == 0 {
            return "Re-sync inspected the batch — no Serato changes to replay."
        }
        if queuedCount == 0 {
            return "Re-sync complete — wrote \(appliedCount) change\(appliedCount == 1 ? "" : "s") to the Serato library."
        }
        if appliedCount == 0 {
            return "Re-sync queued \(queuedCount) change\(queuedCount == 1 ? "" : "s") — Serato is running, quit Serato to apply."
        }
        return "Re-sync wrote \(appliedCount), queued \(queuedCount) (Serato started during the sweep)."
    }
}

// MARK: - Mutation types

public enum TrackMutation: Sendable {
    case indexNewFile(IndexNewFilePayload)
    case renameFile(RenameFilePayload)
    case removeFile(RemoveFilePayload)
    case setFileLibraryState(SetFileLibraryStatePayload)
    case observeFileLocation(ObserveFileLocationPayload)
    case observeFileIdentity(ObserveFileIdentityPayload)
    case beginFileImport(BeginFileImportPayload)
    case setMetadata(SetMetadataPayload)
    case commitMetadataToSerato(CommitMetadataToSeratoPayload)
    case addTrackToSerato(AddTrackToSeratoPayload)
    case writeFileTags(WriteFileTagsPayload)
    case trashFile(TrashFilePayload)
    case removeTrackFromSerato(RemoveTrackFromSeratoPayload)
    case removeFileFromCrates(RemoveFileFromCratesPayload)
    case applyMusicBrainzMatch(ApplyMusicBrainzMatchPayload)
    /// Inverse of `applyMusicBrainzMatch`, produced only by
    /// `decodeInverseMutation` during undo. Never constructed by
    /// feature code directly.
    case revertMusicBrainzMatch(RevertMusicBrainzMatchPayload)
}

/// Move the file at `fileId` to the user's Trash via
/// FileManager.trashItem. Reversible only by the user via Finder
/// ("Put Back"); journaled but undoNotSupported in the engine
/// because we can't reliably re-create audio bytes if the user has
/// emptied Trash by the time undo runs.
public struct TrashFilePayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public init(fileId: Int64) { self.fileId = fileId }
}

/// Remove the `otrk` from Serato's database V2 whose `pfil`
/// matches the file's path. Gated by `SeratoWatchdog` — Serato
/// must be closed to avoid the in-memory cache overwriting the
/// disk version on save. Not undoable: re-adding would require
/// reconstructing the otrk's full metadata + analysis (cue points,
/// beatgrid) which we don't carry across the boundary today.
public struct RemoveTrackFromSeratoPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public init(fileId: Int64) { self.fileId = fileId }
}

/// Sweep every `.crate` file in Serato's Subcrates directory and
/// remove the `otrk` whose `ptrk` matches the file's path. Gated
/// by SeratoWatchdog. Not undoable: a follow-up "re-add to original
/// crates" would need to track which crates contained the file
/// before removal, which isn't journaled today.
public struct RemoveFileFromCratesPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public init(fileId: Int64) { self.fileId = fileId }
}

/// Snapshot of the canonical `tracks` row's identity + display fields
/// as they stood immediately before an `applyMusicBrainzMatch`. Filled
/// by the engine at apply time only when the match landed on a
/// pre-existing row; `nil` when the match created the row (undo nulls
/// the row's fields instead of restoring them). Captures every column
/// the mutation may overwrite so undo restores the row exactly.
public struct TrackIdentifiers: Codable, Sendable, Equatable {
    public let acoustID: String?
    public let recordingMBID: String?
    public let releaseMBID: String?
    public let artistMBID: String?
    public let isrc: String?
    public let artist: String?
    public let title: String?
    public let album: String?
    public let year: Int?

    public init(
        acoustID: String?,
        recordingMBID: String?,
        releaseMBID: String?,
        artistMBID: String?,
        isrc: String?,
        artist: String?,
        title: String?,
        album: String?,
        year: Int?
    ) {
        self.acoustID = acoustID
        self.recordingMBID = recordingMBID
        self.releaseMBID = releaseMBID
        self.artistMBID = artistMBID
        self.isrc = isrc
        self.artist = artist
        self.title = title
        self.album = album
        self.year = year
    }
}

/// Writes a confirmed MusicBrainz match: upserts the canonical `tracks`
/// row (keyed by Chromaprint fingerprint — invariant #4), links the
/// file to it, and applies the cherry-picked display fields to the
/// file's Serato snapshot, Serato's `database V2`, and the audio file's
/// tags.
///
/// Identity fields (`acoustID`, `recordingMBID`, `releaseMBID`,
/// `artistMBID`, `isrc`) are ALWAYS written to the track row. Display
/// fields (`artist`, `title`, `album`, `year`) are cherry-picked — a
/// `nil` field is not applied, leaving the prior value in place.
///
/// `year` reaches ONLY the audio file's tags and `tracks.year`;
/// `SeratoMetadata` (and therefore Serato's `database V2`) has no year
/// field, so it is deliberately not threaded through the Serato write.
///
/// The `previous…` fields are populated by the engine at apply time to
/// make the event fully undoable (invariant #2). Callers leave them at
/// their defaults.
public struct ApplyMusicBrainzMatchPayload: Codable, Sendable, Equatable {
    public let fileID: Int64
    // Identity — always applied:
    public let acoustID: String?
    public let recordingMBID: String
    public let releaseMBID: String?
    public let artistMBID: String?
    public let isrc: String?
    public let fingerprintHash: Data
    /// The file's ACTUAL on-disk identity (`fileSize`/`mtime`, read via the
    /// freshness stat — NOT the DB-indexed `FileRecord` values, which no
    /// in-place edit updates) as seen when the candidate was built at lookup
    /// time. `AutoTaggerService.staleFileIDs` re-stats the file just before
    /// Apply and compares to these; a mismatch means the file was replaced
    /// or edited since review, so that row is excluded from the batch rather
    /// than linking stale identity to changed audio (finding D-A). The
    /// engine can't do that stat inside its write transaction, so the guard
    /// runs in the async apply path, not here.
    ///
    /// Optional so an event JOURNALED by an earlier build of this branch —
    /// before D-A added these fields — still decodes (both come back nil);
    /// such a legacy event predates the check, so revalidation skips it.
    /// `AutoTagRowModel.payload()` always populates them for a fresh apply.
    public let expectedFileSize: Int64?
    public let expectedMtime: Int64?
    // Cherry-picked display fields — absent (nil) means not applied:
    public let artist: String?
    public let title: String?
    public let album: String?
    public let year: Int?
    /// The file's actual on-disk year tag before the match, read by the
    /// review UI (`AudioTags.year`) and supplied by the caller. The
    /// engine can't recover it at apply time (`tracks.year` is a
    /// different, often-empty value — invariant #4), so undo depends on
    /// it being threaded through here. Snapshotted into
    /// `previousFileYear` at apply time.
    public let currentFileYear: Int?
    /// The file's actual on-disk artist/title/album tags before the match,
    /// read by the review UI (`AudioTags`) and supplied by the caller.
    /// These, not the Serato-imported `files`-row snapshot
    /// (`previousMetadata`), are what undo must rewrite back into the audio
    /// file's tags — the embedded tags can differ from the DB row, and undo
    /// must restore the file's ORIGINAL embedded values, not the DB values
    /// (finding D-D). Snapshotted into `previousFileTags` at apply time.
    public let currentFileArtist: String?
    public let currentFileTitle: String?
    public let currentFileAlbum: String?
    // Previous-state snapshots, filled by the engine at apply time:
    public var previousTrackID: Int64?
    public var previousMetadata: SeratoMetadata?
    public var previousFileTags: SeratoMetadata?
    /// The file's on-disk year immediately before the match (copied from
    /// `currentFileYear` at apply time). Undo restores the file tag to
    /// this value — or clears the year frame when it's nil and the match
    /// added one — independent of the canonical `tracks.year`.
    public var previousFileYear: Int?
    public var previousTrackIdentifiers: TrackIdentifiers?
    public var createdTrackRow: Bool

    public init(
        fileID: Int64,
        acoustID: String?,
        recordingMBID: String,
        releaseMBID: String?,
        artistMBID: String?,
        isrc: String?,
        fingerprintHash: Data,
        expectedFileSize: Int64? = nil,
        expectedMtime: Int64? = nil,
        artist: String?,
        title: String?,
        album: String?,
        year: Int?,
        currentFileYear: Int? = nil,
        currentFileArtist: String? = nil,
        currentFileTitle: String? = nil,
        currentFileAlbum: String? = nil,
        previousTrackID: Int64? = nil,
        previousMetadata: SeratoMetadata? = nil,
        previousFileTags: SeratoMetadata? = nil,
        previousFileYear: Int? = nil,
        previousTrackIdentifiers: TrackIdentifiers? = nil,
        createdTrackRow: Bool = false
    ) {
        self.fileID = fileID
        self.acoustID = acoustID
        self.recordingMBID = recordingMBID
        self.releaseMBID = releaseMBID
        self.artistMBID = artistMBID
        self.isrc = isrc
        self.fingerprintHash = fingerprintHash
        self.expectedFileSize = expectedFileSize
        self.expectedMtime = expectedMtime
        self.artist = artist
        self.title = title
        self.album = album
        self.year = year
        self.currentFileYear = currentFileYear
        self.currentFileArtist = currentFileArtist
        self.currentFileTitle = currentFileTitle
        self.currentFileAlbum = currentFileAlbum
        self.previousTrackID = previousTrackID
        self.previousMetadata = previousMetadata
        self.previousFileTags = previousFileTags
        self.previousFileYear = previousFileYear
        self.previousTrackIdentifiers = previousTrackIdentifiers
        self.createdTrackRow = createdTrackRow
    }
}

/// Inverse of `applyMusicBrainzMatch`. Wraps the fully-populated
/// forward payload (with its `previous…` snapshots) so the revert can
/// restore prior state exactly, and so redo (undo of the undo) can
/// re-issue the original forward match.
public struct RevertMusicBrainzMatchPayload: Codable, Sendable, Equatable {
    public let applied: ApplyMusicBrainzMatchPayload

    public init(applied: ApplyMusicBrainzMatchPayload) {
        self.applied = applied
    }
}

/// Writes metadata into the audio file's primary tag (ID3v2.4 for
/// MP3, Vorbis comments for FLAC, iTunes atoms for M4A — Lofty
/// dispatches by format). Captures `previousMetadata` so the
/// reverse mutation can rewrite the file's tags back to their
/// prior state, making the event fully undoable.
///
/// Gated by `SeratoWatchdog` the same way Serato library writes
/// are: Serato may have a file mmapped during playback or analysis,
/// and writing tags underneath it can corrupt the read. The
/// pending-writes queue ensures crate-agent's file writes happen
/// only while Serato is closed.
public struct WriteFileTagsPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let metadata: SeratoMetadata
    public let previousMetadata: SeratoMetadata?

    public init(
        fileId: Int64,
        metadata: SeratoMetadata,
        previousMetadata: SeratoMetadata? = nil
    ) {
        self.fileId = fileId
        self.metadata = metadata
        self.previousMetadata = previousMetadata
    }
}

/// Inserts a new otrk entry into Serato's database V2 for the file
/// at `fileId`'s path. Used by the drag-drop import flow — after
/// `indexNewFile` registers the file in crate-agent's DB, this
/// mutation registers it with Serato. Gated by SeratoWatchdog.
public struct AddTrackToSeratoPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let metadata: SeratoMetadata

    public init(fileId: Int64, metadata: SeratoMetadata) {
        self.fileId = fileId
        self.metadata = metadata
    }
}

public struct IndexNewFilePayload: Codable, Sendable, Equatable {
    public let path: String
    public let volumeUuid: String
    public let inode: Int64
    public let fileSize: Int64
    public let mtime: Int64
    public let lightweightHash: Data?
    public let bitrateKbps: Int?
    public let metadata: SeratoMetadata

    public init(
        path: String,
        volumeUuid: String,
        inode: Int64,
        fileSize: Int64,
        mtime: Int64,
        lightweightHash: Data? = nil,
        bitrateKbps: Int? = nil,
        metadata: SeratoMetadata = .empty
    ) {
        self.path = path
        self.volumeUuid = volumeUuid
        self.inode = inode
        self.fileSize = fileSize
        self.mtime = mtime
        self.lightweightHash = lightweightHash
        self.bitrateKbps = bitrateKbps
        self.metadata = metadata
    }
}

/// Mirror of Serato's per-track metadata. Stored as strings even
/// for numeric-ish fields (`bpm`, `length`) because Serato stores
/// them that way ("128.000", "03:24") — round-trip lossless.
public struct SeratoMetadata: Codable, Sendable, Equatable, Hashable {
    public var artist: String?
    public var title: String?
    public var album: String?
    public var genre: String?
    public var bpm: String?
    public var musicalKey: String?
    public var comment: String?
    public var length: String?
    public var label: String?

    public init(
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        bpm: String? = nil,
        musicalKey: String? = nil,
        comment: String? = nil,
        length: String? = nil,
        label: String? = nil
    ) {
        self.artist = artist
        self.title = title
        self.album = album
        self.genre = genre
        self.bpm = bpm
        self.musicalKey = musicalKey
        self.comment = comment
        self.length = length
        self.label = label
    }

    public static let empty = SeratoMetadata()
}

public struct SetMetadataPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let metadata: SeratoMetadata
    /// Engine captures the row's current values before journaling.
    public let previousMetadata: SeratoMetadata
    /// Imports reflect values already present in Serato. Local snapshots,
    /// including every undo, do not establish V2 ownership. Nil is legacy.
    public let isSeratoAuthoritative: Bool?

    public init(
        fileId: Int64,
        metadata: SeratoMetadata,
        previousMetadata: SeratoMetadata = .empty,
        isSeratoAuthoritative: Bool? = false
    ) {
        self.fileId = fileId
        self.metadata = metadata
        self.previousMetadata = previousMetadata
        self.isSeratoAuthoritative = isSeratoAuthoritative
    }
}

/// Writes the specified metadata fields into Serato's `database V2`
/// for the file. Does NOT touch crate-agent's DB (the caller should
/// have already run `setMetadata` first). Gated by SeratoWatchdog —
/// queued while Serato is running, applied when Serato exits.
///
/// Typically batched with a `setMetadata` mutation under the same
/// batch_id when the user edits metadata in crate-agent's UI: the
/// setMetadata updates crate-agent's snapshot, the
/// commitMetadataToSerato propagates the change to Serato.
///
/// `previousMetadata` carries the values Serato held immediately
/// before this commit, supplied by the caller (the apply path
/// can't read Serato's state — it would race with Serato's own
/// writes). Non-nil here makes the event undoable: the inverse
/// re-issues the commit with `previousMetadata` swapped in for
/// `metadata`. Callers that don't know the previous state pass nil
/// and forfeit undo for this event.
public struct CommitMetadataToSeratoPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let metadata: SeratoMetadata
    public let previousMetadata: SeratoMetadata?

    public init(
        fileId: Int64,
        metadata: SeratoMetadata,
        previousMetadata: SeratoMetadata? = nil
    ) {
        self.fileId = fileId
        self.metadata = metadata
        self.previousMetadata = previousMetadata
    }
}

public struct RenameFilePayload: Codable, Sendable, Equatable {
    public let physicalMove: Bool?
    public let fileId: Int64
    public let newPath: String
    public let previousPath: String
    /// Cross-volume rename: when the file moved to a different volume,
    /// its `inode` and `volume_uuid` change. nil means same-volume
    /// rename (engine leaves the identity fields alone). Engine fills
    /// in `previousVolumeUuid` / `previousInode` from the existing
    /// row at apply time — callers pass nil for those.
    public let newVolumeUuid: String?
    public let newInode: Int64?
    public let previousVolumeUuid: String?
    public let previousInode: Int64?

    public init(
        fileId: Int64,
        newPath: String,
        previousPath: String = "",
        newVolumeUuid: String? = nil,
        newInode: Int64? = nil,
        previousVolumeUuid: String? = nil,
        previousInode: Int64? = nil,
        physicalMove: Bool? = nil
    ) {
        self.physicalMove = physicalMove
        self.fileId = fileId
        self.newPath = newPath
        self.previousPath = previousPath
        self.newVolumeUuid = newVolumeUuid
        self.newInode = newInode
        self.previousVolumeUuid = previousVolumeUuid
        self.previousInode = previousInode
    }
}

public struct RemoveFilePayload: Codable, Sendable, Equatable {
    public let fileId: Int64

    public init(fileId: Int64) {
        self.fileId = fileId
    }
}

// MARK: - Queue types

/// A write that's deferred while Serato is running. Originally
/// only Serato library files (`.crate`, `database V2`); SP-1.5
/// expanded the queue to also gate audio-file tag writes, because
/// Serato may have audio files mmapped during playback or analysis
/// and writing tags underneath could corrupt the read.
enum SeratoPendingWrite: Sendable, Equatable {
    case rename(SeratoPendingRename)
    case metadataUpdate(SeratoPendingMetadataUpdate)
    case addTrack(SeratoPendingAddTrack)
    case fileTagWrite(SeratoPendingFileTagWrite)
    case removeFromDatabase(SeratoPendingRemoval)
    case removeFromCrates(SeratoPendingRemoval)
    case trashFile(SeratoPendingTrash)
}

/// Queued removal of a file's references from Serato. Same payload
/// for database V2 (`.removeFromDatabase`) and `.crate` sweep
/// (`.removeFromCrates`) — both need just the absolute path.
struct SeratoPendingRemoval: Sendable, Equatable {
    let absolutePath: String
}

/// Queued trash-move. Routed through the SeratoWatchdog gate
/// because Serato may have the file open for playback or analysis;
/// moving a file out from under Serato can crash it or corrupt
/// in-flight reads.
struct SeratoPendingTrash: Sendable, Equatable {
    let absolutePath: String
}

/// File-tag write deferred by the SeratoWatchdog. Carries the
/// absolute path resolved from the FileRecord plus the metadata
/// snapshot to write.
struct SeratoPendingFileTagWrite: Sendable, Equatable {
    let absolutePath: String
    let metadata: SeratoMetadata
    /// Year to write into the audio file's tags. Lives here rather than
    /// on `SeratoMetadata` because Serato's `database V2` has no year
    /// field — only the file-tag path carries it. `nil` for callers
    /// that don't set a year (e.g. `writeFileTags`).
    let year: Int?
    /// Remove the file's year/date frame instead of writing a value.
    /// Used by MusicBrainz undo when the match added a year to a file
    /// that had none: `year: nil` alone would leave the added value in
    /// place (nil = leave-unchanged), so the clear must be explicit.
    let clearYear: Bool

    init(absolutePath: String, metadata: SeratoMetadata, year: Int? = nil, clearYear: Bool = false) {
        self.absolutePath = absolutePath
        self.metadata = metadata
        self.year = year
        self.clearYear = clearYear
    }
}

/// A Serato-side rewrite scheduled by `renameFile`. Carries absolute
/// paths; the rename application converts them to the Serato-relative
/// form (`/Users/x/Music/...` → `Users/x/Music/...`) before calling
/// the FFI rewrite functions.
struct SeratoPendingRename: Sendable, Equatable {
    let oldAbsolutePath: String
    let newAbsolutePath: String
}

/// A Serato-side metadata update scheduled by
/// `commitMetadataToSerato`. Carries the absolute path of the file
/// and the new metadata to write into Serato's `database V2`.
struct SeratoPendingMetadataUpdate: Sendable, Equatable {
    let absolutePath: String
    let metadata: SeratoMetadata
}

/// A Serato-side track-insert scheduled by `addTrackToSerato`.
/// Carries the file's absolute path plus the metadata to embed in
/// the new otrk entry.
struct SeratoPendingAddTrack: Sendable, Equatable {
    let absolutePath: String
    let metadata: SeratoMetadata
}

// MARK: - Errors

public enum OperationEngineError: LocalizedError, Equatable {
    case fileNotFound(fileId: Int64)
    case insertDidNotReturnRowId
    case payloadEncodingFailed
    case eventPayloadDecodingFailed(eventId: Int64?, batchId: String, eventType: EventType, underlying: String)
    case seratoEnumerationFailed(directory: String, underlying: String)
    case seratoRewriteFailed(path: String, underlying: String)
    case fileTagWriteFailed(path: String, underlying: String)
    case trashFailed(path: String, underlying: String)
    case batchNotFound(batchId: String)
    case undoNotSupported(eventType: EventType)
    case missingPreviousTrackIdentifiers(fileId: Int64)
    /// A 120s-capped Chromaprint fingerprint collided across two DIFFERENT
    /// recordings: an existing `tracks` row for this fingerprint already
    /// carries a non-nil recording MBID that other files depend on, and the
    /// incoming match names a different recording. Rejected so the existing
    /// canonical identity and its file links stay intact (finding D-C,
    /// invariant #4).
    case fingerprintRecordingConflict(fileId: Int64, existingMBID: String, incomingMBID: String)
    /// Undo of a MusicBrainz match was refused because a LATER batch
    /// re-matched (or separately reverted) the same file — to any recording or
    /// release. Reverting the older match now would unlink the file from its
    /// current match and overwrite its DB metadata + on-disk tags. The user
    /// must undo the newer match first (LIFO), so this is surfaced loudly
    /// rather than silently corrupting the current state (findings #3999114450,
    /// #3999974010). Detected from the event log in `undoBatch`.
    case undoSupersededByLaterMatch(fileId: Int64)
    /// The DB transaction committed (the batch IS applied and
    /// journaled) but one or more external Serato/audio-tag writes
    /// threw afterward. Distinct from a pre-commit throw so the caller
    /// treats the batch as applied and finishes the external side via
    /// `resyncSeratoForBatch(batchId)` — never a re-`applyBatch`, which
    /// would double-journal (issue #836, invariant #2).
    case externalSyncIncomplete(batchId: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let fileId):
            return "Mutation referenced file id \(fileId), which is not in the database."
        case .insertDidNotReturnRowId:
            return "Database insert did not produce a row id — schema or driver invariant broken."
        case let .eventPayloadDecodingFailed(eventId, batchId, eventType, underlying):
            return "Cannot decode event \(eventId.map(String.init) ?? "unknown") (\(eventType.rawValue)) in batch \(batchId): \(underlying)"
        case .payloadEncodingFailed:
            return "Could not encode mutation payload as UTF-8 JSON."
        case .seratoEnumerationFailed(let directory, let underlying):
            return "Failed to enumerate Serato crate files in \(directory): \(underlying)"
        case .seratoRewriteFailed(let path, let underlying):
            return "Failed to rewrite Serato library file \(path): \(underlying)"
        case .fileTagWriteFailed(let path, let underlying):
            return "Failed to write audio tags to \(path): \(underlying)"
        case .trashFailed(let path, let underlying):
            return "Failed to move \(path) to Trash: \(underlying)"
        case .batchNotFound(let batchId):
            return "No events were found for batch \(batchId); nothing to undo."
        case .undoNotSupported(let eventType):
            return "Events of type \(eventType.rawValue) can't be undone yet."
        case .missingPreviousTrackIdentifiers(let fileId):
            return "Cannot revert MusicBrainz match for file id \(fileId): the pre-existing track row has no previous identifiers snapshot to restore."
        case .fingerprintRecordingConflict(let fileId, let existingMBID, let incomingMBID):
            return "Fingerprint collision for file id \(fileId): its fingerprint already identifies recording \(existingMBID), which other files depend on, but this match names \(incomingMBID). Refusing to overwrite the shared identity."
        case .undoSupersededByLaterMatch(let fileId):
            return "Can't undo this MusicBrainz match for file id \(fileId): a later match replaced it. Undo the newer match first."
        case .externalSyncIncomplete(let batchId, let underlying):
            return "Batch \(batchId) was applied, but some Serato/file writes did not land: \(underlying). Re-sync the batch to finish applying them."
        }
    }
}
