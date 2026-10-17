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

    /// Injectable audio-file tag reader, the read half of the same boundary:
    /// a test that fakes the writer fakes the reader to match it.
    public typealias FileTagReader = @Sendable (String) throws -> AudioTags

    /// Injectable database-V2 metadata batch writer. Production wires
    /// in the Rust `batchUpdateDatabaseRecords` FFI (one file read +
    /// one file write covering every track in the batch); tests inject
    /// a counter to assert that an N-row apply coalesces into ONE V2
    /// rewrite rather than N (issue C2b / #3998713590). Returns the
    /// number of otrks actually changed and the paths no record matched.
    public typealias SeratoMetadataBatchWriter =
        @Sendable (_ databasePath: String, _ updates: [SeratoTrackMetadataUpdate]) throws -> SeratoBatchWriteResult

    /// Injectable database-V2 add writer. Production wires in the Rust
    /// `batchAddTracksToDatabase` FFI, which registers every queued
    /// import in one read + write of the library. Returns the number
    /// of otrks appended.
    public typealias SeratoAddTrackBatchWriter =
        @Sendable (_ databasePath: String, _ additions: [SeratoTrackAddition]) throws -> UInt32

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
    private let fileTagReader: FileTagReader
    private let seratoMetadataBatchWriter: SeratoMetadataBatchWriter
    private let seratoAddTrackBatchWriter: SeratoAddTrackBatchWriter
    private let fileTrasher: FileTrasher
    private let activityLog: ActivityLog?
    private let mutationContext: MutationContext

    /// Queued Serato writes live in `serato_write_queue`; these are only the
    /// process-local guards around it. A claimed row is being processed by a
    /// pass and must not be processed again, or overtaken by a dependent row,
    /// until that pass releases it.
    private var claimedQueueIDs: [Int64: UUID] = [:]
    /// Per queue row, how far the current attempt's external writes got.
    private var attemptIO: [Int64: AttemptIOStage] = [:]
    private var duplicateCleanupResults: [Int64: DuplicateCleanupResult] = [:]
    private var isDraining = false
    /// One pass over queued rows runs at a time. A scoped pass leaves a row
    /// that depends on another pass's unfinished row for a later drain, and
    /// with Serato closed and readiness open no drain comes until the next
    /// sync, so overlapping passes would strand it (#117).
    private var externalPassActive = false
    private var externalPassWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set inside a pass, so a pass started from within one (a cleanup step
    /// a drain advances) runs as part of it instead of waiting for it.
    @TaskLocal private static var runsInsideExternalPass = false

    private enum ExternalWriteInterruption: Error {
        case deferred
        case superseded(Set<Int64>)
        case stale(Set<Int64>)
        case conflicted(Set<Int64>)
    }

    private enum DuplicateCleanupInterruption: Error {
        case alreadyPending
    }

    struct MutationContext: Sendable {
        let readiness: LibrarySyncReadiness?
        let locator: SeratoLibraryLocator
        var cleanupTargetFileID: Int64?
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

    /// Observable count of rows in the durable Serato write queue. Emits
    /// after every enqueue and drain step. UI subscribers (e.g., the menu
    /// bar status item) display "N changes pending."
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
        fileTagReader: @escaping FileTagReader = { path in try readAudioTags(filePath: path) },
        seratoMetadataBatchWriter: @escaping SeratoMetadataBatchWriter = { databasePath, updates in
            try batchUpdateDatabaseRecords(databasePath: databasePath, updates: updates)
        },
        seratoAddTrackBatchWriter: @escaping SeratoAddTrackBatchWriter = { databasePath, additions in
            try batchAddTracksToDatabase(databasePath: databasePath, additions: additions)
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
        self.fileTagReader = fileTagReader
        self.seratoMetadataBatchWriter = seratoMetadataBatchWriter
        self.seratoAddTrackBatchWriter = seratoAddTrackBatchWriter
        self.fileTrasher = fileTrasher
        self.activityLog = activityLog
        mutationContext = MutationContext(readiness: readiness, locator: seratoLocator)
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
        let context = mutationContext
        let executionResult: GuardedExecutionResult = try await PhysicalFileMoveTransaction.write(to: database.writer, batchId: batchId) { db, moves in
            try authorization?.check()
            let result = try Self.executeAndLog(context: context, mutation: mutation, batchId: batchId, in: db, physicalMoves: moves)
            try authorization?.check()
            return result
        }

        try await routeSeratoWrites(executionResult.seratoWrites, batchId: batchId)

        return executionResult.eventId
    }

    @discardableResult
    public func apply(_ mutation: TrackMutation, expectedMembershipToken: FileMembershipToken, batchId: String = UUID().uuidString) async throws -> Int64? {
        let authorization = try readinessAuthorization(for: [mutation])
        let context = mutationContext
        let result = try await PhysicalFileMoveTransaction.write(to: database.writer, batchId: batchId) { database, moves in
            try authorization?.check()
            try Self.requireCurrentToken(expectedMembershipToken, mutation: mutation, in: database)
            let result = try Self.executeAndLog(context: context, mutation: mutation, batchId: batchId, in: database, physicalMoves: moves)
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
        try readiness?.requireUnconflicted(.file(target))
        try readiness?.requireUnconflicted(.file(keeper))
        let intent = try PendingDuplicateCleanup(target: FileActionAuthority(target), keeper: FileActionAuthority(keeper), batchID: batchID)
        let fileID = intent.target.token.fileId
        let existing = try await database.writer.read { database in
            try DuplicateCleanupStore.fetch(targetFileID: fileID, in: database)
        }
        if let existing {
            return existing.failure.map(DuplicateCleanupResult.failed) ?? duplicateCleanupResults[fileID] ?? .pending
        }
        try await database.writer.read { database in
            try intent.target.validate(in: database)
            try intent.keeper.validate(in: database)
        }
        duplicateCleanupResults[fileID] = .pending
        await advanceDuplicateCleanup(fileID, starting: intent)
        return duplicateCleanupResults[fileID] ?? .failed("Cleanup lost its completion state.")
    }

    /// Runs cleanup steps until one waits on queued external work, fails, or the
    /// final step's transaction removes the intent. Each step's mutation,
    /// queued effects, and intent update commit together.
    private func advanceDuplicateCleanup(_ fileID: Int64, starting initial: PendingDuplicateCleanup? = nil) async {
        var unsaved = initial
        while true {
            let intent: PendingDuplicateCleanup
            let isNew = unsaved != nil
            do {
                if let unsaved {
                    intent = unsaved
                } else {
                    guard let stored = try await database.writer.read({ database in try DuplicateCleanupStore.fetch(targetFileID: fileID, in: database) }) else {
                        await finishDuplicateCleanupIfCompleted(fileID)
                        return
                    }
                    intent = stored
                }
            } catch {
                duplicateCleanupResults[fileID] = .failed(error.localizedDescription)
                await note("Duplicate cleanup state for file \(fileID) is unreadable: \(error.localizedDescription)")
                return
            }
            unsaved = nil
            guard intent.waitingEventID == nil, intent.failure == nil else {
                if let failure = intent.failure {
                    duplicateCleanupResults[fileID] = .failed(failure)
                }
                return
            }
            do {
                let mutation = intent.mutations[intent.step]
                let drain = LibrarySyncReadiness.drainAuthorization
                let authorization = drain == nil ? try readiness?.capture() : nil
                let readiness = readiness
                var stepContext = mutationContext
                stepContext.cleanupTargetFileID = fileID
                let context = stepContext
                let result = try await database.writer.write { database in
                    try authorization?.check()
                    if drain != nil, readiness?.permitsExternalWrites(drain: drain) == false {
                        throw LibrarySyncReadinessError.synchronizationRequired
                    }
                    if isNew, try DuplicateCleanupStore.fetch(targetFileID: fileID, in: database) != nil {
                        throw DuplicateCleanupInterruption.alreadyPending
                    }
                    try intent.target.validate(in: database, audioWasTrashed: intent.step == 3)
                    try intent.keeper.validate(in: database)
                    try readiness?.requireUnconflicted(SeratoConflictTargets.identity(intent.keeper.identity))
                    let result = try Self.executeAndLog(context: context, mutation: mutation, batchId: intent.batchID, in: database)
                    try readiness?.requireUnconflicted(SeratoConflictTargets.identity(intent.keeper.identity))
                    try authorization?.check()
                    var advanced = intent
                    if let eventID = result.eventId, !result.seratoWrites.isEmpty {
                        advanced.waitingEventID = eventID
                    } else {
                        advanced.step += 1
                    }
                    if advanced.step == advanced.mutations.count {
                        try DuplicateCleanupStore.delete(targetFileID: fileID, in: database)
                    } else {
                        try DuplicateCleanupStore.save(advanced, in: database)
                    }
                    return result
                }
                let outcome: ResyncOutcome
                do {
                    outcome = try await routeSeratoWrites(result.seratoWrites, batchId: intent.batchID)
                } catch {
                    let message = Self.duplicateCleanupFailureMessage(intent, error: error)
                    duplicateCleanupResults[fileID] = .failed(message)
                    await note(message)
                    return
                }
                if outcome.supersededCount > 0 {
                    throw FileProcessingEligibilityError.superseded(fileId: fileID)
                }
                if outcome.queuedCount > 0 {
                    duplicateCleanupResults[fileID] = .pending
                    await note("Duplicate cleanup for \((intent.target.identity.path as NSString).lastPathComponent) is pending; its file row is retained until all external steps finish.")
                    return
                }
            } catch is SeratoPathConflictError {
                if isNew {
                    do { try await database.writer.write { database in try DuplicateCleanupStore.save(intent, in: database) } }
                    catch {
                        duplicateCleanupResults[fileID] = .failed(error.localizedDescription)
                        return
                    }
                }
                duplicateCleanupResults[fileID] = .pending
                return
            } catch DuplicateCleanupInterruption.alreadyPending {
                return
            } catch {
                let message = error.localizedDescription
                let result: DuplicateCleanupResult = error is FileProcessingEligibilityError ? .superseded(message) : .failed(message)
                do { try await cancelDuplicateCleanup(fileID, result: result) }
                catch { duplicateCleanupResults[fileID] = .failed(error.localizedDescription) }
                await note("Duplicate cleanup stopped for file \(fileID): \(message)")
                return
            }
        }
    }

    private func finishDuplicateCleanupIfCompleted(_ fileID: Int64) async {
        guard duplicateCleanupResults[fileID] == .pending else { return }
        duplicateCleanupResults[fileID] = .completed
        await note("Duplicate cleanup completed for file \(fileID).")
    }

    /// Cancels the cleanup and every queued effect it still owns in one
    /// transaction, recording each dropped effect.
    private func cancelDuplicateCleanup(_ fileID: Int64, result: DuplicateCleanupResult, reported explicitReported: Bool? = nil) async throws {
        let reported = explicitReported ?? (LibrarySyncReadiness.drainAuthorization == nil)
        try await database.writer.write { database in
            for write in try SeratoWriteQueue.fetch(cleanupTargetFileID: fileID, in: database) {
                try Self.dropQueuedWrite(write, disposition: .superseded, reported: reported, in: database)
            }
            try DuplicateCleanupStore.delete(targetFileID: fileID, in: database)
        }
        duplicateCleanupResults[fileID] = result
        try await refreshQueueDepth()
    }

    private static func duplicateCleanupFailureMessage(_ intent: PendingDuplicateCleanup, error: Error) -> String {
        "Cleanup stopped at step \(intent.step + 1) for \((intent.target.identity.path as NSString).lastPathComponent): \(error.localizedDescription). Fix the cause, then choose Retry Sync."
    }

    func pendingCleanupOwnsRemoval(of file: FileRecord) async throws -> Bool {
        guard let fileID = file.id,
              let intent = try await database.writer.read({ database in try DuplicateCleanupStore.fetch(targetFileID: fileID, in: database) }),
              intent.removedV2 else { return false }
        do {
            try await database.writer.read { database in
                try intent.target.validate(in: database)
                try intent.keeper.validate(in: database)
            }
            return true
        } catch is FileProcessingEligibilityError {
            try await cancelDuplicateCleanup(fileID, result: .superseded("Duplicate cleanup was superseded by a changed keeper or target."), reported: false)
            return false
        }
    }

    func supersedeReappearedCleanup(fileID: Int64) async throws {
        try await cancelDuplicateCleanup(fileID, result: .superseded("Duplicate cleanup was superseded because Serato re-added the file after removal."), reported: false)
    }

    var duplicateCleanupMessage: String? {
        get async throws {
            let intents = try await database.writer.read { database in try DuplicateCleanupStore.fetchAll(in: database) }
            var results = duplicateCleanupResults
            for (fileID, result) in results where result == .pending && !intents.contains(where: { intent in intent.target.token.fileId == fileID }) {
                results[fileID] = .completed
            }
            for intent in intents {
                results[intent.target.token.fileId] = intent.failure.map(DuplicateCleanupResult.failed) ?? .pending
            }
            guard !results.isEmpty else { return nil }
            let values = Array(results.values)
            let completed = values.filter { value in value == .completed }.count
            let pending = values.filter { value in value == .pending }.count
            let failed = values.filter { value in
                if case .failed = value {
                    true
                } else {
                    false
                }
            }.count
            let superseded = values.count - completed - pending - failed
            return "Duplicate cleanup: \(completed) completed · \(pending) pending · \(failed) failed · \(superseded) superseded (see activity log)"
        }
    }

    var failedDuplicateCleanupMessage: String? {
        get async throws {
            try await database.writer.read { database in
                try DuplicateCleanupStore.fetchAll(in: database).compactMap(\.failure).first
            }
        }
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
    ///
    /// `expectedMetadata` rejects the batch with `metadataChanged` when a
    /// row's metadata no longer matches the snapshot the caller derived
    /// its values from.
    ///
    /// `authorizingMembershipTokens` names files no mutation acts on whose
    /// selection still authorizes the batch (a family change acting on
    /// selected rows); each must be current inside the transaction.
    @discardableResult
    public func applyBatch(
        _ mutations: [TrackMutation],
        batchId: String,
        expectedMembershipTokens: [Int64: FileMembershipToken]? = nil,
        authorizingMembershipTokens: [FileMembershipToken] = [],
        expectedMetadata: [Int64: SeratoMetadata] = [:]
    ) async throws -> [Int64] {
        try await executeBatch(mutations, batchId: batchId, expectedMembershipTokens: expectedMembershipTokens,
                               authorizingMembershipTokens: authorizingMembershipTokens, expectedMetadata: expectedMetadata)
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

    func captureConflictScope() -> LibrarySyncReadiness.ScopeAuthorization? {
        readiness?.captureScope()
    }

    func installDirectConflictAnalysis(_ analysis: SeratoConflictAnalysis, authorization: LibrarySyncReadiness.ScopeAuthorization?) throws {
        if let authorization {
            try readiness?.installDirectObservation(analysis.scope, authorization: authorization)
        }
    }

    func conflictPath(for target: SeratoConflictTarget) -> String? {
        readiness?.conflictPath(for: target)
    }

    func requireUnconflicted(_ target: SeratoConflictTarget) throws {
        try readiness?.requireUnconflicted(target)
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
                              authorizingMembershipTokens: [FileMembershipToken] = [],
                              expectedMetadata: [Int64: SeratoMetadata] = [:],
                              filesystemObservation: Bool = false,
                              moveExpectation: FilesystemMoveExpectation? = nil) async throws -> [Int64]
    {
        guard !mutations.isEmpty else { return [] }
        let scopeAuthorization = readiness?.captureScope()
        let authorization = filesystemObservation ? nil : try readinessAuthorization(for: mutations)
        let context = mutationContext
        let executionResults: [GuardedExecutionResult] = try await PhysicalFileMoveTransaction.write(to: database.writer, batchId: batchId) { db, moves in
            try authorization?.check()
            try scopeAuthorization?.check()
            try moveExpectation?.validate(in: db)
            for (fileID, metadata) in expectedMetadata {
                guard try FileRecord.fetchOne(db, key: fileID)?.seratoMetadata == metadata else {
                    throw OperationEngineError.metadataChanged(fileId: fileID)
                }
            }
            for token in authorizingMembershipTokens {
                guard try FileRecord.fetchOne(db, key: token.fileId)?.membershipRevision == token.revision else {
                    throw FileProcessingEligibilityError.superseded(fileId: token.fileId)
                }
            }
            let results = try mutations.map { mutation in
                if let expectedMembershipTokens, let fileID = mutation.tokenFileID {
                    guard let token = expectedMembershipTokens[fileID] else {
                        throw FileProcessingEligibilityError.superseded(fileId: fileID)
                    }
                    try Self.requireCurrentToken(token, mutation: mutation, in: db)
                }
                return try Self.executeAndLog(context: context, mutation: mutation, batchId: batchId, in: db, physicalMoves: moves)
            }
            try moveExpectation?.validatePhysicalTargets()
            try authorization?.check()
            try scopeAuthorization?.check()
            return results
        }

        let pendingWrites = executionResults.flatMap(\.seratoWrites)
        try await routeSeratoWrites(pendingWrites, batchId: batchId)

        return executionResults.compactMap(\.eventId)
    }

    func organizeFiles(_ plans: [LibraryOrganizer.Plan], batchId: String) async throws -> LibraryOrganizer.Outcome {
        let requests = plans.map { plan in
            PhysicalMoveRequest(token: FileMembershipToken(fileId: plan.id, revision: plan.membershipRevision),
                                sourcePath: plan.sourcePath, destinationPath: plan.destinationPath, sourceIdentity: nil,
                                organizeRequirements: plan.metadataRequirements)
        }
        let result = try await moveFiles(requests, batchId: batchId)
        return LibraryOrganizer.Outcome(batchId: batchId, movedCount: result.movedCount, failureCount: result.errors.count, errors: result.errors)
    }

    func migrateFiles(_ plans: [LibraryMigrator.Plan], batchId: String) async throws -> LibraryMigrator.Outcome {
        let requests = plans.map { plan in
            PhysicalMoveRequest(token: plan.membershipToken, sourcePath: plan.sourcePath,
                                destinationPath: plan.destinationPath, sourceIdentity: plan.sourceIdentity, organizeRequirements: nil)
        }
        let result = try await moveFiles(requests, batchId: batchId)
        return LibraryMigrator.Outcome(batchId: batchId, movedCount: result.movedCount, failureCount: result.errors.count, errors: result.errors)
    }

    private struct PhysicalMoveRequest: Sendable {
        let token: FileMembershipToken
        let sourcePath: String
        let destinationPath: String
        let sourceIdentity: SeratoSourceIdentity?
        let organizeRequirements: OrganizeMetadataRequirements?
    }

    private func moveFiles(_ plans: [PhysicalMoveRequest], batchId: String) async throws -> (movedCount: Int, errors: [String]) {
        let authorization = try readiness?.capture()
        let context = mutationContext
        var results: [GuardedExecutionResult] = []
        var errors: [String] = []
        for plan in plans {
            do {
                let result = try await PhysicalFileMoveTransaction.write(to: database.writer, batchId: batchId) { database, moves in
                    try authorization?.check()
                    try FileProcessingEligibility.requireCurrent(plan.token, in: database)
                    if let requirements = plan.organizeRequirements {
                        guard let file = try FileRecord.fetchOne(database, key: plan.token.fileId) else {
                            throw FileProcessingEligibilityError.superseded(fileId: plan.token.fileId)
                        }
                        try requirements.validate(file)
                    }
                    let result = try Self.executeAndLog(context: context, mutation: .renameFile(.init(fileId: plan.token.fileId, newPath: plan.destinationPath,
                                                                                                      previousPath: plan.sourcePath, physicalMove: true)), batchId: batchId, in: database,
                                                        physicalMoves: moves, expectedPhysicalSource: plan.sourceIdentity)
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
        return (results.count, errors)
    }

    func applyObservedBatch(_ mutations: [TrackMutation], authorization: SeratoSnapshotAuthorization,
                            expectedFiles: [FileObservationExpectation] = [], batchId: String = UUID().uuidString) async throws -> [Int64]
    {
        let context = mutationContext
        return try await observedTransaction(authorization: authorization, expectedFiles: expectedFiles) { connection in
            let results = try mutations.map { mutation in
                try Self.validateObservedIdentity(mutation, in: connection)
                let result = try Self.executeAndLog(context: context, mutation: mutation, batchId: batchId, in: connection)
                guard result.seratoWrites.isEmpty else { throw SeratoMembershipSnapshotError.unsupportedSource }
                return result
            }
            return results.compactMap(\.eventId)
        }
    }

    private func observedTransaction<Result: Sendable>(authorization: SeratoSnapshotAuthorization, expectedFiles: [FileObservationExpectation],
                                                       _ body: @escaping @Sendable (GRDB.Database) throws -> Result) async throws -> Result
    {
        let scopeAuthorization = readiness?.captureScope()
        let metrics = LibrarySyncMetrics.current
        let accounting = SyncRevisionAccounting.current
        return try await database.writer.write { connection in
            try LibrarySyncMetrics.$current.withValue(metrics) {
                try authorization.check()
                try scopeAuthorization?.check()
                for expected in expectedFiles {
                    try expected.validate(in: connection)
                }
                let revisionBefore = try SyncCheckpointStore.revision(in: connection)
                try accounting?.validate(revisionBefore)
                let result = try body(connection)
                try authorization.check()
                try scopeAuthorization?.check()
                let revisionAfter = try SyncCheckpointStore.revision(in: connection)
                accounting?.record(revisionAfter - revisionBefore)
                metrics?.record(.rowWrite, count: Int(revisionAfter - revisionBefore))
                return result
            }
        }
    }

    /// Journals a strict observation and reduces the file's queued V2 intent
    /// against it in one transaction, so a crash cannot leave a queued write
    /// that the observation already superseded, or a baseline that disagrees
    /// with the journal.
    func observeSnapshotMetadata(_ payload: ObserveFileIdentityPayload, authorization: SeratoSnapshotAuthorization,
                                 metadataEvidence: AudioFileReadIdentity? = nil, expectedMetadata: SeratoMetadata? = nil) async throws -> [Int64]
    {
        guard let observed = payload.metadata else { throw SeratoMembershipSnapshotError.unsupportedSource }
        if metadataEvidence != nil, expectedMetadata == nil {
            throw SyncCheckpointError.malformed
        }
        let token = FileMembershipToken(fileId: payload.fileId, revision: payload.expectedRevision)
        guard let current = try await database.writer.read({ connection in try FileRecord.fetchOne(connection, key: payload.fileId) }) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        let context = mutationContext
        let batchID = UUID().uuidString
        let (events, conflicts, queueChanged) = try await observedTransaction(authorization: authorization, expectedFiles: [FileObservationExpectation(file: current)]) { connection in
            let baseline = try SeratoExternalBaselines.load(token: token, identity: current.identity, locator: context.locator, in: connection)
            let queued = try SeratoWriteQueue.fetch(fileID: token.fileId, in: connection).filter { write in write.token == token }
            let reduction = Self.reduceQueuedMetadata(queued, observed: observed, baseline: baseline, local: current.seratoMetadata)
            var observation = payload
            observation.metadata = reduction.overlay
            observation.observedMetadata = observed
            observation.previousObservedMetadata = reduction.journaledBaseline
            observation.uncertainV2Fields = reduction.uncertainFields.isEmpty ? nil : reduction.uncertainFields.sorted()
            let mutation: TrackMutation = if let metadataEvidence, let expectedMetadata {
                .observeFileMetadata(.init(observation: observation, evidence: metadataEvidence, expectedMetadata: expectedMetadata))
            } else {
                .observeFileIdentity(observation)
            }
            let result = try Self.executeAndLog(context: context, mutation: mutation, batchId: batchID, in: connection)
            for replacement in reduction.replacements {
                if let kept = replacement.kept {
                    _ = try SeratoWriteQueue.replace(kept, in: connection)
                } else if !replacement.conflicted {
                    _ = try SeratoWriteQueue.delete(replacement.original, in: connection)
                } else {
                    try Self.dropQueuedWrite(replacement.original, disposition: replacement.uncertain ? .uncertain : .superseded,
                                             detail: "Saved Serato fields changed while this change was queued.", reported: false, in: connection)
                }
                if replacement.conflicted, replacement.kept != nil {
                    try SeratoWriteDispositions.record(eventID: replacement.original.eventId, kind: .metadataUpdate,
                                                       disposition: replacement.uncertain ? .uncertain : .superseded,
                                                       detail: "Some queued fields were superseded by saved Serato fields.", reported: false, in: connection)
                }
            }
            try SeratoExternalBaselines.save(observed, token: token, in: connection)
            return (result.eventId.map { eventID in [eventID] } ?? [], reduction.replacements.filter(\.conflicted).count, !reduction.replacements.isEmpty)
        }
        if queueChanged {
            try await refreshQueueDepth()
        }
        if conflicts > 0 {
            await note("Queued metadata for \((payload.identity.path as NSString).lastPathComponent) was superseded in \(conflicts) change(s): saved Serato fields changed or their original external baseline is unknown. Other fields remain queued.")
        }
        return events
    }

    private struct QueuedMetadataReplacement {
        let original: GuardedSeratoWrite
        let kept: GuardedSeratoWrite?
        let conflicted: Bool
        let uncertain: Bool
    }

    private struct QueuedMetadataReduction {
        var overlay: SeratoMetadata
        var journaledBaseline: SeratoMetadata?
        var uncertainFields = Set<String>()
        var replacements: [QueuedMetadataReplacement] = []
    }

    /// A queued V2 field survives when Serato still holds its captured baseline
    /// value, or already holds the queued value. The latter is this engine's own
    /// write landing before its row was cleared, so it advances the journaled
    /// baseline instead of claiming new external ownership.
    private static func reduceQueuedMetadata(_ queued: [GuardedSeratoWrite], observed: SeratoMetadata,
                                             baseline: SeratoMetadata?, local: SeratoMetadata) -> QueuedMetadataReduction
    {
        let savedFields = metadataFieldMap(observed)
        var overlay = observed
        if let baseline {
            overlay = merging(changedMetadataFields(observed, previous: baseline), from: observed, into: local)
        }
        var reduction = QueuedMetadataReduction(overlay: overlay, journaledBaseline: baseline)
        var ownWrittenFields = Set<String>()
        var earlierIntended: [String: Set<String?>] = [:]
        // Only a row whose I/O may have landed can explain a saved value; any
        // other row's value in Serato is an external edit that happens to match it.
        let intents: [[String: String?]] = queued.map { guarded in
            guard guarded.mayHaveLanded, case let .metadataUpdate(update) = guarded.write else { return [:] }
            return metadataFieldMap(update.metadata).mapValues { value in value.isEmpty ? nil : value }
        }
        for (position, guarded) in queued.enumerated() {
            guard case let .metadataUpdate(update) = guarded.write else { continue }
            let laterIntended = intents[(position + 1)...].reduce(into: [String: Set<String?>]()) { later, intent in
                for (field, value) in intent {
                    later[field, default: []].insert(value)
                }
            }
            var covered = Set<String>()
            let rowBaseline = guarded.externalBaseline.map(metadataFieldMap)
            let desired = metadataFieldMap(update.metadata)
            var permitted = Set<String>()
            let knownFields = Set(desired.keys).filter { field in guarded.knowsBaseline(of: field) }
            for field in desired.keys {
                let saved = savedFields[field].flatMap { value in value.isEmpty ? nil : value }
                let prior = rowBaseline?[field].flatMap { value in value.isEmpty ? nil : value }
                let intended = desired[field].flatMap { value in value.isEmpty ? nil : value }
                if saved == intended {
                    permitted.insert(field)
                    ownWrittenFields.insert(field)
                } else if earlierIntended[field]?.contains(saved) == true {
                    // An earlier queued edit of ours landed but its row was not
                    // cleared; its value is what this later edit replaces.
                    permitted.insert(field)
                    ownWrittenFields.insert(field)
                } else if knownFields.contains(field), saved == prior {
                    permitted.insert(field)
                } else if laterIntended[field]?.contains(saved) == true {
                    // A later queued edit of ours already landed with this one
                    // (one coalesced rewrite), so this field has nothing left to do.
                    covered.insert(field)
                    ownWrittenFields.insert(field)
                }
            }
            for (field, value) in intents[position] {
                earlierIntended[field, default: []].insert(value)
            }
            let dropped = Set(desired.keys).subtracting(permitted).subtracting(covered)
            reduction.uncertainFields.formUnion(dropped.subtracting(knownFields))
            let kept = reducedMetadata(update.metadata, keeping: permitted)
            reduction.overlay = kept.overlaid(on: reduction.overlay)
            var replacement = guarded
            replacement.write = .metadataUpdate(.init(absolutePath: update.absolutePath, metadata: kept))
            replacement.externalBaseline = observed
            replacement.baselineKnownFields = nil
            reduction.replacements.append(QueuedMetadataReplacement(original: guarded, kept: permitted.isEmpty ? nil : replacement,
                                                                    conflicted: !dropped.isEmpty, uncertain: !dropped.isEmpty && dropped.isDisjoint(with: knownFields)))
        }
        if let baseline {
            reduction.journaledBaseline = merging(ownWrittenFields, from: observed, into: baseline)
        }
        return reduction
    }

    /// `base` with the named fields copied from `source`, including absent values.
    static func merging(_ fields: Set<String>, from source: SeratoMetadata, into base: SeratoMetadata) -> SeratoMetadata {
        SeratoMetadata(artist: fields.contains("artist") ? source.artist : base.artist,
                       title: fields.contains("title") ? source.title : base.title,
                       album: fields.contains("album") ? source.album : base.album,
                       genre: fields.contains("genre") ? source.genre : base.genre,
                       bpm: fields.contains("bpm") ? source.bpm : base.bpm,
                       musicalKey: fields.contains("key") ? source.musicalKey : base.musicalKey,
                       comment: fields.contains("comment") ? source.comment : base.comment,
                       length: fields.contains("length") ? source.length : base.length,
                       label: fields.contains("label") ? source.label : base.label)
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

    /// Process a committed batch's queued Serato-side writes: leave them
    /// queued if Serato is running (they drain on Serato exit — invariant
    /// #3), otherwise apply them now (coalesced — see
    /// `applyConsecutiveSeratoWrites`).
    ///
    /// The DB transaction has ALREADY committed by the time this runs:
    /// the mutations ARE applied and journaled, and their effects are rows
    /// in `serato_write_queue`. The SQLite commit and the external file
    /// writes are physically separate and cannot join one transaction, so a
    /// post-commit external-write failure can never mean "nothing
    /// happened." It is surfaced as a DISTINCT typed error —
    /// `.externalSyncIncomplete`, carrying the batchId — and the failed rows
    /// stay queued with their error for Retry Sync or
    /// `resyncSeratoForBatch(batchId)`, NEVER a re-`applyBatch` (which would
    /// re-journal against the already-mutated rows and corrupt the undo
    /// baseline — invariant #2, issue #836).
    @discardableResult
    private func routeSeratoWrites(
        _ writes: [GuardedSeratoWrite],
        batchId: String
    ) async throws -> ResyncOutcome {
        guard !writes.isEmpty else { return ResyncOutcome(appliedCount: 0, queuedCount: 0) }
        let isSeratoRunning = await seratoWatchdog.isSeratoRunning
        if isSeratoRunning || readiness?.permitsExternalWrites == false {
            try await refreshQueueDepth()
            return ResyncOutcome(appliedCount: 0, queuedCount: Set(writes.map(\.eventId)).count)
        }
        do {
            let outcome = try await processScopedRows(Set(writes.compactMap(\.queueID)))
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

    /// For each file with a queued rename, the path Serato still holds its
    /// record at: the source of its oldest pending rename.
    func pendingRenameSources() async throws -> [PendingRenameSource] {
        try await database.writer.read { database in
            var sources: [Int64: PendingRenameSource] = [:]
            for write in try SeratoWriteQueue.fetchOrdered(in: database) {
                guard case let .rename(rename) = write.write, sources[write.token.fileId] == nil,
                      let file = try FileRecord.fetchOne(database, key: write.token.fileId),
                      SeratoWriteEligibility.permits(write, file: file) else { continue }
                sources[write.token.fileId] = PendingRenameSource(fileID: write.token.fileId, savedPath: rename.oldAbsolutePath, currentPath: file.path)
            }
            return sources.values.sorted { first, second in first.fileID < second.fileID }
        }
    }

    /// Whether startup must take the strict path: queued effects, unfinished
    /// cleanup, or dropped effects the user has not yet been shown.
    var hasPendingSynchronizationWork: Bool {
        get async throws {
            try await database.writer.read { database in
                try SeratoWriteQueue.count(in: database) > 0 || DuplicateCleanupStore.exists(in: database)
                    || SeratoWriteDispositions.hasUnreported(in: database)
            }
        }
    }

    /// Number of queued Serato writes, including failed ones retained for
    /// Retry Sync. Surfaced for UI ("M changes pending").
    public var pendingSeratoWriteCount: Int {
        get async throws {
            try await database.writer.read { database in try SeratoWriteQueue.count(in: database) }
        }
    }

    func refreshQueueDepth() async throws {
        let count = try await pendingSeratoWriteCount
        queueDepthSubject.send(count)
    }

    /// Counts of dropped queued effects not yet shown in a ready summary,
    /// marking them shown.
    func takeUnreportedDispositions() async throws -> SeratoWriteDispositionCounts {
        try await database.writer.write { database in try SeratoWriteDispositions.takeUnreported(in: database) }
    }

    /// Converts fences left by builds before the durable queue into queue rows.
    /// Replayable events are rebuilt from the journal against current file
    /// state; destructive effects cannot be verified after the fact, so they
    /// are recorded as unrecoverable rather than resumed.
    /// Repairs durable state an earlier process left mid-effect, before any
    /// pass reads the queue. Each damaged row or fence is isolated with a
    /// visible disposition so the rest of the queue still applies.
    func recoverInterruptedEffects() async throws {
        try await database.writer.write { database in try SeratoWriteQueue.quarantineMalformed(in: database) }
        try await recoverLegacyEffectFences()
        try await recoverInterruptedCleanupTrash()
        try await refreshQueueDepth()
    }

    private func recoverLegacyEffectFences() async throws {
        let prefix = SyncCheckpointStore.legacyEventFencePrefix
        let fences = try await database.writer.read { database in
            try String.fetchAll(database, sql: "SELECT batch_id FROM sync_effect_fences WHERE substr(batch_id, 1, ?) = ? ORDER BY batch_id",
                                arguments: [prefix.count, prefix])
        }
        let context = mutationContext
        for fence in fences {
            let eventID = Int64(fence.dropFirst(prefix.count))
            let recovery: (writes: [GuardedSeratoWrite], event: EventRecord?)
            do {
                guard let eventID else { throw SyncCheckpointError.malformed }
                let event = try await database.writer.read { database in try EventRecord.fetchOne(database, key: eventID) }
                if let event, event.eventType.hasReplayableSeratoProjection {
                    recovery = try await (reconstructResyncWrites(from: [event]).writes, event)
                } else if let event, event.eventType == .trackAddedToSerato {
                    recovery = try await (legacyImportWrite(event), event)
                } else {
                    recovery = ([], event)
                }
            } catch let error where Self.isUnreadableRecord(error) {
                try await database.writer.write { database in
                    try SeratoWriteDispositions.record(eventID: eventID ?? 0, kind: nil, disposition: .malformed,
                                                       detail: "Pre-upgrade change \(fence) was unreadable and was not applied: \(error.localizedDescription)",
                                                       reported: false, in: database)
                    try SyncCheckpointStore.finishEffect(batchID: fence, in: database)
                }
                continue
            }
            let unrecoverable = recovery.event.map { recorded in !recorded.eventType.hasReplayableSeratoProjection && recorded.eventType != .trackAddedToSerato } ?? true
            try await database.writer.write { database in
                for write in recovery.writes {
                    try SeratoWriteQueue.insert(write, locator: context.locator, ignoringExisting: true, in: database)
                }
                if recovery.writes.isEmpty, let eventID {
                    try SeratoWriteDispositions.record(eventID: eventID, kind: recovery.event.flatMap { recorded in Self.legacyWriteKind(recorded.eventType) },
                                                       disposition: unrecoverable ? .legacyUnrecoverable : .superseded,
                                                       detail: "Recovered from an interrupted pre-upgrade session.", reported: false, in: database)
                }
                try SyncCheckpointStore.finishEffect(batchID: fence, in: database)
            }
        }
    }

    /// A process that exited after Trash moved a cleanup target but before
    /// that transaction committed leaves the attempted trash row and its
    /// intent. The target is gone from its verified path, so the cleanup
    /// finishes as its trash transaction would have instead of retiring the
    /// row and reporting the cleanup superseded.
    private func recoverInterruptedCleanupTrash() async throws {
        let context = mutationContext
        let finished = try await database.writer.write { database -> [Int64] in
            var finished: [Int64] = []
            for intent in try DuplicateCleanupStore.fetchAll(in: database) {
                guard intent.step < intent.mutations.count, case .trashFile = intent.mutations[intent.step] else { continue }
                let targetID = intent.target.token.fileId
                // A missing path after a failed attempt proves nothing about this engine's Trash.
                let attempted = try SeratoWriteQueue.fetch(cleanupTargetFileID: targetID, in: database).first { write in
                    if case .trashFile = write.write {
                        write.mayHaveLanded
                    } else {
                        false
                    }
                }
                guard let attempted, case let .trashFile(trash) = attempted.write,
                      !FileManager.default.fileExists(atPath: trash.absolutePath) else { continue }
                do {
                    try intent.target.validate(in: database, audioWasTrashed: true)
                    try intent.keeper.validate(in: database)
                } catch is FileProcessingEligibilityError { continue }
                let removal = TrackMutation.removeFile(.init(fileId: targetID))
                try Self.requireCurrentToken(intent.target.token, mutation: removal, in: database)
                _ = try Self.executeAndLog(context: context, mutation: removal, batchId: intent.batchID, in: database)
                try SeratoWriteQueue.delete(attempted, in: database)
                try DuplicateCleanupStore.delete(targetFileID: targetID, in: database)
                finished.append(targetID)
            }
            return finished
        }
        for targetID in finished {
            duplicateCleanupResults[targetID] = .completed
            await note("Duplicate cleanup for file \(targetID) finished after an interrupted move to Trash.")
        }
    }

    private static func isUnreadableRecord(_ error: Error) -> Bool {
        if case OperationEngineError.eventPayloadDecodingFailed = error {
            return true
        }
        return error is DecodingError || error is SyncCheckpointError
    }

    private func legacyImportWrite(_ event: EventRecord) async throws -> [GuardedSeratoWrite] {
        let payload = try Self.decodeEventPayload(AddTrackToSeratoPayload.self, event: event, decoder: JSONDecoder())
        guard let eventID = event.eventId,
              let file = try await database.writer.read({ database in try FileRecord.fetchOne(database, key: payload.fileId) }),
              let fileID = file.id,
              file.libraryMembership == .pendingImport, file.fileAvailability == .available else { return [] }
        return [GuardedSeratoWrite(token: FileMembershipToken(fileId: fileID, revision: file.membershipRevision),
                                   write: .addTrack(.init(absolutePath: file.path, metadata: payload.metadata)),
                                   eventId: eventID, originalIdentity: file.identity)]
    }

    private static func legacyWriteKind(_ eventType: EventType) -> SeratoWriteKind? {
        switch eventType {
        case .fileRenamed: .rename
        case .musicBrainzMatchApplied, .musicBrainzMatchReverted, .metadataCommittedToSerato: .metadataUpdate
        case .fileTagsWritten: .fileTagWrite
        case .trackAddedToSerato: .addTrack
        case .trackRemovedFromSerato: .removeFromDatabase
        case .fileRemovedFromCrates: .removeFromCrates
        case .fileTrashed: .trashFile
        case .trackImported, .fileRemoved, .metadataSet, .fileLibraryStateChanged, .fileLocationObserved, .fileIdentityObserved, .fileImportRequested,
             .songFamilyCreated, .songFamilyMembersAttached, .songFamilyMembersDetached, .songFamiliesMerged,
             .songFamilySplit, .songFamilyRepresentativeChanged, .songFamilyRestored,
             .songFamilyRecordingLinked, .songFamilyRecordingUnlinked: nil
        }
    }

    // Reverse every event in `batchId` in newest-first order, applying
    // each inverse mutation under a single fresh `undo:<originalBatchId>:<uuid>`
    // batch. The new batch is itself journaled, so "undo of undo"
    // (redo) is just another `undoBatch` call against the returned id.
    //
    // Failure modes:
    // - empty batch → `batchNotFound`
    // - batch contains an event whose inverse isn't supported (today:
    //   `metadataCommittedToSerato`, `trackAddedToSerato`) →
    //   `undoNotSupported`, thrown **before** any inverse runs, so
    //   the DB stays in its pre-undo state
    // - apply-time drift (e.g. the file was removed in a later batch
    //   so renameFile can't find it) → bubbles up as `fileNotFound`
    //   with partial undo state already applied — caller can issue
    //   a follow-up undo of the partial undo batch to revert
    //
    // Returns the new batch id so the caller (UI) can offer "Undo the
    // undo" without having to scan the events table.

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
    /// Reconstructed writes join the durable queue by `(event, kind)`: a
    /// row that is still queued is already the current reconciled intent, so
    /// replay processes that row instead of adding a second copy. Only this
    /// batch's rows are processed, and an earlier queued row for the same
    /// file or path still goes first. Re-writing a tag or record that already
    /// holds the target value is a no-op (the Rust writers return 0 and skip
    /// the file write), and replay never appends to the journal.
    ///
    /// Honors the Serato-running guard exactly (invariant #3): when Serato
    /// is running the rows stay queued and drain on Serato exit. Reports
    /// applied vs queued counts (per replayed event) so the UI can tell the
    /// user whether anything actually landed on disk — "Re-sync complete"
    /// while nothing did bit a user before (issue #64).
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
        let context = mutationContext
        let queued = try await database.writer.write { database in
            try writes.map { write in try SeratoWriteQueue.insert(write, locator: context.locator, ignoringExisting: true, in: database) }
        }

        let isSeratoRunning = await seratoWatchdog.isSeratoRunning
        let outcome: ResyncOutcome
        if isSeratoRunning || readiness?.permitsExternalWrites == false {
            try await refreshQueueDepth()
            outcome = ResyncOutcome(appliedCount: 0, queuedCount: replayedEventCount, supersededCount: supersededCount)
        } else {
            let routed = try await processScopedRows(Set(queued.compactMap(\.queueID)))
            outcome = ResyncOutcome(appliedCount: routed.appliedCount, queuedCount: routed.queuedCount,
                                    supersededCount: supersededCount + routed.supersededCount, conflictBlockedCount: routed.conflictBlockedCount,
                                    missingTargetCount: routed.missingTargetCount)
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
        let pathByFileId: [Int64: String] = if pathDependentFileIds.isEmpty {
            [:]
        } else {
            filesByID.mapValues(\.path)
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
                writes.append(contentsOf: kept.map { write in GuardedSeratoWrite(token: token, write: write, eventId: eventId, originalIdentity: file.identity) })
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

    /// The V2 values the producing event recorded as current before our edit,
    /// when it recorded them.
    static func journaledV2Previous(eventID: Int64, in database: GRDB.Database) throws -> SeratoMetadata? {
        guard let event = try EventRecord.fetchOne(database, key: eventID) else { return nil }
        let decoder = JSONDecoder()
        switch event.eventType {
        case .metadataCommittedToSerato:
            return try decodeEventPayload(CommitMetadataToSeratoPayload.self, event: event, decoder: decoder).previousMetadata
        case .musicBrainzMatchApplied:
            return try decodeEventPayload(ApplyMusicBrainzMatchPayload.self, event: event, decoder: decoder).previousMetadata
        default:
            return nil
        }
    }

    /// The non-nil fields of a `SeratoMetadata`, keyed by a stable field name.
    /// An empty-string value (a clear) is a real value and IS included.
    static func metadataFieldMap(_ metadata: SeratoMetadata) -> [String: String] {
        var result: [String: String] = [:]
        if let value = metadata.artist {
            result["artist"] = value
        }
        if let value = metadata.title {
            result["title"] = value
        }
        if let value = metadata.album {
            result["album"] = value
        }
        if let value = metadata.genre {
            result["genre"] = value
        }
        if let value = metadata.bpm {
            result["bpm"] = value
        }
        if let value = metadata.musicalKey {
            result["key"] = value
        }
        if let value = metadata.comment {
            result["comment"] = value
        }
        if let value = metadata.length {
            result["length"] = value
        }
        if let value = metadata.label {
            result["label"] = value
        }
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
        case let .metadataUpdate(update):
            let latest = latestV2FieldWriter[fileId] ?? [:]
            let keep = Set(metadataFieldMap(update.metadata).keys.filter { latest[$0] == eventId })
            guard !keep.isEmpty else { return nil }
            return .metadataUpdate(SeratoPendingMetadataUpdate(
                absolutePath: update.absolutePath,
                metadata: reducedMetadata(update.metadata, keeping: keep)
            ))
        case let .fileTagWrite(tagWrite):
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
            Array(uniqueIDs[start ..< min(start + chunkSize, uniqueIDs.count)])
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
                case let .metadataUpdate(update):
                    for key in Self.metadataFieldMap(update.metadata).keys {
                        v2[fileId, default: [:]][key] = eventId
                    }
                case let .fileTagWrite(tagWrite):
                    for key in Self.metadataFieldMap(tagWrite.metadata).keys {
                        tag[fileId, default: [:]][key] = eventId
                    }
                    if tagWrite.year != nil || tagWrite.clearYear {
                        tag[fileId, default: [:]]["year"] = eventId
                    }
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
            true
        case .trackImported, .fileRemoved, .metadataSet,
             .trackAddedToSerato, .fileTrashed, .trackRemovedFromSerato,
             .fileRemovedFromCrates, .fileLibraryStateChanged, .fileLocationObserved, .fileIdentityObserved, .fileImportRequested,
             .songFamilyCreated, .songFamilyMembersAttached, .songFamilyMembersDetached, .songFamiliesMerged,
             .songFamilySplit, .songFamilyRepresentativeChanged, .songFamilyRestored,
             .songFamilyRecordingLinked, .songFamilyRecordingUnlinked:
            false
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
             .fileTrashed, .trackRemovedFromSerato, .fileRemovedFromCrates, .fileLibraryStateChanged, .fileLocationObserved, .fileIdentityObserved, .fileImportRequested,
             .songFamilyCreated, .songFamilyMembersAttached, .songFamilyMembersDetached, .songFamiliesMerged,
             .songFamilySplit, .songFamilyRepresentativeChanged, .songFamilyRestored,
             .songFamilyRecordingLinked, .songFamilyRecordingUnlinked:
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

        // Pre-decode every inverse before mutating anything. If any
        // event in the batch is non-reversible, we fail clean — no
        // partial undo state lands in the DB.
        let inverseMutations = try events.map { event in
            try Self.decodeInverseMutation(event: event)
        }

        // Ordering is checked first so a superseded match reports that, not
        // the newer match's tags; both checks run again inside the transaction.
        try await database.writer.read { database in try Self.requireNoLaterMatchSupersedes(events: events, in: database) }
        let tagReads = try await readMatchFileTags(events)
        let undoBatchId = "undo:\(batchId):\(UUID().uuidString)"
        let context = mutationContext
        // One transaction for every inverse mutation in the batch.
        // Undo is conceptually atomic: either the whole batch
        // reverts or none of it does. With N transactions (the
        // pre-batch shape) we'd risk leaving the DB half-undone if
        // one inverse hit a fileNotFound mid-loop.
        let results = try await PhysicalFileMoveTransaction.write(to: database.writer, batchId: undoBatchId) { database, moves in
            try authorization?.check()
            // Inside the transaction that applies the inverses, so an apply
            // that lands while undo is suspended cannot slip past it (#107).
            try Self.requireNoLaterMatchSupersedes(events: events, in: database)
            for read in tagReads {
                guard try FileRecord.fetchOne(database, key: read.fileID)?.path == read.path else {
                    throw FileProcessingEligibilityError.superseded(fileId: read.fileID)
                }
                try MatchUndoTagGuard.requireUnchanged(read)
            }
            // Undoing a grouping link checks that grouping still owns the link
            // and keeps it otherwise, so a retired file never blocks the undo
            // (docs/song-families.md). Its redo takes the general guard.
            for event in events where event.eventType != .songFamilyRecordingLinked {
                guard let fileID = event.fileId else { continue }
                guard let file = try FileRecord.fetchOne(database, key: fileID),
                      file.libraryMembership != .retired,
                      try SeratoWriteEligibility.replayToken(event: event, file: file) != nil
                else {
                    throw FileProcessingEligibilityError.superseded(fileId: fileID)
                }
            }
            let results = try inverseMutations.map { mutation in
                try Self.executeAndLog(context: context, mutation: mutation, batchId: undoBatchId, in: database, physicalMoves: moves)
            }
            try authorization?.check()
            return results
        }
        try await routeSeratoWrites(results.flatMap(\.seratoWrites), batchId: undoBatchId)
        return undoBatchId
    }

    /// Reads the live tags of every file whose match this undo reverses or
    /// redoes, refusing when the inverse would overwrite a later tag edit.
    private func readMatchFileTags(_ events: [EventRecord]) async throws -> [MatchUndoTagGuard.Read] {
        let decoder = JSONDecoder()
        var matches: [(fileID: Int64, direction: MatchHistoryDirection, applied: ApplyMusicBrainzMatchPayload)] = []
        for event in events {
            guard let fileID = event.fileId else { continue }
            switch event.eventType {
            case .musicBrainzMatchApplied:
                try matches.append((fileID, .undo, Self.decodeEventPayload(ApplyMusicBrainzMatchPayload.self, event: event, decoder: decoder)))
            case .musicBrainzMatchReverted:
                try matches.append((fileID, .redo, Self.decodeEventPayload(RevertMusicBrainzMatchPayload.self, event: event, decoder: decoder).applied))
            default: continue
            }
        }
        guard !matches.isEmpty else { return [] }
        let paths = try await database.writer.read { database in
            try Self.fetchFiles(fileIDs: matches.map(\.fileID), in: database).reduce(into: [Int64: String]()) { paths, file in
                if let fileID = file.id {
                    paths[fileID] = file.path
                }
            }
        }
        let requests = try matches.map { match in
            guard let path = paths[match.fileID] else { throw OperationEngineError.fileNotFound(fileId: match.fileID) }
            return MatchUndoTagGuard.Request(fileID: match.fileID, path: path, direction: match.direction, applied: match.applied)
        }
        return try await MatchUndoTagGuard.readAll(requests, reader: fileTagReader)
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
    private static func requireNoLaterMatchSupersedes(events: [EventRecord], in db: GRDB.Database) throws {
        let matchEvents = events.filter {
            $0.eventType == .musicBrainzMatchApplied || $0.eventType == .musicBrainzMatchReverted
        }
        guard !matchEvents.isEmpty else { return }
        let fileIds = Array(Set(matchEvents.compactMap(\.fileId)))
        guard !fileIds.isEmpty else { return }

        // Per-file MATCH-event history (for the LIFO stack), plus each file's
        // CURRENT row (for the value comparison), read together.
        let history = try fetchFileEvents(fileIDs: fileIds, eventTypes: [.musicBrainzMatchApplied, .musicBrainzMatchReverted], in: db)
        let currentFiles = try fetchFiles(fileIDs: fileIds, in: db).reduce(into: [Int64: FileRecord]()) { accumulator, file in
            if let id = file.id {
                accumulator[id] = file
            }
        }
        var historyByFile: [Int64: [EventRecord]] = [:]
        for event in history {
            if let fileId = event.fileId {
                historyByFile[fileId, default: []].append(event)
            }
        }
        let decoder = JSONDecoder()
        let liveMatches = MatchHistoryStacks.liveApplies(in: history) { event in event.fileId }

        for event in matchEvents {
            guard let fileId = event.fileId, let eventId = event.eventId else { continue }
            let fileHistory = historyByFile[fileId] ?? []
            if event.eventType == .musicBrainzMatchApplied {
                if liveMatches[fileId]?.last != eventId {
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
                   let file = currentFiles[fileId]
                {
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
        case .songFamilyCreated, .songFamilyMembersAttached, .songFamilyMembersDetached, .songFamiliesMerged,
             .songFamilySplit, .songFamilyRepresentativeChanged, .songFamilyRestored:
            return try .songFamily(.restore(decoder.decode(RestoreSongFamiliesPayload.self, from: inverseJsonData)))
        case .songFamilyRecordingLinked:
            return try .songFamily(.unlinkRecording(decoder.decode(SongFamilyRecordingLink.self, from: inverseJsonData)))
        case .songFamilyRecordingUnlinked:
            return try .songFamily(.relinkRecording(decoder.decode(SongFamilyRecordingLink.self, from: inverseJsonData)))
        }
    }

    /// Apply every queued Serato write. Call this when Serato has
    /// just exited (the SeratoSyncCoordinator drives this). Drains
    /// the durable queue oldest-first. A row whose I/O fails keeps its
    /// error and blocks only the rows that depend on it; independent rows
    /// still drain, and the pass then reports the failure for Retry Sync.
    @discardableResult
    public func drainPendingSeratoUpdates(retryingFailedCleanup: Bool = false) async throws -> ResyncOutcome {
        guard readiness?.permitsExternalWrites != false else { throw LibrarySyncReadinessError.synchronizationRequired }
        return try await exclusiveExternalPass { try await drainQueue(retryingFailedCleanup: retryingFailedCleanup) }
    }

    private func exclusiveExternalPass<Result: Sendable>(_ pass: () async throws -> Result) async throws -> Result {
        if Self.runsInsideExternalPass {
            return try await pass()
        }
        while externalPassActive {
            await withCheckedContinuation { continuation in externalPassWaiters.append(continuation) }
        }
        externalPassActive = true
        defer {
            externalPassActive = false
            if !externalPassWaiters.isEmpty {
                externalPassWaiters.removeFirst().resume()
            }
        }
        return try await Self.$runsInsideExternalPass.withValue(true) { try await pass() }
    }

    private func drainQueue(retryingFailedCleanup: Bool) async throws -> ResyncOutcome {
        try await recoverInterruptedEffects()
        if retryingFailedCleanup {
            try await database.writer.write { database in try DuplicateCleanupStore.clearFailures(in: database) }
        } else if let message = try await failedDuplicateCleanupMessage {
            throw OperationEngineError.externalSyncIncomplete(batchId: "duplicate-cleanup", underlying: message)
        }
        guard !isDraining else {
            let queued = try await database.writer.read { database in try SeratoWriteQueue.pendingEventCount(in: database) }
            return ResyncOutcome(appliedCount: 0, queuedCount: queued)
        }
        isDraining = true
        defer { isDraining = false }
        let reported = LibrarySyncReadiness.drainAuthorization == nil
        let intents = try await database.writer.read { database in try DuplicateCleanupStore.fetchAll(in: database) }
        for intent in intents where intent.waitingEventID == nil && intent.failure == nil {
            await advanceDuplicateCleanup(intent.target.token.fileId)
        }
        var run = SegmentRun()
        var ready: [SeratoWriteSegment.Entry] = []
        let pass = try await loadQueue()
        for loaded in pass {
            guard let queueID = loaded.queueID else { continue }
            let predecessor = run.blocked
            let readiness = readiness
            let classification = try await database.writer.read { database -> (GuardedSeratoWrite, SeratoConflictQueueDisposition, SeratoQueueDependency)? in
                guard var current = try SeratoWriteQueue.fetch(queueID: queueID, in: database) else { return nil }
                current.requiredKeeper = loaded.requiredKeeper
                let (disposition, dependency) = try SeratoConflictQueue.classify(current, blocked: predecessor, readiness: readiness, in: database)
                return (current, disposition, dependency)
            }
            guard let (queued, disposition, dependency) = classification else { continue }
            if disposition == .blocked {
                run.block(queued, dependency: dependency)
                continue
            }
            if claimedQueueIDs[queueID] != nil || dependency.intersects(run.waiting) {
                run.wait(queued, dependency: dependency)
                continue
            }
            guard disposition == .eligible, !queued.isOrphanedCleanup, try await isEligible(queued) else {
                try await supersede(queued, reported: reported)
                run.superseded.insert(queued.eventId)
                continue
            }
            ready.append(SeratoWriteSegment.Entry(write: queued, dependency: dependency))
        }
        let owner = UUID()
        for segment in SeratoWriteSegmenter.segments(ready) {
            guard !run.stopped else { break }
            let applied = try await runSegment(segment, owner: owner, reported: reported, run: &run)
            for target in Set(applied.compactMap(\.cleanupTargetFileID)) {
                await advanceDuplicateCleanup(target)
            }
        }
        let remaining = try await database.writer.read { database in try SeratoWriteQueue.pendingEventCount(in: database) }
        try await refreshQueueDepth()
        let outcome = ResyncOutcome(appliedCount: run.applied.count, queuedCount: remaining, supersededCount: run.superseded.count,
                                    conflictBlockedCount: run.blockedEvents.count, missingTargetCount: run.missingTarget.count,
                                    blockedQueueIDs: run.blockedQueueIDs)
        await note(outcome.summaryMessage)
        if let failure = Self.combinedFailure(run.failures) {
            throw failure
        }
        return outcome
    }

    private static func combinedFailure(_ failures: [Error]) -> Error? {
        guard let first = failures.first else { return nil }
        guard failures.count > 1 else { return first }
        let details = failures.map(\.localizedDescription).joined(separator: "; ")
        return OperationEngineError.externalSyncIncomplete(batchId: "queued-changes", underlying: "\(details). Fix the causes, then choose Retry Sync.")
    }

    /// Progress of one pass over queued rows. A row that failed, went stale,
    /// or is claimed by another pass holds back every later row sharing its
    /// file or path; a conflict-blocked row does the same and stays allowed
    /// for readiness.
    private struct SegmentRun {
        var applied = Set<Int64>()
        var missingTarget = Set<Int64>()
        var superseded = Set<Int64>()
        var blocked = SeratoQueueDependency()
        var waiting = SeratoQueueDependency()
        var blockedEvents = Set<Int64>()
        var blockedQueueIDs = Set<Int64>()
        var queuedEvents = Set<Int64>()
        var failures: [Error] = []
        var stopped = false

        mutating func block(_ write: GuardedSeratoWrite, dependency: SeratoQueueDependency) {
            blocked.formUnion(dependency)
            blockedEvents.insert(write.eventId)
            if let queueID = write.queueID {
                blockedQueueIDs.insert(queueID)
            }
        }

        mutating func wait(_ write: GuardedSeratoWrite, dependency: SeratoQueueDependency) {
            waiting.formUnion(dependency)
            queuedEvents.insert(write.eventId)
        }
    }

    /// Applies one segment as a single external pass and returns the rows it
    /// completed. Rows are reloaded first: an earlier segment's completion can
    /// rebase their baseline. Rows rejected at the writer boundary leave their
    /// siblings coalesced.
    private func runSegment(_ segment: SeratoWriteSegment, owner: UUID, reported: Bool, run: inout SegmentRun) async throws -> [GuardedSeratoWrite] {
        let stored = try await database.writer.read { database in
            try segment.entries.map { entry -> SeratoWriteSegment.Entry? in
                guard let queueID = entry.write.queueID, var current = try SeratoWriteQueue.fetch(queueID: queueID, in: database) else { return nil }
                current.requiredKeeper = entry.write.requiredKeeper
                return SeratoWriteSegment.Entry(write: current, dependency: entry.dependency)
            }
        }
        var dependencies: [Int64: SeratoQueueDependency] = [:]
        var candidates: [GuardedSeratoWrite] = []
        for entry in stored.compactMap({ entry in entry }) {
            guard let queueID = entry.write.queueID else { continue }
            if entry.dependency.intersects(run.blocked) {
                run.block(entry.write, dependency: entry.dependency)
            } else if entry.dependency.intersects(run.waiting) || claimedQueueIDs[queueID] != nil {
                run.wait(entry.write, dependency: entry.dependency)
            } else {
                dependencies[queueID] = entry.dependency
                candidates.append(entry.write)
            }
        }
        guard !candidates.isEmpty else { return [] }
        guard await !(seratoWatchdog.isSeratoRunning) else {
            run.stopped = true
            run.queuedEvents.formUnion(candidates.map(\.eventId))
            return []
        }
        var rows = try await eligibleWrites(candidates)
        try await supersedeMissing(from: candidates, keeping: rows, reported: reported, run: &run)
        let claimed = claim(Set(rows.compactMap(\.queueID)), owner: owner)
        defer {
            release(claimed, owner: owner)
            for queueID in claimed {
                attemptIO[queueID] = nil
            }
        }
        func dependency(of write: GuardedSeratoWrite) -> SeratoQueueDependency {
            write.queueID.flatMap { queueID in dependencies[queueID] } ?? SeratoQueueDependency()
        }
        // Holding a row back also holds back its later dependents in this segment.
        func holdingBack(_ held: Set<Int64>, from rows: [GuardedSeratoWrite], run: inout SegmentRun) -> [GuardedSeratoWrite] {
            var kept: [GuardedSeratoWrite] = []
            for write in rows {
                if write.queueID.map(held.contains) == true || dependency(of: write).intersects(run.waiting) {
                    run.wait(write, dependency: dependency(of: write))
                } else {
                    kept.append(write)
                }
            }
            return kept
        }
        rows = holdingBack(Set(rows.compactMap(\.queueID)).subtracting(claimed), from: rows, run: &run)
        while !rows.isEmpty {
            do {
                try await requireExternalWriteEligibility(rows)
                try await recordAttempt(rows)
                let missing = try await applyConsecutiveSeratoWrites(rows, reported: reported)
                let unmatched = rows.filter { write in write.queueID.map(missing.contains) == true }
                try await completeQueuedWrites(rows, missingTarget: missing, reported: reported)
                run.applied.formUnion(rows.filter { write in write.queueID.map(missing.contains) != true }.map(\.eventId))
                run.missingTarget.formUnion(unmatched.map(\.eventId))
                return rows
            } catch let ExternalWriteInterruption.superseded(rejected) {
                let survivors = rows.filter { write in write.queueID.map(rejected.contains) != true }
                for write in rows where write.queueID.map(rejected.contains) == true {
                    try await supersede(write, reported: reported)
                    run.superseded.insert(write.eventId)
                }
                rows = try await eligibleWrites(survivors)
                try await supersedeMissing(from: survivors, keeping: rows, reported: reported, run: &run)
            } catch let ExternalWriteInterruption.stale(stale) {
                rows = holdingBack(stale, from: rows, run: &run)
            } catch let ExternalWriteInterruption.conflicted(conflicted) {
                var survivors: [GuardedSeratoWrite] = []
                for write in rows {
                    if write.queueID.map(conflicted.contains) == true || dependency(of: write).intersects(run.blocked) {
                        run.block(write, dependency: dependency(of: write))
                    } else {
                        survivors.append(write)
                    }
                }
                rows = survivors
            } catch is SeratoPathConflictError {
                for write in rows {
                    run.block(write, dependency: dependency(of: write))
                }
                return []
            } catch ExternalWriteInterruption.deferred {
                let remainder = try await eligibleWrites(rows)
                try await supersedeMissing(from: rows, keeping: remainder, reported: reported, run: &run)
                run.queuedEvents.formUnion(remainder.map(\.eventId))
                run.stopped = true
                return []
            } catch {
                try await recordFailure(rows, error: error)
                for write in rows {
                    run.wait(write, dependency: dependency(of: write))
                }
                run.failures.append(error)
                return []
            }
        }
        return []
    }

    private func supersedeMissing(from candidates: [GuardedSeratoWrite], keeping kept: [GuardedSeratoWrite], reported: Bool, run: inout SegmentRun) async throws {
        let keptIDs = Set(kept.compactMap(\.queueID))
        for write in candidates where write.queueID.map(keptIDs.contains) != true {
            try await supersede(write, reported: reported)
            run.superseded.insert(write.eventId)
        }
    }

    /// Claims the rows no other pass holds, in one actor step with no
    /// suspension between the check and the claim.
    private func claim(_ queueIDs: Set<Int64>, owner: UUID) -> Set<Int64> {
        let available = queueIDs.filter { queueID in claimedQueueIDs[queueID] == nil }
        for queueID in available {
            claimedQueueIDs[queueID] = owner
        }
        return available
    }

    /// Releases only the claims this pass owns.
    private func release(_ queueIDs: Set<Int64>, owner: UUID) {
        for queueID in queueIDs where claimedQueueIDs[queueID] == owner {
            claimedQueueIDs[queueID] = nil
        }
    }

    private func loadQueue() async throws -> [GuardedSeratoWrite] {
        try await database.writer.read { database in
            let keepers = try DuplicateCleanupStore.fetchAll(in: database).reduce(into: [Int64: FileActionAuthority]()) { keepers, intent in
                keepers[intent.target.token.fileId] = intent.keeper
            }
            return try SeratoWriteQueue.fetchOrdered(in: database).map { row in
                var write = row
                if let target = row.cleanupTargetFileID {
                    write.requiredKeeper = keepers[target]
                }
                return write
            }
        }
    }

    /// Classifies a scoped pass in FIFO order. Rows outside the scope, or
    /// claimed by another pass, are still pending, so a scoped row that
    /// depends on one waits for it rather than overtaking it. A row that a
    /// newer revision already superseded can never apply and blocks nothing.
    private func partitionScopedRows(_ queueIDs: Set<Int64>) async throws -> (eligible: [SeratoWriteSegment.Entry], blocked: [GuardedSeratoWrite], superseded: [GuardedSeratoWrite]) {
        let rows = try await loadQueue()
        let claimed = Set(claimedQueueIDs.keys)
        let readiness = readiness
        return try await database.writer.read { database in
            var dependencies = SeratoQueueDependency()
            var eligible: [SeratoWriteSegment.Entry] = []
            var blocked: [GuardedSeratoWrite] = []
            var superseded: [GuardedSeratoWrite] = []
            for write in rows {
                guard let queueID = write.queueID else { continue }
                guard queueIDs.contains(queueID), !claimed.contains(queueID) else {
                    guard let file = try FileRecord.fetchOne(database, key: write.token.fileId),
                          SeratoWriteEligibility.permits(write, file: file) else { continue }
                    try dependencies.formUnion(SeratoQueueDependency(target: SeratoConflictTargets.write(write, in: database), eventID: write.eventId))
                    continue
                }
                if write.isOrphanedCleanup {
                    superseded.append(write)
                    continue
                }
                let (disposition, dependency) = try SeratoConflictQueue.classify(write, blocked: dependencies, readiness: readiness, in: database)
                switch disposition {
                case .blocked:
                    dependencies.formUnion(dependency)
                    blocked.append(write)
                case .eligible: eligible.append(SeratoWriteSegment.Entry(write: write, dependency: dependency))
                case .superseded: superseded.append(write)
                }
            }
            return (eligible, blocked, superseded)
        }
    }

    /// Drops a queued write that can no longer apply, recording why. A
    /// cleanup step's write cancels the whole cleanup it belongs to.
    private func supersede(_ write: GuardedSeratoWrite, reported: Bool) async throws {
        if let target = write.cleanupTargetFileID, !write.isOrphanedCleanup {
            try await cancelDuplicateCleanup(target, result: .superseded("Duplicate cleanup was superseded; its remaining steps were cancelled."))
            return
        }
        try await database.writer.write { database in
            try Self.dropQueuedWrite(write, disposition: .superseded, reported: reported, in: database)
        }
    }

    /// An audio write that was attempted and whose target then changed cannot
    /// be told apart from an interrupted write of our own, so it is reported
    /// as interrupted and never retried.
    private static func dropQueuedWrite(_ write: GuardedSeratoWrite, disposition: SeratoWriteDisposition, detail: String? = nil,
                                        reported: Bool, in database: GRDB.Database) throws
    {
        guard try SeratoWriteQueue.delete(write, in: database) else { return }
        let attemptedAudioWrite = write.attempts > 0 && [SeratoWriteKind.fileTagWrite, .trashFile].contains(write.write.kind)
        try SeratoWriteDispositions.record(eventID: write.eventId, kind: write.write.kind, disposition: attemptedAudioWrite ? .interrupted : disposition,
                                           detail: detail ?? write.lastError, reported: reported, in: database)
    }

    private func recordAttempt(_ writes: [GuardedSeratoWrite]) async throws {
        try await database.writer.write { database in try SeratoWriteQueue.recordAttempt(writes, in: database) }
        for queueID in writes.compactMap(\.queueID) {
            attemptIO[queueID] = nil
        }
    }

    /// A row none of whose writes' I/O returned cannot have landed: each one
    /// that reached I/O threw from it. Only a mark this attempt set is
    /// cleared; any other may be an earlier process's that is not folded yet.
    private func recordFailure(_ writes: [GuardedSeratoWrite], error: Error) async throws {
        let message = error.localizedDescription
        let unwritten = writes.compactMap(\.queueID).filter { queueID in attemptIO[queueID] == .marked }
        try await database.writer.write { database in
            try SeratoWriteQueue.recordFailure(writes, message: message, in: database)
            try SeratoWriteQueue.clearIOStarted(unwritten, in: database)
            for target in Set(writes.compactMap(\.cleanupTargetFileID)) {
                guard let intent = try DuplicateCleanupStore.fetch(targetFileID: target, in: database) else { continue }
                try DuplicateCleanupStore.recordFailure(targetFileID: target, message: Self.duplicateCleanupFailureMessage(intent, error: error), in: database)
            }
        }
    }

    /// Deletes rows whose effects all landed. Writers that must make their
    /// completion atomic with I/O already did so; this finishes the rest.
    private func completeQueuedWrites(_ writes: [GuardedSeratoWrite], missingTarget: Set<Int64>, reported: Bool) async throws {
        let locator = seratoLocator
        try await database.writer.write { database in
            try Self.completeQueuedWrites(writes, missingTarget: missingTarget, reported: reported, locator: locator, in: database)
        }
    }

    /// A row whose write found no entry at its path is recorded visibly and
    /// leaves the external baseline alone, since nothing was written.
    private static func completeQueuedWrites(_ writes: [GuardedSeratoWrite], missingTarget: Set<Int64> = [], reported: Bool = false,
                                             locator: SeratoLibraryLocator, in database: GRDB.Database) throws
    {
        for write in writes {
            guard try SeratoWriteQueue.delete(write, in: database) else { continue }
            if write.queueID.map(missingTarget.contains) == true {
                try SeratoWriteDispositions.record(eventID: write.eventId, kind: write.write.kind, disposition: .noSeratoRecord,
                                                   detail: missingTargetDetail(write.write), reported: reported, in: database)
            } else if case let .metadataUpdate(update) = write.write,
                      let previous = try SeratoExternalBaselines.load(token: write.token, identity: write.originalIdentity, locator: locator, in: database)
            {
                try SeratoExternalBaselines.save(update.metadata.overlaid(on: previous), token: write.token, in: database)
            }
            if write.queueID.map(missingTarget.contains) != true {
                try SeratoWriteQueue.rebaseMetadata(after: write, in: database)
            }
            try DuplicateCleanupStore.completeEffect(of: write, in: database)
        }
    }

    private static func missingTargetDetail(_ write: SeratoPendingWrite) -> String {
        let path = switch write {
        case let .rename(rename): rename.oldAbsolutePath
        case let .metadataUpdate(update): update.absolutePath
        case .addTrack, .fileTagWrite, .removeFromDatabase, .removeFromCrates, .trashFile:
            preconditionFailure("Only renames and metadata updates report a path with no Serato entry")
        }
        return "Serato's database has no entry at this path: \((path as NSString).lastPathComponent)."
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
        let files = try fetchFiles(fileIDs: writes.map(\.token.fileId), in: database)
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

    /// Performs one external write inside the serialized writer. Each write's
    /// queue row must still hold the payload this pass loaded: a missing or
    /// reduced row was completed or superseded meanwhile and is skipped
    /// rather than applied twice. With `completing`, the rows are deleted in
    /// the same transaction as the I/O.
    private func performExternalWrite<Output: Sendable>(
        _ writes: [GuardedSeratoWrite], completing: Bool = false, operation: @escaping @Sendable (GRDB.Database) throws -> Output
    ) async throws -> Output {
        try await performExternalWrite(writes, completing: completing) { database, io in
            let result = try operation(database)
            io.recordReturned()
            return result
        }
    }

    /// For a writer that validates or records after its I/O: it reports
    /// through `io` the moment its I/O returns, so a later throw cannot make
    /// that I/O look as if it never landed.
    private func performExternalWrite<Output: Sendable>(
        _ writes: [GuardedSeratoWrite], completing: Bool = false, operation: @escaping @Sendable (GRDB.Database, ExternalIOProgress) throws -> Output
    ) async throws -> Output {
        let watchdog = seratoWatchdog
        let readiness = readiness
        let drainAuthorization = LibrarySyncReadiness.drainAuthorization
        let locator = seratoLocator
        let queueIDs = writes.compactMap(\.queueID)
        let unmarked = queueIDs.filter { queueID in attemptIO[queueID] == nil }
        if !unmarked.isEmpty {
            try await database.writer.write { database in try SeratoWriteQueue.markIOStarting(unmarked, in: database) }
            for queueID in unmarked {
                attemptIO[queueID] = .marked
            }
        }
        let unwritten = queueIDs.filter { queueID in attemptIO[queueID] == .marked }
        let progress = ExternalIOProgress()
        defer {
            if progress.returned {
                for queueID in queueIDs {
                    attemptIO[queueID] = .returned
                }
            }
        }
        // Releasing writer serialization before I/O lets retirement commit against old authorization.
        let outcome = try await database.writer.write { database -> Swift.Result<Output, ExternalWriteInterruption> in
            do {
                try Self.requireExternalWriteBoundary(writes, watchdog: watchdog, readiness: readiness, drainAuthorization: drainAuthorization, in: database)
            } catch let interruption as ExternalWriteInterruption {
                // Nothing was written, so this attempt's marks for rows no write reached must not survive.
                try SeratoWriteQueue.clearIOStarted(unwritten, in: database)
                return .failure(interruption)
            }
            let result: Output
            do { result = try operation(database, progress) }
            catch let error as CoreError {
                // The file was replaced; only its directory flush failed.
                if case .LandedNotDurable = error {
                    progress.recordReturned()
                }
                throw error
            }
            if completing {
                try Self.completeQueuedWrites(writes, locator: locator, in: database)
            }
            return .success(result)
        }
        if case .failure = outcome {
            for queueID in unwritten {
                attemptIO[queueID] = nil
            }
        }
        return try outcome.get()
    }

    /// Every check that must still hold at the moment of external I/O.
    private static func requireExternalWriteBoundary(_ writes: [GuardedSeratoWrite], watchdog: SeratoWatchdog, readiness: LibrarySyncReadiness?,
                                                     drainAuthorization: LibrarySyncReadiness.Authorization?, in database: GRDB.Database) throws
    {
        var stale = Set<Int64>()
        for write in writes {
            guard let queueID = write.queueID else { throw OperationEngineError.insertDidNotReturnRowId }
            if try SeratoWriteQueue.state(of: write, in: database) != .current {
                stale.insert(queueID)
            }
        }
        if !stale.isEmpty {
            throw ExternalWriteInterruption.stale(stale)
        }
        guard try Self.eligibleWrites(writes, in: database).count == writes.count,
              !watchdog.isRunningForExternalWrite,
              readiness?.permitsExternalWrites(drain: drainAuthorization) != false
        else {
            throw ExternalWriteInterruption.deferred
        }
        try Self.requireUnconflicted(writes, readiness: readiness, in: database)
        var superseded = Set<Int64>()
        for write in writes {
            guard let queueID = write.queueID else { continue }
            guard let file = try FileRecord.fetchOne(database, key: write.token.fileId) else {
                superseded.insert(queueID)
                continue
            }
            do { try SeratoWriteEligibility.requirePhysicalTarget(write, file: file, in: database) }
            catch is FileProcessingEligibilityError { superseded.insert(queueID) }
        }
        if !superseded.isEmpty {
            throw ExternalWriteInterruption.superseded(superseded)
        }
        guard !watchdog.isRunningForExternalWrite,
              readiness?.permitsExternalWrites(drain: drainAuthorization) != false else { throw ExternalWriteInterruption.deferred }
        try Self.requireUnconflicted(writes, readiness: readiness, in: database)
    }

    /// `marked`: this attempt committed the row's `io_started` mark.
    /// `returned`: a write for the row returned from its I/O, so it may have
    /// landed however the rest of its transaction ended.
    private enum AttemptIOStage: Equatable { case marked, returned }

    /// Whether one external write's I/O returned, set on the database queue
    /// and read back on the actor once the write returns or throws.
    private final class ExternalIOProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false

        var returned: Bool {
            lock.withLock { stored }
        }

        func recordReturned() {
            lock.withLock { stored = true }
        }
    }

    private func requireExternalWriteEligibility(_ writes: [GuardedSeratoWrite]) async throws {
        let eligible = try await eligibleWrites(writes)
        guard eligible.count == writes.count, await !(seratoWatchdog.isSeratoRunning), readiness?.permitsExternalWrites != false else {
            throw ExternalWriteInterruption.deferred
        }
        let readiness = readiness
        try await database.writer.read { database in try Self.requireUnconflicted(writes, readiness: readiness, in: database) }
    }

    /// Names every row whose target the conflict scope protects, so a
    /// coalesced pass can hold back only those rows.
    private static func requireUnconflicted(_ writes: [GuardedSeratoWrite], readiness: LibrarySyncReadiness?, in database: GRDB.Database) throws {
        guard let readiness, readiness.hasConflicts else { return }
        var conflicted = Set<Int64>()
        for write in writes where try readiness.conflictPath(for: SeratoConflictTargets.write(write, in: database)) != nil {
            guard let queueID = write.queueID else { throw OperationEngineError.insertDidNotReturnRowId }
            conflicted.insert(queueID)
        }
        if !conflicted.isEmpty {
            throw ExternalWriteInterruption.conflicted(conflicted)
        }
    }

    /// Applies the given rows now in dependency-ordered segments, the same way
    /// a drain does. Rows outside the scope are left for the drain.
    private func processScopedRows(_ queueIDs: Set<Int64>) async throws -> ResyncOutcome {
        try await exclusiveExternalPass { try await processScopedRowsExclusively(queueIDs) }
    }

    private func processScopedRowsExclusively(_ queueIDs: Set<Int64>) async throws -> ResyncOutcome {
        let partition = try await partitionScopedRows(queueIDs)
        var run = SegmentRun()
        for write in partition.superseded {
            try await supersede(write, reported: true)
            run.superseded.insert(write.eventId)
        }
        let blockedEvents = Set(partition.blocked.map(\.eventId))
        let owner = UUID()
        let segments = SeratoWriteSegmenter.segments(partition.eligible)
        for segment in segments {
            guard !run.stopped else {
                run.queuedEvents.formUnion(segment.entries.map(\.write.eventId))
                continue
            }
            _ = try await runSegment(segment, owner: owner, reported: true, run: &run)
        }
        try await refreshQueueDepth()
        if let failure = Self.combinedFailure(run.failures) {
            throw failure
        }
        let blocked = blockedEvents.union(run.blockedEvents)
        return ResyncOutcome(appliedCount: run.applied.count, queuedCount: run.queuedEvents.union(blocked).subtracting(run.applied).count,
                             supersededCount: run.superseded.count, conflictBlockedCount: blocked.count, missingTargetCount: run.missingTarget.count)
    }

    /// Returns the queue IDs of rows whose write found no Serato entry at its path.
    private func applySeratoWrite(_ write: SeratoPendingWrite, guardedWrites: [GuardedSeratoWrite], reported: Bool) async throws -> Set<Int64> {
        switch write {
        case .rename:
            preconditionFailure("Queued renames are applied by applySeratoRenameBatch, never one row at a time")
        case let .metadataUpdate(update):
            return try await applySeratoMetadataUpdateBatch([update], guardedWrites: guardedWrites, reported: reported)
        case .addTrack:
            preconditionFailure("Queued adds are registered by applySeratoAddTracks, never one row at a time")
        case let .fileTagWrite(write):
            try await applyFileTagWrite(write, guardedWrites: guardedWrites)
        case let .removeFromDatabase(removal):
            try await applySeratoDatabaseRemoval(removal, guardedWrites: guardedWrites)
        case let .removeFromCrates(removal):
            try await applySeratoCrateSweepRemoval(removal, guardedWrites: guardedWrites)
        case let .trashFile(trash):
            try await applyTrashFileOperation(trash, guardedWrites: guardedWrites)
        }
        return []
    }

    private func applyTrashFileOperation(_ trash: SeratoPendingTrash, guardedWrites: [GuardedSeratoWrite]) async throws {
        let trasher = fileTrasher
        let context = mutationContext
        try await performExternalWrite(guardedWrites, completing: true) { database, io in
            do {
                try trasher(trash.absolutePath)
            } catch {
                throw OperationEngineError.trashFailed(path: trash.absolutePath, underlying: String(describing: error))
            }
            io.recordReturned()
            guard let targetFileID = guardedWrites.first?.cleanupTargetFileID else { return }
            guard let intent = try DuplicateCleanupStore.fetch(targetFileID: targetFileID, in: database) else {
                throw FileProcessingEligibilityError.superseded(fileId: targetFileID)
            }
            try intent.target.validate(in: database, audioWasTrashed: true)
            try intent.keeper.validate(in: database)
            let removal = TrackMutation.removeFile(.init(fileId: targetFileID))
            try Self.requireCurrentToken(intent.target.token, mutation: removal, in: database)
            _ = try Self.executeAndLog(context: context, mutation: removal, batchId: intent.batchID, in: database)
            try DuplicateCleanupStore.delete(targetFileID: targetFileID, in: database)
        }
    }

    private func applySeratoDatabaseRemoval(_ removal: SeratoPendingRemoval, guardedWrites: [GuardedSeratoWrite]) async throws {
        let databaseV2Path = seratoLocator.databaseV2Url.path
        let cleanupTarget = guardedWrites.first?.cleanupTargetFileID
        guard FileManager.default.fileExists(atPath: databaseV2Path) else {
            // No database V2 yet — nothing to remove from. Same
            // tolerant behavior as applySeratoMetadataUpdate, except that
            // cleanup must prove its own removal before it may trash audio.
            if cleanupTarget != nil {
                throw OperationEngineError.seratoRewriteFailed(path: databaseV2Path, underlying: "Duplicate reference removal did not complete.")
            }
            return
        }
        let seratoRelativePath = SeratoLibraryLocator.seratoRelativePath(
            fromAbsolute: removal.absolutePath
        )
        do {
            _ = try await performExternalWrite(guardedWrites, completing: true) { database, io in
                let removed = try removeTrackFromDatabase(databasePath: databaseV2Path, trackPath: seratoRelativePath)
                io.recordReturned()
                if let cleanupTarget {
                    guard try !readDatabaseRecordsStrict(databasePath: databaseV2Path).contains(where: { record in SeratoPath.normalized(record.path) == SeratoPath.normalized(removal.absolutePath) }) else {
                        throw OperationEngineError.seratoRewriteFailed(path: databaseV2Path, underlying: "Duplicate reference removal did not complete.")
                    }
                    try DuplicateCleanupStore.confirmDatabaseRemoval(targetFileID: cleanupTarget, in: database)
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
        let year = try write.year.map { requested in
            guard let year = UInt32(exactly: requested) else {
                throw OperationEngineError.fileTagWriteFailed(path: write.absolutePath, underlying: "year \(requested) is outside the writable range")
            }
            return year
        }
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
            year: year,
            clearYear: write.clearYear
        )
        let tagWriter = fileTagWriter
        do {
            try await performExternalWrite(guardedWrites, completing: true) { database, io in
                guard let guardedWrite = guardedWrites.first,
                      let file = try FileRecord.fetchOne(database, key: guardedWrite.token.fileId)
                else {
                    throw OperationEngineError.insertDidNotReturnRowId
                }
                try tagWriter(write.absolutePath, update)
                io.recordReturned()
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

    /// Registers every queued add in `rows` with Serato in one `database V2`
    /// pass, then confirms each import in the same transaction, so a row
    /// that went stale or was superseded is rejected before the write and
    /// its siblings retry without it.
    private func applySeratoAddTracks(_ rows: [GuardedSeratoWrite]) async throws {
        let adds = rows.compactMap { row -> (row: GuardedSeratoWrite, add: SeratoPendingAddTrack)? in
            guard case let .addTrack(add) = row.write else { return nil }
            return (row, add)
        }
        guard let firstAdd = adds.first else { return }
        let databaseV2Path = seratoLocator.databaseV2Url.path
        let seratoDirectory = seratoLocator.seratoDirectory
        let additions = adds.map { entry in
            SeratoTrackAddition(
                trackPath: SeratoLibraryLocator.seratoRelativePath(fromAbsolute: entry.add.absolutePath),
                metadata: SeratoMetadataUpdate(
                    artist: entry.add.metadata.artist,
                    title: entry.add.metadata.title,
                    album: entry.add.metadata.album,
                    genre: entry.add.metadata.genre,
                    bpm: entry.add.metadata.bpm,
                    key: entry.add.metadata.musicalKey,
                    comment: entry.add.metadata.comment,
                    length: entry.add.metadata.length,
                    label: entry.add.metadata.label
                )
            )
        }
        let bootstrapBytes = freshDatabaseV2Bytes(withTrackPath: additions[0].trackPath, metadata: firstAdd.add.metadata)
        let addWriter = seratoAddTrackBatchWriter
        let scopeAuthorization = readiness?.captureScope()
        let context = mutationContext
        try await performExternalWrite(adds.map(\.row), completing: true) { database, io in
            do {
                var pending = additions
                if !FileManager.default.fileExists(atPath: databaseV2Path) {
                    try FileManager.default.createDirectory(at: seratoDirectory, withIntermediateDirectories: true)
                    try bootstrapBytes.write(to: URL(fileURLWithPath: databaseV2Path), options: .atomic)
                    io.recordReturned()
                    pending.removeFirst()
                }
                if !pending.isEmpty {
                    _ = try addWriter(databaseV2Path, pending)
                }
            } catch let CoreError.LandedNotDurable(message) {
                io.recordReturned()
                throw OperationEngineError.seratoRewriteFailed(path: databaseV2Path, underlying: message)
            } catch {
                throw OperationEngineError.seratoRewriteFailed(path: databaseV2Path, underlying: String(describing: error))
            }
            io.recordReturned()
            try scopeAuthorization?.check()
            let libraryID = try context.locator.supportedLibraryIdentity()
            for (row, _) in adds {
                guard let file = try FileRecord.fetchOne(database, key: row.token.fileId) else {
                    throw OperationEngineError.fileNotFound(fileId: row.token.fileId)
                }
                _ = try Self.executeAndLog(
                    context: context,
                    mutation: .setFileLibraryState(.init(fileId: row.token.fileId, expectedRevision: row.token.revision,
                                                         state: FileLibraryState(membership: .active, availability: file.fileAvailability, libraryID: libraryID, retiredAt: nil))),
                    batchId: "import-confirmed:\(row.eventId)", in: database
                )
            }
            try scopeAuthorization?.check()
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

    /// One Rust FFI call rewrites the `database V2` file for every rename,
    /// then one call per crate file. Database V2 goes first: it is the
    /// source of truth for Serato's "All" view, so one corrupted crate
    /// cannot leave a moved track at its old path there. Every store is
    /// attempted; any failure keeps the batch visibly incomplete for
    /// re-sync. Returns the queue IDs of renames whose track neither the
    /// parsed database V2 nor any crate holds at its final path, which
    /// therefore did not land; without a database V2 there is nothing to
    /// compare, so none.
    private func applySeratoRenameBatch(_ renameRows: [GuardedSeratoWrite], guardedWrites: [GuardedSeratoWrite]) async throws -> Set<Int64> {
        let renames = renameRows.compactMap { row -> SeratoPendingRename? in
            guard case let .rename(rename) = row.write else { return nil }
            return rename
        }
        guard !renames.isEmpty else { return [] }
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
        var missingFromDatabase = Set<UInt32>()
        let databaseV2Path = seratoLocator.databaseV2Url.path
        if FileManager.default.fileExists(atPath: databaseV2Path) {
            do {
                let result = try await performExternalWrite(guardedWrites) { _ in try batchRewriteDatabasePaths(
                    databasePath: databaseV2Path,
                    renames: pairs
                ) }
                missingFromDatabase = Set(result.unmatchedIndices)
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
            throw OperationEngineError.seratoEnumerationFailed(
                directory: seratoLocator.subcratesDirectoryUrl.path,
                underlying: String(describing: error)
            )
        }

        var missingEverywhere = missingFromDatabase
        var perCrateFailures: [(URL, Error)] = []
        for crateFile in crateFiles {
            try await requireExternalWriteEligibility(guardedWrites)
            do {
                let result = try await performExternalWrite(guardedWrites) { _ in try batchRewriteCratePaths(
                    cratePath: crateFile.path,
                    renames: pairs
                ) }
                missingEverywhere.formIntersection(result.unmatchedIndices)
            } catch let error as ExternalWriteInterruption {
                throw error
            } catch {
                perCrateFailures.append((crateFile, error))
                await note("Skipped crate \(crateFile.lastPathComponent) during batch rename: \(error.localizedDescription)")
            }
        }

        try requireSuccessfulSeratoRenames(databaseError: databaseV2Error, crateFailures: perCrateFailures)
        for index in missingFromDatabase.sorted() {
            let oldPath = pairs[Int(index)].oldPath
            await note(missingEverywhere.contains(index)
                ? "Serato's database and crates have no entry at \(oldPath); the rename was not applied there."
                : "Serato's database has no entry at \(oldPath); only its crates were updated.")
        }
        return Set(missingEverywhere.compactMap { index in renameRows[Int(index)].queueID })
    }

    private static func queueIDs(of writes: [GuardedSeratoWrite], where matches: (SeratoPendingWrite) -> Bool) -> Set<Int64> {
        Set(writes.filter { write in matches(write.write) }.compactMap(\.queueID))
    }

    private func requireSuccessfulSeratoRenames(databaseError: Error?, crateFailures: [(URL, Error)]) throws {
        let firstFailure = databaseError.map { error in (seratoLocator.databaseV2Url, error) } ?? crateFailures.first
        if let (url, error) = firstFailure {
            throw OperationEngineError.seratoRewriteFailed(path: url.path, underlying: String(describing: error))
        }
    }

    /// Apply a batch's Serato writes with the full-`database V2`
    /// rewrite kinds coalesced into one read+write pass each:
    ///
    /// - Renames: consecutive `.rename` runs → one `applySeratoRenameBatch`.
    /// - Adds: consecutive `.addTrack` runs → one `applySeratoAddTracks`.
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
    ///
    /// Returns the queue IDs of rows whose write found no Serato entry at its path.
    private func applyConsecutiveSeratoWrites(_ guardedWrites: [GuardedSeratoWrite], reported: Bool) async throws -> Set<Int64> {
        var metadataUpdates: [SeratoPendingMetadataUpdate] = []
        var remaining: [GuardedSeratoWrite] = []
        for row in guardedWrites {
            if case let .metadataUpdate(update) = row.write {
                metadataUpdates.append(update)
            } else {
                remaining.append(row)
            }
        }

        var missingTarget = Set<Int64>()
        if !metadataUpdates.isEmpty {
            try await missingTarget.formUnion(applySeratoMetadataUpdateBatch(metadataUpdates, guardedWrites: guardedWrites, reported: reported))
        }

        var index = 0
        while index < remaining.count {
            switch remaining[index].write {
            case .rename:
                var renameRows: [GuardedSeratoWrite] = []
                while index < remaining.count, case .rename = remaining[index].write {
                    renameRows.append(remaining[index])
                    index += 1
                }
                try await missingTarget.formUnion(applySeratoRenameBatch(renameRows, guardedWrites: guardedWrites))
            case .addTrack:
                var adds: [GuardedSeratoWrite] = []
                while index < remaining.count, case .addTrack = remaining[index].write {
                    adds.append(remaining[index])
                    index += 1
                }
                try await applySeratoAddTracks(adds)
            default:
                try await missingTarget.formUnion(applySeratoWrite(remaining[index].write, guardedWrites: guardedWrites, reported: reported))
                index += 1
            }
        }
        return missingTarget
    }

    /// Write every metadata update in one `database V2` read+rewrite
    /// pass via the injected `seratoMetadataBatchWriter`. Returns the queue
    /// IDs of updates whose track the parsed database V2 does not hold. A
    /// missing database V2 (Serato never ran here) is not evidence that a
    /// track is absent, so it is tolerated as before and reports none.
    private func applySeratoMetadataUpdateBatch(
        _ updates: [SeratoPendingMetadataUpdate], guardedWrites: [GuardedSeratoWrite], reported: Bool
    ) async throws -> Set<Int64> {
        guard !updates.isEmpty else { return [] }
        let databaseV2Path = seratoLocator.databaseV2Url.path
        guard FileManager.default.fileExists(atPath: databaseV2Path) else { return [] }

        // The batch writer keys updates by path and keeps only the last one, so
        // queued edits of the same record are merged in queue order first.
        var merged: [SeratoPendingMetadataUpdate] = []
        var mergedIndex: [String: Int] = [:]
        for update in updates {
            let key = SeratoPath.normalized(update.absolutePath)
            if let index = mergedIndex[key] {
                merged[index] = SeratoPendingMetadataUpdate(absolutePath: merged[index].absolutePath,
                                                            metadata: update.metadata.overlaid(on: merged[index].metadata))
            } else {
                mergedIndex[key] = merged.count
                merged.append(update)
            }
        }
        let trackUpdates = merged.map { update in
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
        let locator = seratoLocator
        do {
            let (missing, unmatchedPaths) = try await performExternalWrite(guardedWrites) { database, io in
                let result = try metadataWriter(databaseV2Path, trackUpdates)
                io.recordReturned()
                let unmatched = Set(result.unmatchedIndices.map { index in SeratoPath.normalized(merged[Int(index)].absolutePath) })
                let missing = Self.queueIDs(of: guardedWrites) { write in
                    guard case let .metadataUpdate(update) = write else { return false }
                    return unmatched.contains(SeratoPath.normalized(update.absolutePath))
                }
                try Self.completeQueuedWrites(guardedWrites, missingTarget: missing, reported: reported, locator: locator, in: database)
                return (missing, result.unmatchedIndices.map { index in trackUpdates[Int(index)].trackPath })
            }
            for path in unmatchedPaths {
                await note("Serato's database has no entry at \(path); its metadata update was not applied.")
            }
            return missing
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

    /// Runs one mutation and enqueues its Serato-side effects in the same
    /// transaction, so a committed mutation always has a durable record of the
    /// external work it still owes.
    private static func executeAndLog(
        context: MutationContext, mutation: TrackMutation, batchId: String,
        in database: GRDB.Database, physicalMoves: PhysicalFileMoveTransaction? = nil,
        expectedPhysicalSource: SeratoSourceIdentity? = nil
    ) throws -> GuardedExecutionResult {
        let readiness = context.readiness
        let scopeAuthorization = readiness?.captureScope()
        let target = readiness?.hasConflicts == true ? try SeratoConflictTargets.mutation(mutation, in: database) : nil
        if let target {
            try readiness?.requireUnconflicted(target)
        }
        let result = try executeAndLogUnchecked(mutation: mutation, batchId: batchId, in: database,
                                                physicalMoves: physicalMoves, expectedPhysicalSource: expectedPhysicalSource)
        if let target {
            try readiness?.requireUnconflicted(target)
        }
        try scopeAuthorization?.check()
        let queued = try result.seratoWrites.map { write in
            try SeratoWriteQueue.insert(write, cleanupTargetFileID: context.cleanupTargetFileID, locator: context.locator, in: database)
        }
        return GuardedExecutionResult(eventId: result.eventId, seratoWrites: queued)
    }

    private static func executeAndLogUnchecked(
        mutation: TrackMutation,
        batchId: String,
        in database: GRDB.Database,
        physicalMoves: PhysicalFileMoveTransaction? = nil,
        expectedPhysicalSource: SeratoSourceIdentity? = nil
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
            let moved = try physicalMoves.move(payload, file: file, expectedSource: expectedPhysicalSource)
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
        case let .indexNewFile(payload):
            let eventId = try applyIndexNewFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case let .renameFile(payload):
            let (eventId, seratoRename) = try applyRenameFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.rename(seratoRename)]
            )
        case let .removeFile(payload):
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
        case let .observeFileMetadata(payload):
            let eventId = try FileIdentityObservationMutation.apply(payload.observation, batchId: batchId, timestamp: timestampMillis, in: db,
                                                                    metadataEvidence: payload.evidence, expectedMetadata: payload.expectedMetadata)
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case let .setFileLibraryState(payload):
            let eventId = try FileLibraryStateMutation.apply(payload, batchId: batchId, timestamp: timestampMillis, in: db)
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case let .beginFileImport(payload):
            let eventId = try FileLibraryStateMutation.beginImport(payload, batchId: batchId, timestamp: timestampMillis, in: db)
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case let .setMetadata(payload):
            let eventId = try applySetMetadata(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case let .commitMetadataToSerato(payload):
            let (eventId, seratoUpdate) = try applyCommitMetadataToSerato(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.metadataUpdate(seratoUpdate)]
            )
        case let .addTrackToSerato(payload):
            let (eventId, seratoAdd) = try applyAddTrackToSerato(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.addTrack(seratoAdd)]
            )
        case let .writeFileTags(payload):
            let (eventId, fileTagWrite) = try applyWriteFileTags(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.fileTagWrite(fileTagWrite)]
            )
        case let .trashFile(payload):
            let (eventId, trash) = try applyTrashFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: [.trashFile(trash)])
        case let .removeTrackFromSerato(payload):
            let (eventId, removal) = try applyRemoveTrackFromSerato(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.removeFromDatabase(removal)]
            )
        case let .removeFileFromCrates(payload):
            let (eventId, removal) = try applyRemoveFileFromCrates(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.removeFromCrates(removal)]
            )
        case let .applyMusicBrainzMatch(payload):
            let (eventId, seratoWrites) = try applyMusicBrainzMatch(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: seratoWrites)
        case let .revertMusicBrainzMatch(payload):
            let (eventId, seratoWrites) = try applyRevertMusicBrainzMatch(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: seratoWrites)
        case let .songFamily(operation):
            let eventId = try SongFamilyMutation.apply(operation, batchId: batchId, timestamp: timestampMillis, in: db)
            return ExecutionResult(eventId: eventId, seratoWrites: [])
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
        if let artist = payload.artist ?? (seedKeptFields ? payload.currentFileArtist : nil) {
            track.artist = artist
        }
        if let title = payload.title ?? (seedKeptFields ? payload.currentFileTitle : nil) {
            track.title = title
        }
        if let album = payload.album ?? (seedKeptFields ? payload.currentFileAlbum : nil) {
            track.album = album
        }
        if let year = payload.year ?? (seedKeptFields ? payload.currentFileYear : nil) {
            track.year = year
        }
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
            .fetchOne(db)
        {
            // `AutoTaggerService.fingerprintConflictFileIDs` excludes these rows before the batch;
            // this rejection remains the guard against changes made since that preflight.
            let existingTrackID = existingTrack.id
            if let existingMBID = try existingTrack.conflictingRecording(replacingWith: payload.recordingMBID, otherFilesReference: {
                try FileRecord.hasOtherFilesReferencingTrack(existingTrackID, excluding: payload.fileID, in: db)
            }) {
                throw OperationEngineError.fingerprintRecordingConflict(
                    fileId: payload.fileID,
                    existingMBID: existingMBID,
                    incomingMBID: payload.recordingMBID
                )
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
            // Undo retains an empty fingerprint row for FK stability, and song
            // grouping links a file to one. Reusing a bare row no other library
            // file depends on must seed kept fields just like creation; a
            // retired file keeps its link but no longer names the recording.
            let isEmptyOrphan = try existingTrack.isBare
                && FileRecord.otherActiveFileReferencingTrack(existingId, excluding: payload.fileID, in: db) == nil
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
        if let artist = payload.artist {
            fileRecord.artist = artist
        }
        if let title = payload.title {
            fileRecord.title = title
        }
        if let album = payload.album {
            fileRecord.album = album
        }
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
        // forward created it or it pre-existed).
        let track = try TrackRecord
            .filter(Column("fingerprint_hash") == applied.fingerprintHash)
            .fetchOne(db)

        // The out-of-order undo guard (rejecting a revert whose file was
        // re-matched by a LATER batch) lives in `undoBatch`, keyed on the event
        // log — the authoritative signal. Row/reference state can't be used
        // here: a same-batch sibling (a different file sharing the row) and a
        // cross-batch re-match of THIS file to the same recording/different
        // release present identical row state (recording unchanged, release
        // drifted, no surviving reference), yet one must undo and the other
        // must be rejected (finding #3999974010). So this method assumes the
        // revert is in-order.

        // Restore the file link + Serato snapshot for exactly the
        // display fields the forward changed.
        fileRecord.trackId = applied.previousTrackID
        if let previousMetadata = applied.previousMetadata {
            if applied.artist != nil {
                fileRecord.artist = previousMetadata.artist
            }
            if applied.title != nil {
                fileRecord.title = previousMetadata.title
            }
            if applied.album != nil {
                fileRecord.album = previousMetadata.album
            }
        }
        try fileRecord.update(db)

        // Undoing batch A must never overwrite what a later batch B
        // established on the same fingerprint-keyed row (invariant #4:
        // FLAC+MP3 of one recording, or a re-encode, share a track row). This
        // runs before the revert is journaled, while A's apply is still live.
        if var track {
            guard applied.createdTrackRow || applied.previousTrackIdentifiers != nil else {
                throw OperationEngineError.missingPreviousTrackIdentifiers(fileId: applied.fileID)
            }
            let original = track
            try CanonicalTrackOwnership.restoreFields(of: &track, revertingMatchOf: applied.fileID, in: db)
            if track != original {
                try track.update(db)
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
        let fileSnapshot = applied.fileTagRestoreSnapshot

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

    static func insertEvent(
        batchId: String,
        timestamp: Int64,
        fileId: Int64?,
        trackId: Int64? = nil,
        eventType: EventType,
        forwardPayload: some Encodable,
        inversePayload: some Encodable,
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
              let inverseJsonString = String(data: inverseJsonData, encoding: .utf8)
        else {
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
/// running (durably queued, drain on Serato exit). The UI uses
/// this split to phrase the result honestly — "Re-sync complete"
/// when N actually landed vs "Queued N — quit Serato to apply"
/// when nothing did.
public struct ResyncOutcome: Sendable, Equatable {
    public let appliedCount: Int
    public let queuedCount: Int
    public let supersededCount: Int
    public let conflictBlockedCount: Int
    /// Changes whose write found no Serato entry at their path, so nothing
    /// landed (#105).
    public let missingTargetCount: Int
    /// Queue rows a drain left in place only because a path conflict blocks
    /// them; readiness may open around exactly these.
    let blockedQueueIDs: Set<Int64>

    public init(appliedCount: Int, queuedCount: Int, supersededCount: Int = 0, conflictBlockedCount: Int = 0, missingTargetCount: Int = 0) {
        self.init(appliedCount: appliedCount, queuedCount: queuedCount, supersededCount: supersededCount,
                  conflictBlockedCount: conflictBlockedCount, missingTargetCount: missingTargetCount, blockedQueueIDs: [])
    }

    init(appliedCount: Int, queuedCount: Int, supersededCount: Int, conflictBlockedCount: Int, missingTargetCount: Int,
         blockedQueueIDs: Set<Int64>)
    {
        self.appliedCount = appliedCount
        self.queuedCount = queuedCount
        self.supersededCount = supersededCount
        self.conflictBlockedCount = conflictBlockedCount
        self.missingTargetCount = missingTargetCount
        self.blockedQueueIDs = blockedQueueIDs
    }

    public var totalCount: Int {
        appliedCount + queuedCount
    }

    public var summaryMessage: String {
        if conflictBlockedCount > 0 || missingTargetCount > 0 {
            let waiting = conflictBlockedCount > 0 ? ", including \(conflictBlockedCount) changes waiting for path-conflict repair" : ""
            let missing = missingTargetCount > 0 ? "; " + SeratoWriteDispositionMessages.summary(.noSeratoRecord, count: missingTargetCount) : ""
            return "Re-sync wrote \(appliedCount), queued \(queuedCount)\(waiting); \(supersededCount) superseded\(missing)."
        }
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
    case observeFileMetadata(ObserveFileMetadataPayload)
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
    case songFamily(SongFamilyOperation)
}

/// Move the file at `fileId` to the user's Trash via
/// FileManager.trashItem. Reversible only by the user via Finder
/// ("Put Back"); journaled but undoNotSupported in the engine
/// because we can't reliably re-create audio bytes if the user has
/// emptied Trash by the time undo runs.
public struct TrashFilePayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public init(fileId: Int64) {
        self.fileId = fileId
    }
}

/// Remove the `otrk` from Serato's database V2 whose `pfil`
/// matches the file's path. Gated by `SeratoWatchdog` — Serato
/// must be closed to avoid the in-memory cache overwriting the
/// disk version on save. Not undoable: re-adding would require
/// reconstructing the otrk's full metadata + analysis (cue points,
/// beatgrid) which we don't carry across the boundary today.
public struct RemoveTrackFromSeratoPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public init(fileId: Int64) {
        self.fileId = fileId
    }
}

/// Sweep every `.crate` file in Serato's Subcrates directory and
/// remove the `otrk` whose `ptrk` matches the file's path. Gated
/// by SeratoWatchdog. Not undoable: a follow-up "re-add to original
/// crates" would need to track which crates contained the file
/// before removal, which isn't journaled today.
public struct RemoveFileFromCratesPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public init(fileId: Int64) {
        self.fileId = fileId
    }
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
struct SeratoPendingRemoval: Codable, Sendable, Equatable {
    let absolutePath: String
}

/// Queued trash-move. Routed through the SeratoWatchdog gate
/// because Serato may have the file open for playback or analysis;
/// moving a file out from under Serato can crash it or corrupt
/// in-flight reads.
struct SeratoPendingTrash: Codable, Sendable, Equatable {
    let absolutePath: String
}

/// File-tag write deferred by the SeratoWatchdog. Carries the
/// absolute path resolved from the FileRecord plus the metadata
/// snapshot to write.
struct SeratoPendingFileTagWrite: Codable, Sendable, Equatable {
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
struct SeratoPendingRename: Codable, Sendable, Equatable {
    let oldAbsolutePath: String
    let newAbsolutePath: String
}

/// A Serato-side metadata update scheduled by
/// `commitMetadataToSerato`. Carries the absolute path of the file
/// and the new metadata to write into Serato's `database V2`.
struct SeratoPendingMetadataUpdate: Codable, Sendable, Equatable {
    let absolutePath: String
    let metadata: SeratoMetadata
}

/// A Serato-side track-insert scheduled by `addTrackToSerato`.
/// Carries the file's absolute path plus the metadata to embed in
/// the new otrk entry.
struct SeratoPendingAddTrack: Codable, Sendable, Equatable {
    let absolutePath: String
    let metadata: SeratoMetadata
}

// MARK: - Errors

/// Undoing a match event, or undoing its revert, which redoes the match.
public enum MatchHistoryDirection: Sendable, Equatable {
    case undo, redo

    var verb: String {
        switch self {
        case .undo: "undo"
        case .redo: "redo"
        }
    }

    var gerund: String {
        switch self {
        case .undo: "undoing"
        case .redo: "redoing"
        }
    }
}

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
    /// Undo found no live MusicBrainz match by this file on its canonical
    /// track row, so it can't tell which row fields the match still owns.
    case matchOwnershipNotFound(fileId: Int64)
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
    /// Undo or redo of a match was refused because the audio file's tags no
    /// longer hold either end of the match for these fields: a later tag edit
    /// that the inverse would overwrite (#111).
    case undoWouldOverwriteFileTags(fileId: Int64, fields: [String], direction: MatchHistoryDirection)
    /// The audio file changed between undo's tag check and its commit, so
    /// the check no longer describes the file the inverse would rewrite.
    case undoFileChangedWhileChecking(fileId: Int64, direction: MatchHistoryDirection)
    /// Undo or redo of a match needs to read the audio file it would
    /// rewrite, and the file is missing or its volume is offline.
    case undoFileUnavailable(fileId: Int64, path: String, direction: MatchHistoryDirection)
    /// Undo or redo of a match could not read the audio file it would
    /// rewrite for a reason other than its absence, such as permissions.
    case undoFileUnreadable(fileId: Int64, path: String, reason: String, direction: MatchHistoryDirection)
    case metadataChanged(fileId: Int64)
    /// The DB transaction committed (the batch IS applied and
    /// journaled) but one or more external Serato/audio-tag writes
    /// threw afterward. Distinct from a pre-commit throw so the caller
    /// treats the batch as applied and finishes the external side via
    /// `resyncSeratoForBatch(batchId)` — never a re-`applyBatch`, which
    /// would double-journal (issue #836, invariant #2).
    case externalSyncIncomplete(batchId: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(fileId):
            "Mutation referenced file id \(fileId), which is not in the database."
        case .insertDidNotReturnRowId:
            "Database insert did not produce a row id — schema or driver invariant broken."
        case let .eventPayloadDecodingFailed(eventId, batchId, eventType, underlying):
            "Cannot decode event \(eventId.map(String.init) ?? "unknown") (\(eventType.rawValue)) in batch \(batchId): \(underlying)"
        case .payloadEncodingFailed:
            "Could not encode mutation payload as UTF-8 JSON."
        case let .seratoEnumerationFailed(directory, underlying):
            "Failed to enumerate Serato crate files in \(directory): \(underlying)"
        case let .seratoRewriteFailed(path, underlying):
            "Failed to rewrite Serato library file \(path): \(underlying)"
        case let .fileTagWriteFailed(path, underlying):
            "Failed to write audio tags to \(path): \(underlying)"
        case let .trashFailed(path, underlying):
            "Failed to move \(path) to Trash: \(underlying)"
        case let .batchNotFound(batchId):
            "No events were found for batch \(batchId); nothing to undo."
        case let .undoNotSupported(eventType):
            "Events of type \(eventType.rawValue) can't be undone yet."
        case let .missingPreviousTrackIdentifiers(fileId):
            "Cannot revert MusicBrainz match for file id \(fileId): the pre-existing track row has no previous identifiers snapshot to restore."
        case let .matchOwnershipNotFound(fileId):
            "Cannot revert MusicBrainz match for file id \(fileId): no live match by this file was found on its track row."
        case let .fingerprintRecordingConflict(fileId, existingMBID, incomingMBID):
            "Fingerprint collision for file id \(fileId): its fingerprint already identifies recording \(existingMBID), which other files depend on, but this match names \(incomingMBID). Refusing to overwrite the shared identity."
        case let .undoSupersededByLaterMatch(fileId):
            "Can't undo this MusicBrainz match for file id \(fileId): a later match replaced it. Undo the newer match first."
        case let .undoWouldOverwriteFileTags(fileId, fields, direction):
            "Can't \(direction.verb) this MusicBrainz change for file id \(fileId): its audio file's \(fields.joined(separator: ", ")) changed since, and \(direction.gerund) would overwrite that edit."
        case let .undoFileUnavailable(fileId, path, direction):
            "Can't \(direction.verb) this MusicBrainz change for file id \(fileId): \((path as NSString).lastPathComponent) is missing or its drive is offline. Reconnect it, then \(direction.verb) again."
        case let .undoFileUnreadable(fileId, path, reason, direction):
            "Can't \(direction.verb) this MusicBrainz change for file id \(fileId): \(path) can't be read (\(reason))."
        case let .undoFileChangedWhileChecking(fileId, direction):
            "Can't \(direction.verb) this MusicBrainz change for file id \(fileId): its audio file changed while \(direction.verb) was checking it. Try again."
        case let .metadataChanged(fileId):
            "File id \(fileId) metadata changed after it was reviewed. Re-scan before applying."
        case let .externalSyncIncomplete(batchId, underlying):
            "Batch \(batchId) was applied, but some Serato/file writes did not land: \(underlying). Re-sync the batch to finish applying them."
        }
    }
}
