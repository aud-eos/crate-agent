import Combine
import Foundation

private struct LibrarySyncFailure: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

@MainActor
final class SeratoLibrarySyncSession: ObservableObject {
    enum State: Equatable {
        case idle
        case waitingForSerato
        case reconciling
        case ready(ReconciliationSummary)
        case failed(String)
    }

    enum SyncPhase: String { case validating = "Validating saved state", replaying = "Catching up on changes", parsing = "Reading Serato library", reconciling = "Checking library membership", refreshing = "Refreshing file info", draining = "Applying queued changes" }
    @Published private(set) var phase: SyncPhase? {
        didSet { LibrarySyncMetrics.current?.transition(to: phase?.rawValue) }
    }

    @Published private(set) var fileInfoFailures: [String] = []
    private var startupReplay: FilesystemReplayReceipt?
    private var startupReplayHandler: (@Sendable (FilesystemEventBatch) async throws -> Void)?
    private(set) var retainedStartupObservations: [FSEventsObservation] = []
    private(set) var validationWasSuperseded = false

    func prepareStartupReplay(_ receipt: FilesystemReplayReceipt, handler: @escaping @Sendable (FilesystemEventBatch) async throws -> Void) {
        startupReplay = receipt
        startupReplayHandler = handler
        retainedStartupObservations = []
    }

    func clearStartupReplay() {
        startupReplay = nil
        startupReplayHandler = nil
        retainedStartupObservations = []
    }

    func retryRequest() -> LibrarySyncRequest {
        lastRequest
    }

    private let checkpointStore: SyncCheckpointStore?
    private let watchRoots: [String]
    private var pendingRequest = LibrarySyncRequest.incremental
    private var lastRequest = LibrarySyncRequest.incremental
    @Published private(set) var state: State = .idle
    @Published private(set) var initialSyncComplete = false
    @Published private(set) var conflicts: [SeratoPathConflict] = []
    @Published private(set) var conflictsAreStale = false
    @Published private(set) var scanProgress: LibraryScanner.ScanProgress?
    private let reader: SeratoMembershipSnapshotReader
    private let reconciler: SeratoMembershipReconciler
    private let scanner: LibraryScanner
    private let conflictAnalyzer: SeratoConflictAnalyzer
    private let operationEngine: OperationEngine
    private let watchdog: SeratoWatchdog
    let readiness: LibrarySyncReadiness
    private let stopProcessing: @MainActor () async -> Void
    private let startProcessing: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var requested = false
    private var filesystemFailure: String?
    private var filesystemRetryActive = false
    private var requestGeneration: UInt64 = 0
    private var successfulGeneration: UInt64?
    private var retryingFailedCleanup = false

    init(reader: SeratoMembershipSnapshotReader, reconciler: SeratoMembershipReconciler,
         scanner: LibraryScanner, operationEngine: OperationEngine, watchdog: SeratoWatchdog,
         readiness: LibrarySyncReadiness, stopProcessing: @escaping @MainActor () async -> Void = {},
         startProcessing: @escaping @MainActor () async -> Void = {},
         conflictAnalyzer: SeratoConflictAnalyzer = SeratoConflictAnalyzer(),
         checkpointStore: SyncCheckpointStore? = nil, watchRoots: [String] = [])
    {
        self.checkpointStore = checkpointStore
        self.watchRoots = watchRoots
        self.reader = reader
        self.reconciler = reconciler
        self.scanner = scanner
        self.conflictAnalyzer = conflictAnalyzer
        self.operationEngine = operationEngine
        self.watchdog = watchdog
        self.readiness = readiness
        self.stopProcessing = stopProcessing
        self.startProcessing = startProcessing
    }

    func requestSync(_ request: LibrarySyncRequest = .incremental) {
        if request == .forceRefresh {
            pendingRequest = .forceRefresh
        }
        requestGeneration += 1
        successfulGeneration = nil
        if let filesystemFailure, !filesystemRetryActive {
            state = .failed(filesystemFailure)
            return
        }
        requested = true
        readiness.invalidate()
        conflictsAreStale = !conflicts.isEmpty
        guard task == nil else { return }
        let metrics = LibrarySyncMetrics.current ?? LibrarySyncMetrics()
        task = Task { [weak self] in
            await SyncRevisionAccounting.$current.withValue(SyncRevisionAccounting()) {
                await LibrarySyncMetrics.$current.withValue(metrics) { await self?.run() }
            }
        }
    }

    func waitUntilIdle() async {
        while let task {
            await task.value
        }
    }

    func stopSync() {
        successfulGeneration = nil
        requested = false
        readiness.invalidate()
        conflictsAreStale = !conflicts.isEmpty
        task?.cancel()
        scanProgress = nil
        state = .idle
    }

    func synchronize(_ request: LibrarySyncRequest = .incremental, retryingFailedCleanup: Bool = false) async throws {
        self.retryingFailedCleanup = self.retryingFailedCleanup || retryingFailedCleanup
        requestSync(request)
        let requiredGeneration = requestGeneration
        await waitUntilIdle()
        try Task.checkCancellation()
        guard let successfulGeneration, successfulGeneration >= requiredGeneration,
              successfulGeneration == requestGeneration
        else {
            if case let .failed(message) = state {
                throw LibrarySyncFailure(message: message)
            }
            if case .waitingForSerato = state {
                throw SeratoMembershipSnapshotError.seratoRunning
            }
            throw LibrarySyncReadinessError.synchronizationRequired
        }
    }

    func suspend() {
        successfulGeneration = nil
        requested = false
        readiness.invalidate()
        conflictsAreStale = !conflicts.isEmpty
        task?.cancel()
        state = .waitingForSerato
    }

    func reportFailure(_ message: String) {
        successfulGeneration = nil
        requested = false
        readiness.invalidate()
        conflictsAreStale = !conflicts.isEmpty
        task?.cancel()
        state = .failed(message)
        if task == nil {
            task = Task { [weak self] in
                guard let self else { return }
                await stopProcessing()
                task = nil
                if requested {
                    requestSync()
                }
            }
        }
    }

    func reportFilesystemFailure(_ message: String) {
        filesystemFailure = message
        reportFailure(message)
    }

    func beginFilesystemRetry() {
        filesystemRetryActive = true
        readiness.invalidate()
        conflictsAreStale = !conflicts.isEmpty
    }

    func finishFilesystemRetry(succeeded: Bool) {
        filesystemRetryActive = false
        if succeeded {
            filesystemFailure = nil
        }
    }

    func seratoStateChanged(isRunning: Bool) {
        if isRunning {
            if task != nil {
                suspend()
            }
        } else {
            switch state {
            case .waitingForSerato, .ready:
                successfulGeneration = nil
                readiness.invalidate()
                conflictsAreStale = !conflicts.isEmpty
                state = .idle
            case .idle, .reconciling, .failed:
                break
            }
        }
    }

    private func run() async {
        defer {
            retryingFailedCleanup = false
            task = nil
            scanProgress = nil
            phase = nil
            if requested {
                requestSync()
            }
        }
        await stopProcessing()
        var cumulativeChanges = ReconciliationSummary()
        do {
            while requested {
                requested = false
                let generation = requestGeneration
                let request = pendingRequest
                lastRequest = request
                pendingRequest = .incremental
                try Task.checkCancellation()
                try await operationEngine.recoverInterruptedEffects()
                watchdog.refresh()
                guard !watchdog.isSeratoRunning else { pendingRequest = request; state = .waitingForSerato; return }
                state = .reconciling
                let authorization = readiness.prepareDrain()
                phase = .validating
                let header: SyncCheckpointHeader?
                do {
                    let saved = try await checkpointStore?.loadHeader()
                    header = saved?.complete == true ? saved : nil
                } catch SyncCheckpointError.malformed where request == .forceRefresh { header = nil }
                catch is DecodingError where request == .forceRefresh { header = nil }
                let baseRevision = try await checkpointStore?.currentRevision()
                SyncRevisionAccounting.current?.begin(at: baseRevision)
                let ownRevisionStart = SyncRevisionAccounting.current?.changes ?? 0
                validationWasSuperseded = false
                let stats: SyncStatValidation? = if let checkpointStore, let baseRevision, header != nil, request != .forceRefresh {
                    try await checkpointStore.validateFileStats(expectedRevision: baseRevision)
                } else {
                    nil
                }
                let cachedSource: SeratoSnapshotAuthorization?
                if let header, header.watchRoots == watchRoots, request != .forceRefresh {
                    do { cachedSource = try await reader.authorizeCachedSource(libraryID: header.libraryID, source: header.source) }
                    catch SeratoMembershipSnapshotError.sourceChanged { cachedSource = nil }
                } else {
                    cachedSource = nil
                }
                let pendingWork = try await operationEngine.hasPendingSynchronizationWork
                if let checkpointStore, let header, let baseRevision, let cachedSource,
                   header.complete, !header.hadConflicts, header.localRevision == baseRevision,
                   stats?.changedFileIDs.isEmpty == true, !pendingWork, !filesystemRetryActive,
                   startupReplay?.observations.isEmpty != false
                {
                    try readiness.install(.init(), for: authorization)
                    try await checkpointStore.authorizeReady(expectedRevision: baseRevision, source: cachedSource, ready: authorization)
                    let processingAuthorization = try readiness.capture()
                    await SyncRevisionAccounting.$current.withValue(nil) { await startProcessing() }
                    try processingAuthorization.check()
                    try Task.checkCancellation()
                    if requested {
                        await stopProcessing(); continue
                    }
                    conflicts = []
                    conflictsAreStale = false
                    fileInfoFailures = []
                    initialSyncComplete = true
                    successfulGeneration = generation
                    state = .ready(.init())
                    continue
                }
                let checkpoint: LibrarySyncCheckpoint?
                do { checkpoint = header == nil ? nil : try await checkpointStore?.load() }
                catch SyncCheckpointError.malformed where request == .forceRefresh { checkpoint = nil }
                catch is DecodingError where request == .forceRefresh { checkpoint = nil }
                phase = .parsing
                let snapshot: SeratoMembershipSnapshot = if cachedSource != nil, let checkpoint {
                    try reader.cachedSnapshot(records: checkpoint.records.map { record in try record.record() })
                } else {
                    try await reader.read()
                }
                var validatedSnapshot = snapshot
                var files = try await scanner.identityProjectionsForConflictAnalysis()
                phase = .reconciling
                var analysis = try await analyze(snapshot, authorization: authorization, files: files)
                if let startupReplay, let startupReplayHandler, !startupReplay.observations.isEmpty {
                    let legacyIDs = Set(files.filter { file in file.libraryMembership == .legacyUnverified }.compactMap(\.id))
                    if !legacyIDs.isEmpty {
                        let legacyPlan = LibraryRefreshPlan(indexedFiles: files, metadataPaths: [], refreshPaths: [], reconcileFileIDs: legacyIDs, evidence: [:])
                        _ = try await reconciler.reconcile(snapshot, analysis: analysis, plan: legacyPlan)
                    }
                    phase = .replaying
                    do { try await startupReplayHandler(.init(observations: startupReplay.observations, highestEventID: startupReplay.eventID)) }
                    catch let deferred as FilesystemConflictDeferral { retainedStartupObservations = deferred.observations }
                    self.startupReplayHandler = nil
                    try await reader.validate(snapshot)
                    files = try await scanner.identityProjectionsForConflictAnalysis()
                    analysis = try await analyze(snapshot, authorization: authorization, files: files)
                }
                let dirty = try await checkpointStore?.dirtyFiles()
                var evidence = Dictionary(uniqueKeysWithValues: (checkpoint?.files ?? []).map { file in (file.fileID, file) })
                let plan: LibraryRefreshPlan? = if checkpointStore != nil {
                    try await LibraryRefreshPlanner(evidence: evidence, validatedFileIDs: stats?.validatedFileIDs ?? [])
                        .makePlan(request: request, snapshot: snapshot, indexedFiles: files,
                                  previousRecords: checkpoint?.records.map { record in try record.record() } ?? [],
                                  dirtyFileIDs: dirty?.fileIDs ?? [], dirtyPaths: dirty?.paths ?? [], analysis: analysis)
                } else {
                    nil
                }
                var summary = try await reconciler.reconcile(snapshot, analysis: analysis, plan: plan)
                cumulativeChanges.retired += summary.retired
                cumulativeChanges.reactivated += summary.reactivated
                phase = .refreshing
                try await refreshMetadata(snapshot, analysis: analysis, plan: plan)
                await evidence.merge(scanner.evidenceAfterLastScan()) { _, refreshed in refreshed }
                try await reader.validate(snapshot)
                try Task.checkCancellation()
                if requested {
                    continue
                }
                if filesystemRetryActive {
                    successfulGeneration = generation
                    if let filesystemFailure {
                        state = .failed(filesystemFailure)
                    }
                    return
                }
                let revision = watchdog.stateRevision
                phase = .draining
                let drain = try await LibrarySyncReadiness.$drainAuthorization.withValue(authorization) {
                    try await operationEngine.drainPendingSeratoUpdates(retryingFailedCleanup: retryingFailedCleanup)
                }
                retryingFailedCleanup = false
                summary.conflictBlockedWriteCount = drain.conflictBlockedCount
                summary.duplicateCleanupMessage = try await operationEngine.duplicateCleanupMessage
                if drain.appliedCount > 0, checkpointStore != nil {
                    requested = true
                    pendingRequest = request
                    continue
                }
                if drain.appliedCount > 0 {
                    let refreshedSnapshot = try await reader.read()
                    validatedSnapshot = refreshedSnapshot
                    analysis = try await analyze(refreshedSnapshot, authorization: authorization)
                    try await refreshMetadata(refreshedSnapshot, analysis: analysis)
                    try await reader.validate(refreshedSnapshot)
                }
                try Task.checkCancellation()
                guard watchdog.isClosed(atRevision: revision) else { throw SeratoMembershipSnapshotError.seratoRunning }
                if requested {
                    continue
                }
                try await reader.validate(validatedSnapshot)
                try Task.checkCancellation()
                if let checkpointStore, let baseRevision {
                    let ownChanges = (SyncRevisionAccounting.current?.changes ?? 0) - ownRevisionStart
                    let expectedRevision = baseRevision + ownChanges
                    let finalFiles = try await scanner.identityProjectionsForConflictAnalysis()
                    let retainedEvidence = finalFiles.compactMap { file -> SyncFileEvidence? in
                        guard let identifier = file.id, let stored = evidence[identifier], stored.identity == file.identity,
                              stored.membershipRevision == file.membershipRevision else { return nil }
                        return stored
                    }
                    let header = SyncCheckpointHeader(libraryID: validatedSnapshot.libraryID, source: validatedSnapshot.source,
                                                      localRevision: expectedRevision, watchRoots: watchRoots,
                                                      eventID: (retainedStartupObservations.isEmpty ? startupReplay?.eventID : nil) ?? checkpoint?.header.eventID ?? 0,
                                                      hadConflicts: !analysis.conflicts.isEmpty)
                    if !drain.blockedQueueIDs.isEmpty {
                        try await checkpointStore.authorizeReady(expectedRevision: expectedRevision, source: reader.authorization(for: validatedSnapshot),
                                                                 ready: authorization, allowedQueueIDs: drain.blockedQueueIDs)
                    } else {
                        try await checkpointStore.publish(.init(header: header, records: validatedSnapshot.records.map(SavedSeratoOccurrence.init), files: retainedEvidence),
                                                          expectedRevision: expectedRevision, sourceAuthorization: reader.authorization(for: validatedSnapshot), ready: authorization)
                    }
                } else {
                    try readiness.markReady(authorization)
                }
                let processingAuthorization = try readiness.capture()
                await SyncRevisionAccounting.$current.withValue(nil) { await startProcessing() }
                if requested {
                    await stopProcessing()
                    continue
                }
                try processingAuthorization.check()
                try Task.checkCancellation()
                if requested {
                    await stopProcessing()
                    continue
                }
                try processingAuthorization.check()
                let dispositions = try await operationEngine.takeUnreportedDispositions()
                summary.supersededWrites = dispositions.notApplied
                summary.interruptedWrites = dispositions.interrupted
                summary.retired = cumulativeChanges.retired
                summary.reactivated = cumulativeChanges.reactivated
                summary.pathConflictCount = analysis.conflicts.count
                conflicts = analysis.conflicts
                conflictsAreStale = false
                initialSyncComplete = true
                successfulGeneration = generation
                state = .ready(summary)
            }
        } catch {
            validationWasSuperseded = error is LibrarySyncReadinessError || (error as? SeratoMembershipSnapshotError) == .sourceChanged
            if case SyncCheckpointError.changed = error {
                validationWasSuperseded = true
            }
            successfulGeneration = nil
            readiness.invalidate()
            conflictsAreStale = !conflicts.isEmpty
            await stopProcessing()
            if !Task.isCancelled {
                state = watchdog.isSeratoRunning ? .waitingForSerato : .failed("Library sync failed: \(error.localizedDescription)")
            }
        }
    }

    private func analyze(_ snapshot: SeratoMembershipSnapshot, authorization: LibrarySyncReadiness.Authorization, files suppliedFiles: [FileRecord]? = nil) async throws -> SeratoConflictAnalysis {
        let files: [FileRecord] = if let suppliedFiles {
            suppliedFiles
        } else {
            try await scanner.identityProjectionsForConflictAnalysis()
        }
        let analysis = try await conflictAnalyzer.analyze(snapshot: snapshot, files: files)
        try await reader.validate(snapshot)
        try Task.checkCancellation()
        try readiness.install(analysis.scope, for: authorization)
        return analysis
    }

    private func refreshMetadata(_ snapshot: SeratoMembershipSnapshot, analysis: SeratoConflictAnalysis, plan: LibraryRefreshPlan? = nil) async throws {
        let progressStream = AsyncStream<LibraryScanner.ScanProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { [weak self] in
            for await progress in progressStream.stream {
                guard !Task.isCancelled else { return }
                self?.scanProgress = progress
            }
        }
        defer {
            progressStream.continuation.finish()
            consumer.cancel()
        }
        let result = try await scanner.scan(snapshot: snapshot, reader: reader, analysis: analysis, plan: plan) { progress in
            progressStream.continuation.yield(progress)
        }
        fileInfoFailures = result.fileInfoFailures
        progressStream.continuation.finish()
        await consumer.value
    }
}
