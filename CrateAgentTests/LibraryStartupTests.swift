import Combine
@testable import CrateAgent
import GRDB
import os
import XCTest

@MainActor
final class LibraryStartupTests: XCTestCase {
    func testUnchangedRestartUsesStatEvidenceAndForceRefreshReadsAudio() async throws {
        let fixture = try await LibraryStartupPerformanceFixture(count: 3)
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Cannot clean startup fixture: \(error)") }
        }
        let store = SyncCheckpointStore(database: fixture.database)
        func session() -> SeratoLibrarySyncSession {
            SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler, scanner: fixture.scanner,
                                     operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: fixture.readiness,
                                     checkpointStore: store, watchRoots: [fixture.directory.path])
        }
        try await session().synchronize()
        let checkpoint = try await store.loadHeader()
        XCTAssertNotNil(checkpoint)
        let metrics = LibrarySyncMetrics()
        let restarted = session()
        try await LibrarySyncMetrics.$current.withValue(metrics) { try await restarted.synchronize() }
        guard case .ready = restarted.state else { return XCTFail("Cached startup did not become ready") }
        XCTAssertEqual(metrics.snapshot().snapshotParses, 0)
        XCTAssertEqual(metrics.snapshot().audioTagReads, 0)
        XCTAssertEqual(metrics.snapshot().bitrateReads, 0)
        XCTAssertEqual(metrics.snapshot().lightweightHashReads, 0)
        XCTAssertEqual(metrics.snapshot().stats, 3)
        let forced = LibrarySyncMetrics()
        try await LibrarySyncMetrics.$current.withValue(forced) { try await restarted.synchronize(.forceRefresh) }
        XCTAssertEqual(forced.snapshot().snapshotParses, 1)
        XCTAssertEqual(forced.snapshot().bitrateReads, 3)
    }

    func testCoordinatorStartsValidationAndReleasesReplayOnlyAfterSuccess() async throws {
        let fixture = try await LibraryStartupPerformanceFixture(count: 1)
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Cannot clean startup fixture: \(error)") }
        }
        let session = fixture.makeSession()
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { _ in }, checkpoint: { _ in })
        let coordinator = LibraryStartupCoordinator(session: session, processor: processor, captureBoundary: {
            try await processor.enqueue(.init(observations: [], highestEventID: 0, deliverySequence: 1, replayBoundary: true, historyComplete: true))
            return 1
        })
        coordinator.start()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(session.initialSyncComplete)
        XCTAssertNoThrow(try fixture.readiness.capture())
        do { _ = try await processor.collectStartupReplay(through: 1); XCTFail("Replay remained paused after startup") }
        catch FilesystemReplayError.deliveryActive {}
    }

    func testForcedRescanAfterFailedStartupReleasesWatcherDelivery() async throws {
        let fixture = try await LibraryStartupPerformanceFixture(count: 1)
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Cannot clean startup fixture: \(error)") }
        }
        let session = fixture.makeSession(checkpointed: true)
        let handled = OSAllocatedUnfairLock(initialState: 0)
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { _ in handled.withLock { $0 += 1 } }, checkpoint: { _ in })
        let stream = StartupTestStream(processor: processor)
        let failCapture = OSAllocatedUnfairLock(initialState: true)
        let startup = LibraryStartupCoordinator(session: session, processor: processor, captureBoundary: {
            if failCapture.withLock({ previous in let fail = previous; previous = false; return fail }) {
                throw NSError(domain: "StartupRecoveryFixture", code: 1)
            }
            return try await stream.capture()
        })
        startup.start()
        await startup.waitUntilIdle()
        await session.waitUntilIdle()
        guard case .failed = session.state else { return XCTFail("Startup failure was not visible") }
        startup.requestRescan()
        await startup.waitUntilIdle()
        await session.waitUntilIdle()
        XCTAssertTrue(startup.completed)
        XCTAssertEqual(session.retryRequest(), .forceRefresh)
        try await stream.deliver()
        XCTAssertEqual(handled.withLock { $0 }, 1, "Rescan left the watcher paused")
        XCTAssertNoThrow(try fixture.readiness.capture())
    }

    func testInitialRuntimeDrainFailureLeavesStartupCompleteAndCanBeRetried() async throws {
        let fixture = try await LibraryStartupPerformanceFixture(count: 1)
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Cannot clean startup fixture: \(error)") }
        }
        let session = fixture.makeSession(checkpointed: true)
        let failOnce = OSAllocatedUnfairLock(initialState: true)
        let checkpoints = OSAllocatedUnfairLock(initialState: [UInt64]())
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { _ in
            if failOnce.withLock({ previous in let fail = previous; previous = false; return fail }) {
                throw NSError(domain: "StartupRecoveryFixture", code: 2)
            }
        }, checkpoint: { eventID in checkpoints.withLock { $0.append(eventID) } })
        let startup = LibraryStartupCoordinator(session: session, processor: processor, captureBoundary: {
            try await processor.enqueue(.init(observations: [], highestEventID: 0, deliverySequence: 1, replayBoundary: true, historyComplete: true))
            try await processor.enqueue(.init(observations: [], highestEventID: 2, deliverySequence: 2))
            return 1
        })
        startup.start()
        await startup.waitUntilIdle()
        await session.waitUntilIdle()
        XCTAssertTrue(startup.completed, "Retry must use runtime recovery after delivery activates")
        guard case .failed = session.state else { return XCTFail("Drain failure was hidden") }
        XCTAssertThrowsError(try fixture.readiness.capture())
        session.beginFilesystemRetry()
        try await processor.retry()
        session.finishFilesystemRetry(succeeded: true)
        try await session.synchronize(session.retryRequest(), retryingFailedCleanup: true)
        XCTAssertEqual(checkpoints.withLock { $0 }, [2])
        XCTAssertNoThrow(try fixture.readiness.capture())
    }

    func testReadinessInvalidatedAtReadyPublicationIsRevalidatedAcrossHandoff() async throws {
        let fixture = try await LibraryStartupPerformanceFixture(count: 1)
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Cannot clean startup fixture: \(error)") }
        }
        let session = fixture.makeSession(checkpointed: true)
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { _ in }, checkpoint: { _ in })
        let stream = StartupTestStream(processor: processor)
        let startup = LibraryStartupCoordinator(session: session, processor: processor, captureBoundary: { try await stream.capture() })
        var invalidated = false
        let observation = session.$state.sink { state in
            if case .ready = state, !invalidated {
                invalidated = true
                fixture.readiness.invalidate()
            }
        }
        startup.start()
        await startup.waitUntilIdle()
        XCTAssertTrue(invalidated)
        XCTAssertTrue(startup.completed)
        XCTAssertNoThrow(try fixture.readiness.capture(), "Ready presentation must not conceal an invalid handoff")
        withExtendedLifetime(observation) {}
    }

    func testIncrementalAndForcedRefreshPreserveUnchangedExternalFieldsEditedLocally() async throws {
        let fixture = try await LibraryStartupPerformanceFixture(count: 1)
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Cannot clean startup fixture: \(error)") }
        }
        let session = fixture.makeSession(checkpointed: true)
        try await session.synchronize()
        let files = try await fixture.scanner.identityProjectionsForConflictAnalysis()
        let identifier = try XCTUnwrap(files.first?.id)
        try await fixture.engine.apply(.setMetadata(.init(fileId: identifier, metadata: .init(title: "Local title"))))
        let incrementalMetrics = LibrarySyncMetrics()
        try await LibrarySyncMetrics.$current.withValue(incrementalMetrics) { try await session.synchronize() }
        XCTAssertEqual(incrementalMetrics.snapshot().audioTagReads, 0)
        XCTAssertEqual(incrementalMetrics.snapshot().lightweightHashReads, 0)
        let afterIncremental = try await fixture.scanner.identityProjectionsForConflictAnalysis()
        XCTAssertEqual(afterIncremental.first?.title, "Local title")
        try await session.synchronize(.forceRefresh)
        let afterForced = try await fixture.scanner.identityProjectionsForConflictAnalysis()
        XCTAssertEqual(afterForced.first?.title, "Local title")
    }

    func testPriorConflictRechecksPhysicalIdentityWithUnchangedSavedSource() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("Café.wav")
        try fixture.save(paths: [file.path, file.path.decomposedStringWithCanonicalMapping])
        let scanner = LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator)
        let store = SyncCheckpointStore(database: fixture.database)
        func session() -> SeratoLibrarySyncSession {
            .init(reader: fixture.reader, reconciler: fixture.reconciler, scanner: scanner,
                  operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: gate, checkpointStore: store)
        }
        let first = session()
        try await first.synchronize()
        let source = try SeratoSourceIdentity.read(fixture.locator.databaseV2Url)
        XCTAssertEqual(first.conflicts.count, 1)
        try FileManager.default.removeItem(atPath: file.path)
        let restarted = session()
        try await restarted.synchronize()
        XCTAssertEqual(try SeratoSourceIdentity.read(fixture.locator.databaseV2Url), source)
        XCTAssertEqual(restarted.conflicts.count, 1)
        XCTAssertTrue(restarted.conflicts[0].occurrences.allSatisfy { occurrence in occurrence.observation == .missing })
        XCTAssertThrowsError(try gate.capture().check(target: .file(file)))
    }

    func testStartupWaitsForSeratoAndCloseAutomaticallyValidates() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let scanner = LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator)
        let session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler, scanner: scanner,
                                               operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: gate,
                                               checkpointStore: SyncCheckpointStore(database: fixture.database))
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { _ in }, checkpoint: { _ in })
        let stream = StartupTestStream(processor: processor)
        let startup = LibraryStartupCoordinator(session: session, processor: processor, captureBoundary: { try await stream.capture() })
        let lifecycle = SeratoSyncCoordinator(session: session, seratoWatchdog: fixture.watchdog, startup: startup)
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        startup.start()
        await startup.waitUntilIdle()
        XCTAssertEqual(session.state, .waitingForSerato)
        XCTAssertThrowsError(try gate.capture())
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        await startup.waitUntilIdle()
        XCTAssertTrue(startup.completed)
        XCTAssertNoThrow(try gate.capture())
        withExtendedLifetime(lifecycle) {}
    }

    func testLateDeliveredEventInvalidatesCandidateBeforeProcessingStarts() async throws {
        let fixture = try await LibraryStartupPerformanceFixture(count: 1)
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Cannot clean startup fixture: \(error)") }
        }
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { _ in }, checkpoint: { _ in })
        let stream = StartupTestStream(processor: processor)
        var injectLateEvent = true
        let session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler, scanner: fixture.scanner,
                                               operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: fixture.readiness,
                                               startProcessing: {
                                                   if injectLateEvent {
                                                       injectLateEvent = false
                                                       do { try await stream.deliver() }
                                                       catch { XCTFail("Late delivery failed: \(error)") }
                                                   }
                                               }, checkpointStore: SyncCheckpointStore(database: fixture.database))
        let startup = LibraryStartupCoordinator(session: session, processor: processor, captureBoundary: { try await stream.capture() })
        startup.start()
        await startup.waitUntilIdle()
        XCTAssertTrue(startup.completed)
        let captures = await stream.captures
        XCTAssertEqual(captures, 2)
        XCTAssertNoThrow(try fixture.readiness.capture())
    }

    func testStartupReplayEstablishesLegacyMembershipBeforeApplyingRename() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("legacy.wav", membership: .legacyUnverified, bytes: FinalRemovalIntegrationTests.wav())
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let destination = fixture.directory.appendingPathComponent("moved.wav").path
        try FileManager.default.moveItem(atPath: file.path, toPath: destination)
        let scanner = LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator)
        let session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler, scanner: scanner,
                                               operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: gate,
                                               checkpointStore: SyncCheckpointStore(database: fixture.database))
        let filesystem = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { _ in }, checkpoint: { _ in })
        let startup = LibraryStartupCoordinator(session: session, processor: processor, captureBoundary: {
            try await processor.enqueue(.init(observations: [.init(path: destination, isFile: true, wasRenamed: true)], highestEventID: 1, deliverySequence: 1))
            try await processor.enqueue(.init(observations: [], highestEventID: 1, deliverySequence: 2, replayBoundary: true, historyComplete: true))
            return 2
        }, replay: { batch in try await filesystem.handleBatch(batch) })
        startup.start()
        await startup.waitUntilIdle()
        XCTAssertTrue(startup.completed, "\(session.state)")
        let current = try await fixture.row(file)
        XCTAssertEqual(current.libraryMembership, .active)
        XCTAssertEqual(current.path, destination)
        let saved = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path)
        XCTAssertEqual(saved.map { record in SeratoPath.normalized(record.path) }, [destination])
    }

    func testKnownConflictBlockedWritesKeepIndependentProcessingReady() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("Café.wav", bytes: FinalRemovalIntegrationTests.wav())
        try fixture.save(paths: [file.path])
        let scanner = LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator)
        let session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler, scanner: scanner,
                                               operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: gate,
                                               checkpointStore: SyncCheckpointStore(database: fixture.database))
        try await session.synchronize()
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Queued"), previousMetadata: .empty)))
        try fixture.save(paths: [file.path, file.path.decomposedStringWithCanonicalMapping])
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await session.synchronize()
        XCTAssertNoThrow(try gate.capture())
        XCTAssertThrowsError(try gate.capture().check(target: .file(file)))
        let queued = await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(queued, 1)
    }

    func testConcurrentLocalEditDuringParsingIsNotOverwrittenBeforeRevisionFailure() async throws {
        let fixture = try await LibraryStartupPerformanceFixture(count: 1)
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Cannot clean startup fixture: \(error)") }
        }
        try await fixture.makeSession(checkpointed: true).synchronize()
        let files = try await fixture.scanner.identityProjectionsForConflictAnalysis()
        let file = try XCTUnwrap(files.first)
        _ = try updateDatabaseRecord(databasePath: fixture.locator.databaseV2Url.path, trackPath: file.path,
                                     update: SeratoMetadataUpdate(artist: nil, title: "External changed", album: nil, genre: nil,
                                                                  bpm: nil, key: nil, comment: nil, length: nil, label: nil))
        let barrier = SessionBarrier()
        let reader = SeratoMembershipSnapshotReader(locator: fixture.locator, watchdog: fixture.watchdog, afterParsing: { await barrier.pauseFirst() })
        let session = SeratoLibrarySyncSession(reader: reader,
                                               reconciler: SeratoMembershipReconciler(database: fixture.database, operationEngine: fixture.engine, reader: reader),
                                               scanner: fixture.scanner, operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: fixture.readiness,
                                               checkpointStore: SyncCheckpointStore(database: fixture.database))
        let syncing = Task { try await session.synchronize() }
        await barrier.waitForEntry()
        let identifier = try XCTUnwrap(file.id)
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET title = ? WHERE id = ?", arguments: ["Later local edit", identifier])
        }
        await barrier.release()
        do { try await syncing.value; XCTFail("Concurrent write authorized an older candidate") } catch {}
        let retained = try await fixture.scanner.identityProjectionsForConflictAnalysis()
        XCTAssertEqual(retained.first?.title, "Later local edit")
        XCTAssertThrowsError(try fixture.readiness.capture())
    }

    func testFileInfoFailureIsVisibleAndRetriedButSuccessfulAbsentBitrateIsCached() async throws {
        let fixture = try await LibraryStartupPerformanceFixture(count: 1)
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Cannot clean startup fixture: \(error)") }
        }
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET bitrate_kbps = 999")
        }
        let fails = OSAllocatedUnfairLock(initialState: true)
        let scanner = LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator,
                                     identityReader: { path in try FileMetadataCollector.collectVerified(at: path) },
                                     bitrateReader: { _ in
                                         if fails.withLock({ value in value }) {
                                             throw CocoaError(.fileReadUnknown)
                                         }
                                         return nil
                                     })
        let store = SyncCheckpointStore(database: fixture.database)
        let session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler, scanner: scanner,
                                               operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: fixture.readiness, checkpointStore: store)
        try await session.synchronize()
        XCTAssertEqual(session.fileInfoFailures.count, 1)
        let failed = try await store.load()
        XCTAssertEqual(failed?.files.first?.bitrateProbed, false)
        XCTAssertNotNil(failed?.files.first?.bitrateError)
        fails.withLock { value in value = false }
        try await session.synchronize()
        XCTAssertTrue(session.fileInfoFailures.isEmpty)
        let completed = try await store.load()
        XCTAssertEqual(completed?.files.first?.bitrateProbed, true)
        let files = try await scanner.identityProjectionsForConflictAnalysis()
        XCTAssertNil(files.first?.bitrateKbps)
        let metrics = LibrarySyncMetrics()
        try await LibrarySyncMetrics.$current.withValue(metrics) { try await session.synchronize() }
        XCTAssertEqual(metrics.snapshot().bitrateReads, 0)
        XCTAssertEqual(metrics.snapshot().audioTagReads, 0)
    }

    func testCancelledStartupKeepsReplayPausedAndDoesNotPublishCheckpoint() async throws {
        let fixture = try await LibraryStartupPerformanceFixture(count: 1)
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Cannot clean startup fixture: \(error)") }
        }
        let barrier = SessionBarrier()
        let reader = SeratoMembershipSnapshotReader(locator: fixture.locator, watchdog: fixture.watchdog, afterParsing: { await barrier.pauseFirst() })
        let store = SyncCheckpointStore(database: fixture.database)
        let session = SeratoLibrarySyncSession(reader: reader,
                                               reconciler: SeratoMembershipReconciler(database: fixture.database, operationEngine: fixture.engine, reader: reader),
                                               scanner: fixture.scanner, operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: fixture.readiness, checkpointStore: store)
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { _ in }, checkpoint: { _ in XCTFail("Cancelled startup acknowledged replay") })
        let stream = StartupTestStream(processor: processor)
        let startup = LibraryStartupCoordinator(session: session, processor: processor, captureBoundary: { try await stream.capture() })
        startup.start()
        await barrier.waitForEntry()
        startup.stop()
        await barrier.release()
        await startup.waitUntilIdle()
        let header = try await store.loadHeader()
        XCTAssertNil(header)
        XCTAssertFalse(startup.completed)
        XCTAssertThrowsError(try fixture.readiness.capture())
        _ = try await processor.collectStartupReplay(through: 1)
    }

    func testStartupFinishesPendingImportBeforePublishingCheckpoint() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("pending.wav", membership: .pendingImport, bytes: FinalRemovalIntegrationTests.wav())
        try await fixture.engine.apply(.addTrackToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .empty)))
        let store = SyncCheckpointStore(database: fixture.database)
        let scanner = LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator)
        let session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler, scanner: scanner,
                                               operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: gate, checkpointStore: store)
        try await session.synchronize()
        let current = try await fixture.row(file)
        XCTAssertEqual(current.libraryMembership, .active)
        let effects = try await store.pendingEffects()
        XCTAssertTrue(effects.isEmpty)
        let checkpoint = try await store.loadHeader()
        XCTAssertNotNil(checkpoint)
        XCTAssertNoThrow(try gate.capture())
    }
}

private actor StartupTestStream {
    let processor: FilesystemEventProcessor
    var sequence: UInt64 = 0
    var captures = 0
    init(processor: FilesystemEventProcessor) {
        self.processor = processor
    }

    func capture() async throws -> UInt64 {
        sequence += 1
        captures += 1
        try await processor.enqueue(.init(observations: [], highestEventID: 0, deliverySequence: sequence, replayBoundary: true, historyComplete: true))
        return sequence
    }

    func deliver() async throws {
        sequence += 1
        try await processor.enqueue(.init(observations: [.init(path: "/fixture/late", isFile: true)], highestEventID: 1, deliverySequence: sequence))
    }
}
