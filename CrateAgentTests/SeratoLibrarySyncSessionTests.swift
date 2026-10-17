import Combine
@testable import CrateAgent
import Foundation
import GRDB
import XCTest

@MainActor
final class SeratoLibrarySyncSessionTests: XCTestCase {
    func testPlannedExternalMetadataChangeDoesNotReadAudioOrTouchUnchangedTrack() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let changed = try await fixture.add("changed.wav")
        let untouched = try await fixture.add("untouched.wav")
        let files = [changed, untouched]
        try fixture.save(paths: files.map(\.path))
        let previous = try await fixture.reader.read()
        var evidence: [Int64: SyncFileEvidence] = [:]
        var baselines: [FileMembershipToken: SeratoMetadata] = [:]
        for file in files {
            let identifier = try XCTUnwrap(file.id)
            evidence[identifier] = try SyncFileEvidence(fileID: identifier, membershipRevision: file.membershipRevision,
                                                        identity: file.identity, readIdentity: AudioFileReadIdentity.read(at: file.path), bitrateProbed: true)
            baselines[FileMembershipToken(fileId: identifier, revision: file.membershipRevision)] = .empty
        }
        let savedBaselines = baselines
        try await fixture.database.writer.write { database in
            for (token, metadata) in savedBaselines {
                try SeratoExternalBaselines.save(metadata, token: token, in: database)
            }
        }
        let bytes = try SeratoTestEncoding.record("vrsn", XCTUnwrap("2.0/Serato Scratch LIVE Database".data(using: .utf16BigEndian)))
            + SeratoTestEncoding.record("otrk", SeratoTestEncoding.record("pfil", XCTUnwrap(changed.path.data(using: .utf16BigEndian)))
                + SeratoTestEncoding.record("tsng", XCTUnwrap("External title".data(using: .utf16BigEndian))))
            + SeratoTestEncoding.record("otrk", SeratoTestEncoding.record("pfil", XCTUnwrap(untouched.path.data(using: .utf16BigEndian))))
        try bytes.write(to: fixture.locator.databaseV2Url)
        let snapshot = try await fixture.reader.read()
        let analysis = try await SeratoConflictAnalyzer().analyze(snapshot: snapshot, files: files)
        let planner = LibraryRefreshPlanner(evidence: evidence, validatedFileIDs: Set(files.compactMap(\.id)))
        let plan = try await planner.makePlan(request: .incremental, snapshot: snapshot, indexedFiles: files,
                                              previousRecords: previous.records, dirtyFileIDs: [], dirtyPaths: [], analysis: analysis)
        let scanner = LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator,
                                     identityReader: { _ in XCTFail("Metadata-only scan hashed audio"); throw SyncCheckpointError.changed },
                                     bitrateReader: { _ in XCTFail("Metadata-only scan probed audio"); return nil })
        let metrics = LibrarySyncMetrics()
        try await LibrarySyncMetrics.$current.withValue(metrics) {
            _ = try await fixture.reconciler.reconcile(snapshot, analysis: analysis, plan: plan)
            _ = try await scanner.scan(snapshot: snapshot, reader: fixture.reader, analysis: analysis, plan: plan)
        }
        let updated = try await fixture.row(changed)
        let retained = try await fixture.row(untouched)
        XCTAssertEqual(updated.title, "External title")
        XCTAssertEqual(retained, untouched)
        XCTAssertEqual(metrics.snapshot().lightweightHashReads, 0)
        XCTAssertEqual(metrics.snapshot().audioTagReads, 0)
        let events = try await fixture.events()
        XCTAssertEqual(events, 1)
        let unchanged = try await planner.makePlan(request: .incremental, snapshot: snapshot, indexedFiles: [updated, retained],
                                                   previousRecords: snapshot.records, dirtyFileIDs: [], dirtyPaths: [], analysis: analysis)
        _ = try await scanner.scan(snapshot: snapshot, reader: fixture.reader, analysis: analysis, plan: unchanged)
        let repeated = try await fixture.events()
        XCTAssertEqual(repeated, events)
    }

    func testPlannedMetadataObservationRejectsLaterLocalEdit() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("later-edit.wav")
        try fixture.save(paths: [file.path])
        let snapshot = try await fixture.reader.read()
        let identifier = try XCTUnwrap(file.id)
        let evidence = try AudioFileReadIdentity.read(at: file.path)
        let authorization = try await fixture.reader.authorization(for: snapshot)
        let observation = ObserveFileIdentityPayload(fileId: identifier, expectedRevision: file.membershipRevision,
                                                     previousIdentity: file.identity, identity: file.identity,
                                                     metadata: .init(title: "External title"), expectedState: file.libraryState)
        try await fixture.engine.apply(.setMetadata(.init(fileId: identifier, metadata: .init(title: "Newer local title"))))
        do {
            _ = try await fixture.engine.observeSnapshotMetadata(observation, authorization: authorization,
                                                                 metadataEvidence: evidence, expectedMetadata: file.seratoMetadata)
            XCTFail("Older observation overwrote a later local edit")
        } catch FileProcessingEligibilityError.superseded {}
        let retained = try await fixture.row(file)
        XCTAssertEqual(retained.title, "Newer local title")
        let events = try await fixture.events()
        XCTAssertEqual(events, 1)
    }

    func testConflictSyncRetiresOnlyIndependentRowsAndRetainsStaleDetailsUntilValidatedRepair() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let protected = try await fixture.add("Café.mp3")
        let removed = try await fixture.add("removed.mp3")
        try fixture.save(paths: [protected.path, protected.path.decomposedStringWithCanonicalMapping])
        let session = makeSession(fixture, gate: gate)
        try await session.synchronize()
        guard case let .ready(summary) = session.state else { return XCTFail("\(session.state)") }
        XCTAssertEqual(summary.pathConflictCount, 1)
        XCTAssertEqual(summary.retired, 1)
        let protectedAfter = try await fixture.row(protected)
        let removedAfter = try await fixture.row(removed)
        XCTAssertEqual(protectedAfter, protected)
        XCTAssertEqual(removedAfter.libraryMembership, .retired)
        let protectedEvents = try await fixture.database.writer.read { connection in try EventRecord.filter(Column("file_id") == protected.id).fetchCount(connection) }
        XCTAssertEqual(protectedEvents, 0)
        XCTAssertThrowsError(try gate.capture().check(target: .file(protected)))
        XCTAssertNoThrow(try gate.capture())
        XCTAssertFalse(session.conflictsAreStale)
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        session.suspend()
        XCTAssertTrue(session.conflictsAreStale)
        XCTAssertEqual(session.conflicts.count, 1)
        XCTAssertThrowsError(try gate.capture())
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try Data([1, 2]).write(to: fixture.locator.databaseV2Url)
        do { try await session.synchronize(); XCTFail("Corrupt source cleared protection") } catch {}
        XCTAssertTrue(session.conflictsAreStale)
        XCTAssertEqual(session.conflicts.count, 1)
        XCTAssertThrowsError(try gate.requireUnconflicted(.file(protected)))
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: protected.path)])
        try await session.synchronize()
        XCTAssertTrue(session.conflicts.isEmpty)
        XCTAssertFalse(session.conflictsAreStale)
        XCTAssertNoThrow(try gate.capture().check(target: .file(protected)))
    }

    func testDirectScannerProtectsConflictsAndRejectsMismatchedAnalysis() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("Café.mp3")
        try fixture.save(paths: [file.path, file.path.decomposedStringWithCanonicalMapping])
        let scanner = LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator)
        let snapshot = try await fixture.reader.read()
        let wrong = SeratoConflictAnalysis(source: snapshot.source, libraryID: snapshot.libraryID, generation: snapshot.generation + 1, conflicts: [], scope: .init())
        do { _ = try await scanner.scan(snapshot: snapshot, reader: fixture.reader, analysis: wrong); XCTFail("Mismatched analysis accepted") }
        catch SeratoMembershipSnapshotError.sourceChanged {}
        _ = try await scanner.scan(snapshot: snapshot, reader: fixture.reader)
        XCTAssertThrowsError(try gate.capture())
        XCTAssertThrowsError(try gate.requireUnconflicted(.file(file)))
        do { _ = try await scanner.scan(); XCTFail("Legacy scan accepted ambiguous saved records") }
        catch is SeratoPathConflictError {}
        let row = try await fixture.row(file)
        let events = try await fixture.events()
        XCTAssertEqual(row, file)
        XCTAssertEqual(events, 0)
    }

    func testConflictQueueRetainsOrderedIntentWhileIndependentWritesDrainAndRepairRevalidates() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let protected = try await fixture.add("Café.mp3")
        let independent = try await fixture.add("independent.mp3")
        let savedPaths = [protected.path, independent.path].map(SeratoLibraryLocator.seratoRelativePath)
        try fixture.save(paths: savedPaths)
        let session = makeSession(fixture, gate: gate)
        try await session.synchronize()
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        for (file, metadata) in [(protected, SeratoMetadata(title: "Queued title")), (protected, SeratoMetadata(artist: "Queued artist")), (independent, SeratoMetadata(title: "Independent"))] {
            try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: metadata, previousMetadata: .empty)))
        }
        try fixture.save(paths: savedPaths + [savedPaths[0].decomposedStringWithCanonicalMapping])
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await session.synchronize()
        guard case let .ready(summary) = session.state else { return XCTFail("\(session.state)") }
        XCTAssertEqual(summary.conflictBlockedWriteCount, 2)
        XCTAssertEqual(summary.notAppliedWrites.total, 0)
        let saved = try readDatabaseRecords(databasePath: fixture.locator.databaseV2Url.path)
        XCTAssertEqual(saved.first { record in SeratoPath.normalized(record.path) == independent.path }?.title, "Independent")
        XCTAssertTrue(saved.filter { record in SeratoPath.normalized(record.path) == protected.path }.allSatisfy { record in record.title == nil && record.artist == nil })
        let repeated = try await fixture.engine.drainPendingSeratoUpdates()
        XCTAssertEqual(repeated.appliedCount, 0)
        XCTAssertEqual(repeated.conflictBlockedCount, 2)
        XCTAssertEqual(repeated.supersededCount, 0)
        try fixture.save(paths: savedPaths)
        _ = try updateDatabaseRecord(databasePath: fixture.locator.databaseV2Url.path, trackPath: savedPaths[0], update: SeratoMetadataUpdate(artist: nil, title: "Chosen in Serato", album: nil, genre: nil, bpm: nil, key: nil, comment: nil, length: nil, label: nil))
        try await session.synchronize()
        let repaired = try readDatabaseRecords(databasePath: fixture.locator.databaseV2Url.path).first { record in SeratoPath.normalized(record.path) == protected.path }
        XCTAssertEqual(repaired?.title, "Chosen in Serato")
        XCTAssertEqual(repaired?.artist, "Queued artist")
        let pending = try await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(pending, 0)
    }

    func testQueuedDuplicateCleanupRetainsTargetWhenItsKeeperBecomesConflicted() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let keeper = try await fixture.add("Café.mp3")
        let target = try await fixture.add("copy.mp3")
        let independent = try await fixture.add("independent.mp3")
        let paths = [keeper.path, target.path, independent.path].map(SeratoLibraryLocator.seratoRelativePath)
        try fixture.save(paths: paths)
        let session = makeSession(fixture, gate: gate)
        try await session.synchronize()
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        _ = try await fixture.engine.resolveDuplicate(target: target, keeper: keeper, batchID: "keeper-conflict")
        try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(independent.id), metadata: .init(title: "Independent"), previousMetadata: .empty)))
        try fixture.save(paths: paths + [paths[0].decomposedStringWithCanonicalMapping])
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await session.synchronize()
        let first = try await fixture.engine.drainPendingSeratoUpdates()
        let second = try await fixture.engine.drainPendingSeratoUpdates()
        XCTAssertEqual(first.conflictBlockedCount, 1)
        XCTAssertEqual(second.conflictBlockedCount, 1)
        XCTAssertEqual(second.supersededCount, 0)
        let failure = try await fixture.engine.failedDuplicateCleanupMessage
        XCTAssertNil(failure)
        let records = try readDatabaseRecords(databasePath: fixture.locator.databaseV2Url.path)
        XCTAssertTrue(records.contains { record in SeratoPath.normalized(record.path) == target.path })
        XCTAssertEqual(records.first { record in SeratoPath.normalized(record.path) == independent.path }?.title, "Independent")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
    }

    func testConflictFilesystemEventsRetainCheckpointAndDoNotStarveIndependentObservations() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let protected = try await fixture.add("Café.mp3")
        let independent = try await fixture.add("independent.mp3")
        try fixture.save(paths: [protected.path, protected.path.decomposedStringWithCanonicalMapping, independent.path])
        let session = makeSession(fixture, gate: gate)
        try await session.synchronize()
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let handler = FilesystemSyncBatchHandler(coordinator: coordinator, session: session)
        let checkpoints = SessionCheckpoints()
        let processor = FilesystemEventProcessor(handler: { batch in try await handler.handle(batch) }, checkpoint: { eventID in await checkpoints.append(eventID) })
        try FileManager.default.removeItem(atPath: protected.path)
        try FileManager.default.removeItem(atPath: independent.path)
        try await processor.enqueue(.init(observations: [.init(path: protected.path, isFile: true, wasRemoved: true, eventID: 501)], highestEventID: 501))
        try await processor.enqueue(.init(observations: [.init(path: independent.path, isFile: true, wasRemoved: true, eventID: 502)], highestEventID: 502))
        let protectedAfter = try await fixture.row(protected)
        let independentAfter = try await fixture.row(independent)
        let heldCheckpoints = await checkpoints.values
        XCTAssertEqual(protectedAfter, protected)
        XCTAssertEqual(independentAfter.fileAvailability, .missing)
        XCTAssertEqual(heldCheckpoints, [])
        try fixture.save(paths: [protected.path, independent.path])
        try await session.synchronize()
        try await processor.retry()
        let finishedCheckpoints = await checkpoints.values
        XCTAssertEqual(finishedCheckpoints.last, 502)
    }

    func testMixedConflictBatchStillValidatesRequiredReconciliation() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let protected = try await fixture.add("Café.mp3")
        let independent = try await fixture.add("retired.mp3")
        try fixture.save(paths: [protected.path, protected.path.decomposedStringWithCanonicalMapping, independent.path])
        let session = makeSession(fixture, gate: gate)
        try await session.synchronize()
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let handler = FilesystemSyncBatchHandler(coordinator: coordinator, session: session)
        let checkpoints = SessionCheckpoints()
        let processor = FilesystemEventProcessor(handler: { batch in try await handler.handle(batch) }, checkpoint: { eventID in await checkpoints.append(eventID) })
        let batch = FilesystemEventBatch(observations: [
            .init(path: protected.path, isFile: true, wasRemoved: true, eventID: 601),
            .init(path: fixture.directory.path, isDirectory: true, rootChanged: true, eventID: 602),
        ], highestEventID: 602)
        try Data("invalid source".utf8).write(to: fixture.locator.databaseV2Url)
        do { try await processor.enqueue(batch); XCTFail("Conflict deferral hid source validation failure") } catch {}
        XCTAssertThrowsError(try gate.capture())
        try fixture.save(paths: [protected.path, protected.path.decomposedStringWithCanonicalMapping])
        try await processor.retry()
        let retired = try await fixture.row(independent)
        XCTAssertEqual(retired.libraryMembership, .retired)
        let held = await checkpoints.values
        XCTAssertEqual(held, [])
        try fixture.save(paths: [protected.path])
        try await session.synchronize()
        try await processor.retry()
        let finished = await checkpoints.values
        XCTAssertEqual(finished.last, 602)
    }

    func testSessionStartsIdleUntilExplicitlyRequested() throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }

        let session = makeSession(fixture, gate: gate)

        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.initialSyncComplete)
        XCTAssertNil(session.scanProgress)
    }

    func testStopSyncCancelsTheRealSnapshotBeforeItCanRetireAFile() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("still-active.mp3")
        try fixture.save(paths: [])
        let barrier = SessionBarrier()
        let reader = SeratoMembershipSnapshotReader(
            locator: fixture.locator,
            watchdog: fixture.watchdog,
            afterParsing: { await barrier.pauseFirst() }
        )
        let session = makeSession(fixture, gate: gate, reader: reader)

        session.requestSync()
        await barrier.waitForEntry()
        session.stopSync()
        await barrier.release()
        await session.waitUntilIdle()

        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.initialSyncComplete)
        let current = try await fixture.row(file)
        XCTAssertEqual(current.libraryMembership, .active)
    }

    func testSupersededProcessingStartCannotAcknowledgeFailedFilesystemSync() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        var session: SeratoLibrarySyncSession!
        defer { session = nil }
        session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler,
                                           scanner: LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator),
                                           operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: gate,
                                           startProcessing: {
                                               do { try Data([1, 2]).write(to: fixture.locator.databaseV2Url) }
                                               catch { XCTFail("Could not corrupt fixture: \(error)") }
                                               session.requestSync()
                                           })
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let handler = FilesystemSyncBatchHandler(coordinator: coordinator, session: session)
        let checkpoints = SessionCheckpoints()
        let processor = FilesystemEventProcessor(handler: { try await handler.handle($0) }, checkpoint: { await checkpoints.append($0) })
        do {
            try await processor.enqueue(.init(observations: [.init(path: fixture.directory.path, isDirectory: true, requiresReconciliation: true)], highestEventID: 91))
            XCTFail("Failed coalesced source was acknowledged")
        } catch {}
        await session.waitUntilIdle()
        guard case .failed = session.state else { return XCTFail("Expected final source failure") }
        XCTAssertFalse(session.initialSyncComplete)
        let retained = await coordinator.requiresReconciliation
        XCTAssertTrue(retained)
        let saved = await checkpoints.values
        XCTAssertEqual(saved, [])
        do { try await processor.enqueue(.init(observations: [], highestEventID: 92)); XCTFail("Failed head was discarded") } catch {}
    }

    func testWorkerInvalidationDuringFingerprintUpdateRollsBackTransaction() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("during-write.mp3")
        try gate.markReady(gate.prepareDrain())
        try await fixture.database.writer.write { database in
            database.trace { event in
                if event.description.contains("UPDATE files"), event.description.contains("chromaprint_fingerprint") {
                    gate.invalidate()
                }
            }
        }
        let worker = FingerprintWorker(database: fixture.database, fingerprintFunction: { _ in [1, 2, 3] }, readiness: gate)
        do { _ = try await worker.processAllPendingOnce(); XCTFail("Invalidated update committed") } catch is LibrarySyncReadinessError {}
        let current = try await fixture.row(file)
        XCTAssertEqual(current.fingerprintStatus, .pending)
        XCTAssertNil(current.chromaprintFingerprint)
    }

    func testExitRetiresBeforeQueuedAddAndRenameDrain() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let removed = try await fixture.add("removed.mp3")
        let renamed = try await fixture.add("before.mp3")
        let imported = try await fixture.add("import.mp3", membership: .pendingImport)
        try fixture.save(paths: [removed.path, renamed.path].map(SeratoLibraryLocator.seratoRelativePath))
        let session = makeSession(fixture, gate: gate)
        session.requestSync()
        await session.waitUntilIdle()
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(removed.id), metadata: SeratoMetadata(title: "stale"))))
        try await fixture.engine.apply(.addTrackToSerato(.init(fileId: XCTUnwrap(imported.id), metadata: SeratoMetadata())))
        session.requestSync()
        await session.waitUntilIdle()
        XCTAssertThrowsError(try gate.capture())
        let destination = fixture.directory.appendingPathComponent("after.mp3").path
        try FileManager.default.moveItem(atPath: renamed.path, toPath: destination)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        try await coordinator.handleObservations([FSEventsObservation(path: destination, isFile: true, wasRenamed: true)])
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: renamed.path)])
        let crateBytes = try SeratoTestEncoding.record("vrsn", XCTUnwrap("1.0/Serato ScratchLive Crate".data(using: .utf16BigEndian)))
            + SeratoTestEncoding.record("otrk", SeratoTestEncoding.record("ptrk", XCTUnwrap(SeratoLibraryLocator.seratoRelativePath(fromAbsolute: renamed.path).data(using: .utf16BigEndian))))
        let crates = [fixture.locator.subcratesDirectoryUrl.appendingPathComponent("test.crate"), fixture.locator.smartCratesDirectoryUrl.appendingPathComponent("test.scrate")]
        for crate in crates {
            try crateBytes.write(to: crate)
        }
        session.requestSync()
        await session.waitUntilIdle()
        XCTAssertEqual(session.state, .waitingForSerato)
        let before = try await fixture.row(removed)
        XCTAssertEqual(before.libraryMembership, .active)
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        session.requestSync()
        await session.waitUntilIdle()
        guard case .ready = session.state else { return XCTFail("\(session.state)") }
        let after = try await fixture.row(removed)
        XCTAssertEqual(after.libraryMembership, .retired)
        let paths = try readDatabaseRecords(databasePath: fixture.locator.databaseV2Url.path).map { SeratoPath.normalized($0.path) }
        XCTAssertFalse(paths.contains(removed.path))
        XCTAssertTrue(paths.contains(destination), "\(paths)")
        XCTAssertTrue(paths.contains(imported.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: removed.path))
        for crate in crates {
            let cratePaths = try readCratePaths(cratePath: crate.path).map(SeratoPath.normalized)
            XCTAssertEqual(cratePaths, [destination])
            XCTAssertFalse(cratePaths.contains(removed.path))
        }
        let events = try await fixture.database.writer.read { try EventRecord.fetchAll($0) }
        let retirement = try XCTUnwrap(events.last { $0.fileId == removed.id && $0.eventType == .fileLibraryStateChanged })
        let confirmation = try XCTUnwrap(events.first { $0.batchId.hasPrefix("import-confirmed:") })
        XCTAssertLessThan(try XCTUnwrap(retirement.eventId), try XCTUnwrap(confirmation.eventId))
    }

    func testCancelledReconciliationAndBurstRequestsSerializeRealSnapshots() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("member.mp3")
        try fixture.save(paths: [])
        let barrier = SessionBarrier()
        let reader = SeratoMembershipSnapshotReader(locator: fixture.locator, watchdog: fixture.watchdog, afterParsing: { await barrier.pauseFirst() })
        let session = makeSession(fixture, gate: gate, reader: reader)
        session.requestSync()
        await barrier.waitForEntry()
        for _ in 0 ..< 50 {
            session.requestSync()
        }
        session.suspend()
        try fixture.save(paths: [file.path])
        await barrier.release()
        await session.waitUntilIdle()
        XCTAssertFalse(session.initialSyncComplete)
        let before = try await fixture.row(file)
        XCTAssertEqual(before.libraryMembership, .active)
        session.requestSync()
        await session.waitUntilIdle()
        XCTAssertTrue(session.initialSyncComplete)
        let after = try await fixture.row(file)
        XCTAssertEqual(after.libraryMembership, .active)
        let entries = await barrier.entries
        XCTAssertEqual(entries, 2)
    }

    func testWorkerCompletionCannotRegainAuthorizationAfterGateReopens() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("fingerprint.mp3")
        let started = expectation(description: "Decoder entered")
        let release = DispatchSemaphore(value: 0)
        let worker = FingerprintWorker(database: fixture.database, concurrency: 1,
                                       fingerprintFunction: { _ in started.fulfill(); release.wait(); return [1, 2, 3] }, readiness: gate)
        try gate.markReady(gate.prepareDrain())
        let task = Task { try await worker.processAllPendingOnce() }
        await fulfillment(of: [started], timeout: 5)
        gate.invalidate()
        try gate.markReady(gate.prepareDrain())
        release.signal()
        do { _ = try await task.value; XCTFail("Old processing generation committed") }
        catch is LibrarySyncReadinessError {}
        let current = try await fixture.row(file)
        XCTAssertEqual(current.fingerprintStatus, .pending)
        XCTAssertNil(current.chromaprintFingerprint)
    }

    func testMissingSourceBlocksDrainAndReadinessUntilRetry() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("pending.mp3", membership: .pendingImport)
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        try await fixture.engine.apply(.addTrackToSerato(.init(fileId: XCTUnwrap(file.id), metadata: SeratoMetadata())))
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try FileManager.default.removeItem(at: fixture.locator.databaseV2Url)
        let session = makeSession(fixture, gate: gate)
        session.requestSync()
        await session.waitUntilIdle()
        guard case .failed = session.state else { return XCTFail("Expected monitored failure") }
        XCTAssertThrowsError(try gate.capture())
        XCTAssertFalse(session.initialSyncComplete)
        let pendingBefore = try await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(pendingBefore, 1)
        let before = try await fixture.row(file)
        XCTAssertEqual(before.libraryMembership, .pendingImport)
        try fixture.save(paths: [])
        session.requestSync()
        await session.waitUntilIdle()
        XCTAssertNoThrow(try gate.capture())
        XCTAssertTrue(session.initialSyncComplete)
        let pendingAfter = try await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(pendingAfter, 0)
    }

    private func makeSession(_ fixture: SeratoRemovalFixture, gate: LibrarySyncReadiness,
                             reader: SeratoMembershipSnapshotReader? = nil) -> SeratoLibrarySyncSession
    {
        let reader = reader ?? fixture.reader
        return SeratoLibrarySyncSession(reader: reader,
                                        reconciler: SeratoMembershipReconciler(database: fixture.database, operationEngine: fixture.engine, reader: reader),
                                        scanner: LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator),
                                        operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: gate)
    }

    /// Rows indexed before subsecond times were kept get them from their verified stat
    /// evidence on the next incremental sync, without re-reading the audio (#118).
    func testIncrementalSyncRecordsSubsecondTimeOfLegacyRowsFromStatEvidence() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("legacy.wav", bytes: FinalRemovalIntegrationTests.wav())
        try fixture.save(paths: [file.path])
        let session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler,
                                               scanner: LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator),
                                               operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: gate,
                                               checkpointStore: SyncCheckpointStore(database: fixture.database))
        try await session.synchronize()
        try await fixture.database.writer.write { database in try database.execute(sql: "UPDATE files SET mtime_nanoseconds = NULL") }

        let counters = LibrarySyncMetrics()
        try await LibrarySyncMetrics.$current.withValue(counters) { try await session.synchronize() }

        let row = try await fixture.row(file)
        XCTAssertNotNil(row.mtimeNanoseconds)
        XCTAssertEqual(row.mtimeNanoseconds, FileMetadataCollector.collect(at: file.path)?.mtimeNanoseconds)
        XCTAssertEqual(row.membershipRevision, file.membershipRevision)
        XCTAssertEqual(counters.snapshot().lightweightHashReads, 0)
    }

    /// A file edited after the plan verified its evidence keeps only its own row for the
    /// next sync; the rest of the library's subsecond times are still recorded.
    func testFileChangedAfterPlanningLeavesOnlyItsOwnSubsecondTimeForLater() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let steady = try await fixture.add("steady.wav", bytes: FinalRemovalIntegrationTests.wav())
        let edited = try await fixture.add("edited.wav", bytes: FinalRemovalIntegrationTests.wav(sample: 1))
        try fixture.save(paths: [steady.path, edited.path])
        try await fixture.database.writer.write { database in try database.execute(sql: "UPDATE files SET mtime_nanoseconds = NULL") }
        let files = try await [fixture.row(steady), fixture.row(edited)]
        var evidence: [Int64: SyncFileEvidence] = [:]
        for file in files {
            let identifier = try XCTUnwrap(file.id)
            evidence[identifier] = try SyncFileEvidence(fileID: identifier, membershipRevision: file.membershipRevision,
                                                        identity: file.identity, readIdentity: AudioFileReadIdentity.read(at: file.path), bitrateProbed: true)
        }
        let snapshot = try await fixture.reader.read()
        let analysis = try await SeratoConflictAnalyzer().analyze(snapshot: snapshot, files: files)
        let plan = try await LibraryRefreshPlanner(evidence: evidence, validatedFileIDs: Set(files.compactMap(\.id)))
            .makePlan(request: .incremental, snapshot: snapshot, indexedFiles: files, previousRecords: snapshot.records,
                      dirtyFileIDs: [], dirtyPaths: [], analysis: analysis)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.25)], ofItemAtPath: edited.path)

        _ = try await fixture.reconciler.reconcile(snapshot, analysis: analysis, plan: plan)

        let recorded = try await fixture.row(steady)
        let skipped = try await fixture.row(edited)
        XCTAssertEqual(recorded.mtimeNanoseconds, FileMetadataCollector.collect(at: steady.path)?.mtimeNanoseconds)
        XCTAssertNil(skipped.mtimeNanoseconds)
    }

    func testRequiredFilesystemReconciliationRetainsFailedHeadAndCheckpoint() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("removed.mp3")
        let imported = try await fixture.add("pending.mp3", membership: .pendingImport)
        try await fixture.engine.apply(.addTrackToSerato(.init(fileId: XCTUnwrap(imported.id), metadata: SeratoMetadata())))
        let session = makeSession(fixture, gate: gate)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let handler = FilesystemSyncBatchHandler(coordinator: coordinator, session: session)
        let checkpoints = SessionCheckpoints()
        let processor = FilesystemEventProcessor(handler: { try await handler.handle($0) }, checkpoint: { await checkpoints.append($0) })
        try Data([1, 2]).write(to: fixture.locator.databaseV2Url)
        let batch = FilesystemEventBatch(observations: [.init(path: fixture.directory.path, isDirectory: true, requiresReconciliation: true)], highestEventID: 41)
        do { try await processor.enqueue(batch); XCTFail("Corrupt source checkpointed") } catch {}
        session.reportFilesystemFailure("Retained filesystem batch 41 failed")
        await session.waitUntilIdle()
        let requested = await coordinator.requiresReconciliation
        XCTAssertTrue(requested)
        let failedCheckpoints = await checkpoints.values
        XCTAssertEqual(failedCheckpoints, [])
        let before = try await fixture.row(file)
        XCTAssertEqual(before.libraryMembership, .active)
        do { try await processor.enqueue(.init(observations: [], highestEventID: 42)); XCTFail("Failed head skipped") } catch {}
        session.beginFilesystemRetry()
        do { try await processor.retry(); XCTFail("Corrupt-source retry succeeded") } catch {}
        session.finishFilesystemRetry(succeeded: false)
        try fixture.save(paths: [])
        session.requestSync()
        await session.waitUntilIdle()
        XCTAssertEqual(session.state, .failed("Retained filesystem batch 41 failed"))
        XCTAssertThrowsError(try gate.capture())
        session.beginFilesystemRetry()
        try await processor.retry()
        XCTAssertThrowsError(try gate.capture())
        let queuedBeforeCheckpointCompletion = try await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(queuedBeforeCheckpointCompletion, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), SeratoTestEncoding.library(paths: []))
        session.finishFilesystemRetry(succeeded: true)
        try await session.synchronize()
        XCTAssertNoThrow(try gate.capture())
        let queuedAfterRetry = try await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(queuedAfterRetry, 0)
        let after = try await fixture.row(file)
        XCTAssertEqual(after.libraryMembership, .retired)
        let retriedCheckpoints = await checkpoints.values
        XCTAssertEqual(retriedCheckpoints, [41, 42])
    }

    func testBurstRequestsCoalesceWithoutOverlappingSnapshots() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("retire.mp3")
        let barrier = SessionBarrier()
        let reader = SeratoMembershipSnapshotReader(locator: fixture.locator, watchdog: fixture.watchdog, afterParsing: { await barrier.pauseFirst() })
        let session = makeSession(fixture, gate: gate, reader: reader)
        session.requestSync()
        await barrier.waitForEntry()
        for _ in 0 ..< 8 {
            session.requestSync()
        }
        await barrier.release()
        await session.waitUntilIdle()
        let entries = await barrier.entries
        XCTAssertEqual(entries, 2)
        guard case .ready = session.state else { return XCTFail("\(session.state)") }
        let after = try await fixture.row(file)
        XCTAssertEqual(after.libraryMembership, .retired)
    }

    func testSeratoCloseAfterInterruptedManualSyncReturnsIdleWithoutRestarting() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let removed = try await fixture.add("removed.mp3")
        let imported = try await fixture.add("pending.mp3", membership: .pendingImport)
        try await fixture.engine.apply(.addTrackToSerato(.init(fileId: XCTUnwrap(imported.id), metadata: SeratoMetadata())))
        let barrier = SessionBarrier()
        let reader = SeratoMembershipSnapshotReader(locator: fixture.locator, watchdog: fixture.watchdog, afterParsing: { await barrier.pauseFirst() })
        let session = makeSession(fixture, gate: gate, reader: reader)
        let coordinator = SeratoSyncCoordinator(session: session, seratoWatchdog: fixture.watchdog)
        session.requestSync()
        await barrier.waitForEntry()
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        await barrier.release()
        await session.waitUntilIdle()
        XCTAssertEqual(session.state, .waitingForSerato)
        XCTAssertFalse(session.initialSyncComplete)
        XCTAssertThrowsError(try gate.capture())
        let before = try await fixture.row(removed)
        XCTAssertEqual(before.libraryMembership, .active)
        let queued = try await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(queued, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), SeratoTestEncoding.library(paths: []))
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        await session.waitUntilIdle()
        let after = try await fixture.row(removed)
        XCTAssertEqual(after.libraryMembership, .active)
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.initialSyncComplete)
        withExtendedLifetime(coordinator) {}
    }

    func testSeratoCloseAfterSuccessfulSyncInvalidatesReadinessWithoutRestarting() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let session = makeSession(fixture, gate: gate)
        let coordinator = SeratoSyncCoordinator(session: session, seratoWatchdog: fixture.watchdog)
        session.requestSync()
        await session.waitUntilIdle()
        XCTAssertNoThrow(try gate.capture())

        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        await session.waitUntilIdle()

        XCTAssertEqual(session.state, .idle)
        XCTAssertThrowsError(try gate.capture())
        withExtendedLifetime(coordinator) {}
    }

    func testStartupOpenBlocksOrdinaryMutationAndWorkerButRetainsExplicitImport() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("member.mp3")
        let imported = try await fixture.add("pending.mp3", membership: .pendingImport)
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        let session = makeSession(fixture, gate: gate)
        session.requestSync()
        await session.waitUntilIdle()
        XCTAssertEqual(session.state, .waitingForSerato)
        do {
            try await fixture.engine.apply(.renameFile(.init(fileId: XCTUnwrap(file.id), newPath: fixture.directory.appendingPathComponent("wrong.mp3").path, previousPath: file.path, physicalMove: true)))
            XCTFail("Unvalidated row was processed")
        } catch is LibrarySyncReadinessError {}
        let worker = FingerprintWorker(database: fixture.database, fingerprintFunction: { _ in XCTFail("Unvalidated row was decoded"); return [] }, readiness: gate)
        do { _ = try await worker.processAllPendingOnce(); XCTFail("Unvalidated worker ran") } catch is LibrarySyncReadinessError {}
        try await fixture.engine.apply(.addTrackToSerato(.init(fileId: XCTUnwrap(imported.id), metadata: SeratoMetadata())))
        let queued = try await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(queued, 1)
        let current = try await fixture.row(file)
        XCTAssertEqual(current.path, file.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}

actor SessionCheckpoints {
    private(set) var values: [UInt64] = []
    func append(_ value: UInt64) {
        values.append(value)
    }
}

actor SessionBarrier {
    private var entered: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    private(set) var entries = 0
    func pauseFirst() async {
        entries += 1
        guard entries == 1 else { return }
        await withCheckedContinuation { continuation in
            blocked = continuation
            entered?.resume()
            entered = nil
        }
    }

    func waitForEntry() async {
        guard entries == 0 else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func release() {
        blocked?.resume(); blocked = nil
    }
}
