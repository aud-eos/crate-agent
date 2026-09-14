import Combine
@testable import CrateAgent
import Foundation
import GRDB
import XCTest

@MainActor
final class SeratoLibrarySyncSessionTests: XCTestCase {
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
        let pendingBefore = await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(pendingBefore, 1)
        let before = try await fixture.row(file)
        XCTAssertEqual(before.libraryMembership, .pendingImport)
        try fixture.save(paths: [])
        session.requestSync()
        await session.waitUntilIdle()
        XCTAssertNoThrow(try gate.capture())
        XCTAssertTrue(session.initialSyncComplete)
        let pendingAfter = await fixture.engine.pendingSeratoWriteCount
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
        session.seratoStateChanged(isRunning: false)
        await session.waitUntilIdle()
        XCTAssertEqual(session.state, .failed("Retained filesystem batch 41 failed"))
        XCTAssertThrowsError(try gate.capture())
        session.beginFilesystemRetry()
        try await processor.retry()
        XCTAssertThrowsError(try gate.capture())
        let queuedBeforeCheckpointCompletion = await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(queuedBeforeCheckpointCompletion, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), SeratoTestEncoding.library(paths: []))
        session.finishFilesystemRetry(succeeded: true)
        try await session.synchronize()
        XCTAssertNoThrow(try gate.capture())
        let queuedAfterRetry = await fixture.engine.pendingSeratoWriteCount
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

    func testSeratoLaunchDuringInitialReadCancelsRetirementAndDefersQueuedIntent() async throws {
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
        let queued = await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(queued, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), SeratoTestEncoding.library(paths: []))
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        await session.waitUntilIdle()
        let after = try await fixture.row(removed)
        XCTAssertEqual(after.libraryMembership, .retired)
        XCTAssertTrue(session.initialSyncComplete)
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
        let queued = await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(queued, 1)
        let current = try await fixture.row(file)
        XCTAssertEqual(current.path, file.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testWorkerDatabaseFailureIsVisibleAndRetryStartsNewGeneration() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let worker = FingerprintWorker(database: fixture.database, fingerprintFunction: { _ in [] }, readiness: gate)
        var injectFailure = true
        let session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler,
                                               scanner: LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator),
                                               operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: gate,
                                               startProcessing: {
                                                   guard injectFailure else { return }
                                                   injectFailure = false
                                                   do { try await fixture.database.writer.write { try $0.execute(sql: "ALTER TABLE files RENAME TO held_files") } }
                                                   catch { XCTFail("Could not inject database failure: \(error)") }
                                               }, worker: worker)
        let failure = expectation(description: "Visible worker database error")
        let subscription = session.$state.sink { state in
            if case let .failed(message) = state, message.contains("Fingerprint processing stopped") {
                failure.fulfill()
            }
        }
        session.requestSync()
        await fulfillment(of: [failure], timeout: 5)
        await session.waitUntilIdle()
        XCTAssertThrowsError(try gate.capture())
        XCTAssertNotNil(session.fingerprintProgress?.error)
        let priorError = await worker.lastError
        XCTAssertNotNil(priorError)
        try await fixture.database.writer.write { try $0.execute(sql: "ALTER TABLE held_files RENAME TO files") }
        session.requestSync()
        await session.waitUntilIdle()
        guard case .ready = session.state else { return XCTFail("\(session.state)") }
        let currentError = await worker.lastError
        XCTAssertNil(currentError)
        XCTAssertNil(session.fingerprintProgress?.error)
        await worker.stop()
        withExtendedLifetime(subscription) {}
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
