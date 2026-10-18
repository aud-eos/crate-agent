import Combine
@testable import CrateAgent
import Foundation
import GRDB
import XCTest

@MainActor
final class PR123FilesystemSyncRegressionTests: XCTestCase {
    private let mountedRoot = URL(fileURLWithPath: "/private/tmp/crate-agent-task6-volume")

    func testDestinationFirstCrossVolumeMoveAcrossBatches() async throws {
        try await destinationFirstMove(sameBatch: false)
    }

    func testDestinationFirstCrossVolumeMoveWithinBatch() async throws {
        try await destinationFirstMove(sameBatch: true)
    }

    private func destinationFirstMove(sameBatch: Bool) async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let directory = try ownedVolumeDirectory()
        defer { cleanupVolumeDirectory(directory) }
        let file = try await fixture.add("before.mp3")
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let destination = directory.appendingPathComponent("after.mp3")
        try FileManager.default.copyItem(atPath: file.path, toPath: destination.path)
        let copied = try XCTUnwrap(FileMetadataCollector.collect(at: destination.path, includeLightweightHash: true))
        XCTAssertNotEqual(copied.volumeUuid, file.volumeUuid)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let created = FSEventsObservation(path: destination.path, isFile: true, wasCreated: true, eventID: 100)
        let removed = FSEventsObservation(path: file.path, isFile: true, wasRemoved: true, eventID: 101)
        if sameBatch {
            let intervention = SourceRemovalIntervention(source: file.path)
            try await fixture.database.writer.write { connection in
                connection.trace { event in
                    if event.expandedDescription.contains("batch_id"), event.expandedDescription.contains("filesystem-event-101") {
                        intervention.removeOnce()
                    }
                }
            }
            try await coordinator.handleBatch(.init(observations: [created, removed], highestEventID: 101))
            XCTAssertTrue(intervention.removed)
        } else {
            try await coordinator.handleBatch(.init(observations: [created], highestEventID: 100))
            let stillOriginal = try await fixture.row(file)
            XCTAssertEqual(stillOriginal.path, file.path, "A copy with a live source is not a move")
            XCTAssertEqual(try savedPaths(fixture), [file.path])
            try FileManager.default.removeItem(atPath: file.path)
            try await coordinator.handleBatch(.init(observations: [removed], highestEventID: 101))
        }
        let moved = try await fixture.row(file)
        XCTAssertEqual(moved.path, destination.path)
        XCTAssertEqual(moved.volumeUuid, copied.volumeUuid)
        XCTAssertEqual(moved.inode, copied.inode)
        XCTAssertEqual(moved.libraryMembership, .active)
        XCTAssertEqual(moved.fileAvailability, .available)
        XCTAssertEqual(moved.membershipRevision, file.membershipRevision)
        XCTAssertEqual(try savedPaths(fixture), [destination.path])
    }

    func testAudioSymlinkParticipatesInStrictReconciliationAndScan() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let target = try await fixture.add("target.wav", bytes: FinalRemovalIntegrationTests.wav())
        let linked = fixture.directory.appendingPathComponent("linked.wav")
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: target.path)
        let file = try await replaceFixturePath(target, path: linked.path, fixture: fixture)
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: linked.path)])
        XCTAssertEqual(try readAudioTags(filePath: linked.path).durationSeconds, 1)
        XCTAssertEqual(try FileMetadataCollector.collectVerified(at: linked.path), file.identity)
        let snapshot = try await fixture.reader.read()
        _ = try await fixture.reconciler.reconcile(snapshot)
        let result = try await scanner(fixture).scan(snapshot: snapshot, reader: fixture.reader)
        XCTAssertEqual(result.filesSkipped, 0)
        let current = try await fixture.row(file)
        XCTAssertEqual(current.path, linked.path)
        XCTAssertEqual(current.libraryMembership, .active)
        XCTAssertEqual(current.membershipRevision, file.membershipRevision)
        XCTAssertThrowsError(try SeratoSourceIdentity.read(linked), "V2 sources must still reject symlinks")
    }

    func testBrokenAndNonregularAudioLinksFailVerification() throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let broken = fixture.directory.appendingPathComponent("broken.mp3")
        try FileManager.default.createSymbolicLink(atPath: broken.path, withDestinationPath: fixture.directory.appendingPathComponent("absent.mp3").path)
        XCTAssertThrowsError(try FileMetadataCollector.collectVerified(at: broken.path))
        let directoryLink = fixture.directory.appendingPathComponent("directory.mp3")
        try FileManager.default.createSymbolicLink(atPath: directoryLink.path, withDestinationPath: fixture.directory.path)
        XCTAssertThrowsError(try FileMetadataCollector.collectVerified(at: directoryLink.path))
    }

    func testAudioVerificationRejectsRepointedLinkAndChangedTarget() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.add("first.wav", bytes: FinalRemovalIntegrationTests.wav())
        let second = try await fixture.add("second.wav", bytes: FinalRemovalIntegrationTests.wav())
        let linked = fixture.directory.appendingPathComponent("linked.wav")
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: first.path)
        XCTAssertEqual(try readAudioTags(filePath: linked.path).durationSeconds, 1)
        let original = try AudioFileReadIdentity.read(at: linked.path)
        _ = try FileMetadataCollector.collectVerified(at: linked.path)
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: second.path)
        XCTAssertThrowsError(try original.requireUnchanged(at: linked.path))
        let repointed = try AudioFileReadIdentity.read(at: linked.path)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: second.path))
        try handle.seek(toOffset: 44)
        try handle.write(contentsOf: Data([4, 3, 2, 1]))
        try handle.close()
        XCTAssertThrowsError(try repointed.requireUnchanged(at: linked.path))
        XCTAssertEqual(try readAudioTags(filePath: linked.path).durationSeconds, 1)
    }

    func testRetainedMoveRejectsChangedDestination() async throws {
        try await invalidatedCandidate(.destinationChanged)
    }

    func testRetainedMoveRejectsMissingDestination() async throws {
        try await invalidatedCandidate(.destinationMissing)
    }

    func testRetainedMoveRejectsReplacedSource() async throws {
        try await invalidatedCandidate(.sourceReplaced)
    }

    func testRetainedMoveRejectsRetirementAndReactivation() async throws {
        try await invalidatedCandidate(.retiredAndReactivated)
    }

    private enum CandidateInvalidation { case destinationChanged, destinationMissing, sourceReplaced, retiredAndReactivated }

    private func invalidatedCandidate(_ invalidation: CandidateInvalidation) async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("before.mp3")
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let destination = fixture.directory.appendingPathComponent("after.mp3")
        try FileManager.default.copyItem(atPath: file.path, toPath: destination.path)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        try await coordinator.handleObservations([.init(path: destination.path, isFile: true, wasCreated: true)])
        switch invalidation {
        case .destinationChanged:
            try FileManager.default.moveItem(at: destination, to: destination.appendingPathExtension("held"))
            try Data([4, 3, 2, 1]).write(to: destination)
        case .destinationMissing:
            try FileManager.default.removeItem(at: destination)
        case .sourceReplaced:
            try FileManager.default.moveItem(atPath: file.path, toPath: file.path + ".held")
            try Data([4, 3, 2, 1]).write(to: URL(fileURLWithPath: file.path))
            try await coordinator.handleObservations([.init(path: file.path, isFile: true, wasCreated: true)])
        case .retiredAndReactivated:
            _ = try await fixture.engine.apply(.setFileLibraryState(.init(fileId: XCTUnwrap(file.id), expectedRevision: file.membershipRevision,
                                                                          state: .init(membership: .retired, availability: .available, libraryID: file.seratoLibraryId, retiredAt: 1))))
            _ = try await fixture.reconcile()
        }
        try FileManager.default.removeItem(atPath: file.path)
        try await coordinator.handleObservations([.init(path: file.path, isFile: true, wasRemoved: true)])
        let after = try await fixture.row(file)
        XCTAssertEqual(after.path, file.path)
        XCTAssertEqual(try savedPaths(fixture), [file.path])
        let requiresReconciliation = await coordinator.requiresReconciliation
        XCTAssertTrue(requiresReconciliation)
    }

    func testTwoDestinationsStayFailedUntilRetryResolvesAmbiguity() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("before.mp3")
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let first = fixture.directory.appendingPathComponent("first.mp3")
        let second = fixture.directory.appendingPathComponent("second.mp3")
        try FileManager.default.copyItem(atPath: file.path, toPath: first.path)
        try FileManager.default.copyItem(atPath: file.path, toPath: second.path)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let probe = StartupReplayProbe()
        let processor = FilesystemEventProcessor(handler: { try await coordinator.handleBatch($0) }, checkpoint: { await probe.checkpoint($0) })
        try await processor.enqueue(.init(observations: [.init(path: first.path, isFile: true, wasCreated: true, eventID: 1)], highestEventID: 1))
        do {
            try await processor.enqueue(.init(observations: [.init(path: second.path, isFile: true, wasCreated: true, eventID: 2)], highestEventID: 2))
            XCTFail("Two live destinations must surface ambiguity")
        } catch is FilesystemObservationError {}
        var observed = await probe.snapshot()
        XCTAssertEqual(observed.checkpoints, [1])
        do { try await processor.retry(); XCTFail("Unchanged ambiguity must remain failed") } catch is FilesystemObservationError {}
        try FileManager.default.removeItem(at: first)
        try await processor.retry()
        try FileManager.default.removeItem(atPath: file.path)
        try await processor.enqueue(.init(observations: [.init(path: file.path, isFile: true, wasRemoved: true, eventID: 3)], highestEventID: 3))
        let after = try await fixture.row(file)
        XCTAssertEqual(after.path, second.path)
        XCTAssertEqual(try savedPaths(fixture), [second.path])
        observed = await probe.snapshot()
        XCTAssertEqual(observed.checkpoints, [1, 2, 3])
    }

    func testRetainedMoveRechecksDestinationBeforeCommit() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("before.mp3")
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let destination = fixture.directory.appendingPathComponent("after.mp3")
        try FileManager.default.copyItem(atPath: file.path, toPath: destination.path)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        try await coordinator.handleObservations([.init(path: destination.path, isFile: true, wasCreated: true)])
        try FileManager.default.removeItem(atPath: file.path)
        let intervention = SourceRemovalIntervention(source: destination.path)
        try await fixture.database.writer.write { connection in
            connection.trace { event in
                if event.expandedDescription.contains("INSERT INTO \"events\""), event.expandedDescription.contains("file_renamed") {
                    intervention.removeOnce()
                }
            }
        }
        do {
            try await coordinator.handleObservations([.init(path: file.path, isFile: true, wasRemoved: true)])
            XCTFail("Destination loss after preflight must roll back the observation")
        } catch is FilesystemObservationError {}
        XCTAssertTrue(intervention.removed)
        let after = try await fixture.row(file)
        XCTAssertEqual(after.path, file.path)
        XCTAssertEqual(try savedPaths(fixture), [file.path])
        let count = try await fixture.events()
        XCTAssertEqual(count, 0)
    }

    func testStartupReplayWaitsForLegacyMembershipAndSuccessfulRetry() async throws {
        let readiness = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: readiness)
        defer { fixture.cleanup() }
        let file = try await fixture.add("before.mp3", membership: .legacyUnverified)
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let saved = try Data(contentsOf: fixture.locator.databaseV2Url)
        let destination = fixture.directory.appendingPathComponent("after.mp3")
        try FileManager.default.moveItem(atPath: file.path, toPath: destination.path)
        let session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler, scanner: scanner(fixture), operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: readiness)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let handler = FilesystemSyncBatchHandler(coordinator: coordinator, session: session)
        let probe = StartupReplayProbe()
        let checkpointed = expectation(description: "Buffered rename checkpointed after initial sync")
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { batch in
            await probe.handled(batch.highestEventID)
            try await handler.handle(batch)
        }, checkpoint: {
            await probe.checkpoint($0)
            checkpointed.fulfill()
        })
        let subscription = processor.resumeAfterInitialSync(session)
        defer { subscription.cancel() }
        try await processor.enqueue(.init(observations: [.init(path: destination.path, isFile: true, wasRenamed: true, eventID: 40)], highestEventID: 40))
        let buffered = try await fixture.row(file)
        XCTAssertEqual(buffered.path, file.path)
        XCTAssertEqual(buffered.libraryMembership, .legacyUnverified)
        var observed = await probe.snapshot()
        XCTAssertEqual(observed.handled, [])
        XCTAssertEqual(observed.checkpoints, [])
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        do { try await session.synchronize(); XCTFail("Running Serato must wait") } catch {}
        try await processor.retry()
        observed = await probe.snapshot()
        XCTAssertEqual(observed.handled, [])
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try Data([1, 2]).write(to: fixture.locator.databaseV2Url)
        do { try await session.synchronize(); XCTFail("Malformed source must fail") } catch {}
        XCTAssertFalse(session.initialSyncComplete)
        observed = await probe.snapshot()
        XCTAssertEqual(observed.checkpoints, [])
        try saved.write(to: fixture.locator.databaseV2Url)
        try await session.synchronize()
        XCTAssertTrue(session.initialSyncComplete)
        await fulfillment(of: [checkpointed], timeout: 5)
        let current = try await fixture.row(file)
        XCTAssertEqual(current.path, destination.path)
        XCTAssertEqual(current.libraryMembership, .active)
        XCTAssertEqual(current.fileAvailability, .available)
        XCTAssertEqual(try savedPaths(fixture), [destination.path])
        observed = await probe.snapshot()
        XCTAssertEqual(observed.handled, [40])
        XCTAssertEqual(observed.checkpoints, [40])
    }

    func testAuthorizedScannerSkipsForeignOwnerAtSavedPath() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        var file = try await fixture.add("foreign.mp3")
        file.seratoLibraryId = "foreign-library"
        file.artist = "Foreign artist"
        file.title = "Foreign title"
        file.membershipRevision = 7
        let original = file
        try await fixture.database.writer.write { try original.update($0) }
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let eventsBefore = try await fixture.events()
        let snapshot = try await fixture.reader.read()
        let summary = try await fixture.reconciler.reconcile(snapshot)
        XCTAssertEqual(summary.skippedUnsupported, 1)
        let result = try await scanner(fixture).scan(snapshot: snapshot, reader: fixture.reader)
        XCTAssertEqual(result.filesSkipped, 1)
        XCTAssertEqual(result.filesMetadataUpdated, 0)
        let after = try await fixture.row(file)
        XCTAssertEqual(after, original)
        let eventsAfter = try await fixture.events()
        XCTAssertEqual(eventsAfter, eventsBefore)
    }

    func testScannerAcceptsCurrentOwnerAndInitiallyUnownedLegacyRows() async throws {
        for membership in [LibraryMembership.active, .legacyUnverified] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            var file = try await fixture.add("owned.mp3", membership: membership)
            file.title = "Local title"
            let original = file
            try await fixture.database.writer.write { try original.update($0) }
            try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
            let snapshot = try await fixture.reader.read()
            _ = try await fixture.reconciler.reconcile(snapshot)
            let result = try await scanner(fixture).scan(snapshot: snapshot, reader: fixture.reader)
            XCTAssertEqual(result.filesSkipped, 0)
            XCTAssertEqual(result.filesMetadataUpdated, 1)
            let after = try await fixture.row(file)
            XCTAssertEqual(after.seratoLibraryId, snapshot.libraryID)
            XCTAssertEqual(after.libraryMembership, .active)
            XCTAssertNil(after.title)
        }
    }

    func testStartupReleaseWaitsUntilCoalescedSessionIsIdle() async throws {
        let readiness = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: readiness)
        defer { fixture.cleanup() }
        let file = try await fixture.add("before.mp3", membership: .legacyUnverified)
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let destination = fixture.directory.appendingPathComponent("after.mp3")
        try FileManager.default.moveItem(atPath: file.path, toPath: destination.path)
        let entered = expectation(description: "Coalesced follow-up snapshot paused")
        let boundary = StartupSnapshotBoundary(entered: entered)
        let reader = SeratoMembershipSnapshotReader(locator: fixture.locator, watchdog: fixture.watchdog, afterParsing: { await boundary.afterParsing() })
        let reconciler = SeratoMembershipReconciler(database: fixture.database, operationEngine: fixture.engine, reader: reader)
        let session = SeratoLibrarySyncSession(reader: reader, reconciler: reconciler, scanner: scanner(fixture), operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: readiness)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let handler = FilesystemSyncBatchHandler(coordinator: coordinator, session: session)
        let probe = StartupReplayProbe()
        let checkpointed = expectation(description: "Replay completed after coalesced session")
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { batch in
            await probe.handled(batch.highestEventID)
            try await handler.handle(batch)
        }, checkpoint: {
            await probe.checkpoint($0)
            checkpointed.fulfill()
        })
        let delivery = processor.resumeAfterInitialSync(session)
        var requestedFollowup = false
        let coalescing = session.$initialSyncComplete.sink { completed in
            if completed, !requestedFollowup {
                requestedFollowup = true
                session.requestSync()
            }
        }
        defer { delivery.cancel(); coalescing.cancel() }
        try await processor.enqueue(.init(observations: [.init(path: destination.path, isFile: true, wasRenamed: true)], highestEventID: 50))
        let synchronization = Task { try await session.synchronize() }
        await fulfillment(of: [entered], timeout: 5)
        // Flush actor delivery queued before the second snapshot suspended.
        try await processor.retry()
        let before = await probe.snapshot()
        XCTAssertEqual(before.handled, [])
        XCTAssertEqual(before.checkpoints, [])
        let established = try await fixture.row(file)
        XCTAssertEqual(established.libraryMembership, .active)
        XCTAssertEqual(established.path, file.path)
        await boundary.release()
        try await synchronization.value
        await fulfillment(of: [checkpointed], timeout: 5)
        let after = try await fixture.row(file)
        XCTAssertEqual(after.libraryMembership, .active)
        XCTAssertEqual(after.path, destination.path)
        XCTAssertEqual(try savedPaths(fixture), [destination.path])
        let completed = await probe.snapshot()
        XCTAssertEqual(completed.handled, [50])
        XCTAssertEqual(completed.checkpoints, [50])
    }

    func testPendingMoveSurvivesStrictObservationOfMissingSource() async throws {
        let readiness = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: readiness)
        defer { fixture.cleanup() }
        let file = try await fixture.add("before.mp3")
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let destination = fixture.directory.appendingPathComponent("after.mp3")
        let entered = expectation(description: "Destination batch requested a strict snapshot")
        let boundary = StartupSnapshotBoundary(entered: entered)
        let reader = SeratoMembershipSnapshotReader(locator: fixture.locator, watchdog: fixture.watchdog, afterParsing: { await boundary.afterParsing() })
        let reconciler = SeratoMembershipReconciler(database: fixture.database, operationEngine: fixture.engine, reader: reader)
        let session = SeratoLibrarySyncSession(reader: reader, reconciler: reconciler, scanner: scanner(fixture), operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: readiness)
        try await session.synchronize()
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let handler = FilesystemSyncBatchHandler(coordinator: coordinator, session: session)
        let processor = FilesystemEventProcessor(handler: { try await handler.handle($0) }, checkpoint: { _ in })
        try FileManager.default.copyItem(atPath: file.path, toPath: destination.path)
        let created = Task {
            try await processor.enqueue(.init(observations: [.init(path: destination.path, isFile: true, wasCreated: true)], highestEventID: 60))
        }
        await fulfillment(of: [entered], timeout: 5)
        try FileManager.default.removeItem(atPath: file.path)
        await boundary.release()
        try await created.value
        let observedMissing = try await fixture.row(file)
        XCTAssertEqual(observedMissing.fileAvailability, .missing)
        XCTAssertEqual(observedMissing.membershipRevision, file.membershipRevision)
        try await processor.enqueue(.init(observations: [.init(path: file.path, isFile: true, wasRemoved: true)], highestEventID: 61))
        let moved = try await fixture.row(file)
        XCTAssertEqual(moved.path, destination.path)
        XCTAssertEqual(moved.libraryMembership, .active)
        XCTAssertEqual(moved.fileAvailability, .available)
        XCTAssertEqual(try savedPaths(fixture), [destination.path])
    }

    func testRetainedMoveRejectsObservedInPlaceSourceEdit() async throws {
        try await retainedMoveRejectsObservedSourceEdit(outsideHashWindows: false)
    }

    func testRetainedMoveRejectsObservedMiddleEditWithUnchangedSampledIdentity() async throws {
        try await retainedMoveRejectsObservedSourceEdit(outsideHashWindows: true)
    }

    func testRepeatedDestinationCannotRenewChangedSourceAuthority() async throws {
        try await retainedMoveRejectsObservedSourceEdit(outsideHashWindows: true, repeatDestination: true)
    }

    func testInvalidatedDestinationCannotRegainAuthorityOnLaterObservation() async throws {
        try await retainedMoveRejectsObservedSourceEdit(outsideHashWindows: true, repeatDestination: true, rediscoverAfterInvalidation: true)
    }

    func testInaccessibleRetainedSourceCannotPromoteCopyAfterRemoval() async throws {
        let readiness = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: readiness)
        defer { fixture.cleanup() }
        let file = try await fixture.add("source.wav", bytes: FinalRemovalIntegrationTests.wav())
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let reads = StartupReplayProbe()
        let reader = SeratoMembershipSnapshotReader(locator: fixture.locator, watchdog: fixture.watchdog, afterParsing: { await reads.handled(0) })
        let reconciler = SeratoMembershipReconciler(database: fixture.database, operationEngine: fixture.engine, reader: reader)
        let session = SeratoLibrarySyncSession(reader: reader, reconciler: reconciler, scanner: scanner(fixture), operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: readiness)
        try await session.synchronize()
        let destination = fixture.directory.appendingPathComponent("stale-copy.wav")
        try FileManager.default.copyItem(atPath: file.path, toPath: destination.path)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let handler = FilesystemSyncBatchHandler(coordinator: coordinator, session: session)
        let checkpoints = StartupReplayProbe()
        let processor = FilesystemEventProcessor(handler: { try await handler.handle($0) }, checkpoint: { await checkpoints.checkpoint($0) })
        try await processor.enqueue(.init(observations: [.init(path: destination.path, isFile: true, wasCreated: true, eventID: 93)], highestEventID: 93))
        let priorReads = await reads.snapshot().handled.count
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        XCTAssertEqual(try FileAvailabilityResolver().inspect(path: file.path, volumeID: file.volumeUuid), .inaccessible)
        XCTAssertThrowsError(try FileMetadataCollector.collectVerified(at: file.path))
        try await processor.enqueue(.init(observations: [.init(path: file.path, isFile: true, wasModified: true, eventID: 94)], highestEventID: 94))
        let inaccessible = try await fixture.row(file)
        XCTAssertEqual(inaccessible.fileAvailability, .inaccessible)
        let reconciledReads = await reads.snapshot().handled.count
        XCTAssertGreaterThan(reconciledReads, priorReads)
        try FileManager.default.removeItem(atPath: file.path)
        try await processor.enqueue(.init(observations: [.init(path: file.path, isFile: true, wasRemoved: true, eventID: 95)], highestEventID: 95))
        let after = try await fixture.row(file)
        XCTAssertEqual(after.path, file.path)
        XCTAssertEqual(after.fileAvailability, .missing)
        XCTAssertEqual(try savedPaths(fixture), [file.path])
        let renames = try await fixture.database.writer.read { connection in
            try EventRecord.filter(Column("event_type") == EventType.fileRenamed.rawValue).fetchCount(connection)
        }
        XCTAssertEqual(renames, 0)
        let completed = await checkpoints.snapshot()
        XCTAssertEqual(completed.checkpoints, [93, 94, 95])
    }

    private func retainedMoveRejectsObservedSourceEdit(outsideHashWindows: Bool, repeatDestination: Bool = false,
                                                       rediscoverAfterInvalidation: Bool = false) async throws
    {
        let readiness = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: readiness)
        defer { fixture.cleanup() }
        var bytes = FinalRemovalIntegrationTests.wav()
        if outsideHashWindows {
            bytes.append(Data(repeating: 0, count: 3 * LightweightHashCalculator.windowSize))
            var riffSize = UInt32(bytes.count - 8).littleEndian
            var sampleSize = UInt32(bytes.count - 44).littleEndian
            bytes.replaceSubrange(4 ..< 8, with: withUnsafeBytes(of: &riffSize) { Data($0) })
            bytes.replaceSubrange(40 ..< 44, with: withUnsafeBytes(of: &sampleSize) { Data($0) })
        }
        let file = try await fixture.add("source.wav", bytes: bytes)
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let reads = StartupReplayProbe()
        let reader = SeratoMembershipSnapshotReader(locator: fixture.locator, watchdog: fixture.watchdog, afterParsing: { await reads.handled(0) })
        let reconciler = SeratoMembershipReconciler(database: fixture.database, operationEngine: fixture.engine, reader: reader)
        let session = SeratoLibrarySyncSession(reader: reader, reconciler: reconciler, scanner: scanner(fixture), operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: readiness)
        try await session.synchronize()
        let destination = fixture.directory.appendingPathComponent("stale-copy.wav")
        try FileManager.default.copyItem(atPath: file.path, toPath: destination.path)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let handler = FilesystemSyncBatchHandler(coordinator: coordinator, session: session)
        let checkpoints = StartupReplayProbe()
        let processor = FilesystemEventProcessor(handler: { try await handler.handle($0) }, checkpoint: { await checkpoints.checkpoint($0) })
        try await processor.enqueue(.init(observations: [.init(path: destination.path, isFile: true, wasCreated: true, eventID: 90)], highestEventID: 90))
        let retained = try await fixture.row(file)
        XCTAssertEqual(retained.path, file.path)
        XCTAssertEqual(try savedPaths(fixture), [file.path])
        let pendingReconciliation = await coordinator.takeReconciliationRequest()
        XCTAssertFalse(pendingReconciliation, "The destination batch must finish its initial strict pass")
        let priorReads = await reads.snapshot().handled.count
        let original = try FileMetadataCollector.collectVerified(at: file.path)
        let originalRead = try AudioFileReadIdentity.read(at: file.path)
        let duration = try readAudioTags(filePath: file.path).durationSeconds
        XCTAssertGreaterThan(try XCTUnwrap(duration), 0)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file.path))
        try handle.seek(toOffset: outsideHashWindows ? UInt64(LightweightHashCalculator.windowSize + 1024) : 44)
        try handle.write(contentsOf: Data([4, 3, 2, 1]))
        try handle.close()
        try setModificationTime(of: file.path, seconds: Int(original.mtime), nanoseconds: Int(original.mtimeNanoseconds ?? 0))
        let changed = try FileMetadataCollector.collectVerified(at: file.path)
        XCTAssertEqual(changed.inode, original.inode)
        XCTAssertEqual(changed.volumeUuid, original.volumeUuid)
        XCTAssertEqual(changed.fileSize, original.fileSize)
        XCTAssertEqual(changed.mtime, original.mtime)
        XCTAssertNotEqual(try AudioFileReadIdentity.read(at: file.path), originalRead)
        XCTAssertEqual(try readAudioTags(filePath: file.path).durationSeconds, duration)
        if outsideHashWindows {
            XCTAssertEqual(changed, original, "Precise source authority must detect edits outside the sampled hash")
        } else {
            XCTAssertNotEqual(changed.lightweightHash, original.lightweightHash)
        }
        let sourceObservation = FSEventsObservation(path: file.path, isFile: true, wasModified: true, eventID: 91)
        let destinationObservation = FSEventsObservation(path: destination.path, isFile: true, wasCreated: true, eventID: 91)
        try await processor.enqueue(.init(observations: [repeatDestination ? destinationObservation : sourceObservation], highestEventID: 91))
        let reconciledReads = await reads.snapshot().handled.count
        XCTAssertGreaterThan(reconciledReads, priorReads, "Observed source drift must request the existing strict reconciliation path")
        if case .ready = session.state {} else {
            XCTFail("Source observation must finish reconciliation")
        }
        if rediscoverAfterInvalidation {
            try await processor.enqueue(.init(observations: [.init(path: destination.path, isFile: true, wasCreated: true, eventID: 92)], highestEventID: 92))
        }
        try FileManager.default.removeItem(atPath: file.path)
        let removedEventID: UInt64 = rediscoverAfterInvalidation ? 93 : 92
        try await processor.enqueue(.init(observations: [.init(path: file.path, isFile: true, wasRemoved: true, eventID: removedEventID)], highestEventID: removedEventID))
        let after = try await fixture.row(file)
        XCTAssertEqual(after.path, file.path)
        XCTAssertEqual(after.fileAvailability, .missing)
        XCTAssertEqual(try savedPaths(fixture), [file.path])
        let renames = try await fixture.database.writer.read { connection in
            try EventRecord.filter(Column("event_type") == EventType.fileRenamed.rawValue).fetchCount(connection)
        }
        XCTAssertEqual(renames, 0, "Discarded source authority must never rename to the stale destination")
        let completed = await checkpoints.snapshot()
        XCTAssertEqual(completed.checkpoints, rediscoverAfterInvalidation ? [90, 91, 92, 93] : [90, 91, 92])
    }

    func testCancelledStartupSubscriptionDoesNotResumeAfterBusySession() async throws {
        let readiness = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: readiness)
        defer { fixture.cleanup() }
        let file = try await fixture.add("before.mp3")
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let entered = expectation(description: "Already-initialized session is busy")
        let boundary = StartupSnapshotBoundary(entered: entered)
        let reader = SeratoMembershipSnapshotReader(locator: fixture.locator, watchdog: fixture.watchdog, afterParsing: { await boundary.afterParsing() })
        let reconciler = SeratoMembershipReconciler(database: fixture.database, operationEngine: fixture.engine, reader: reader)
        let session = SeratoLibrarySyncSession(reader: reader, reconciler: reconciler, scanner: scanner(fixture), operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: readiness)
        try await session.synchronize()
        let synchronization = Task { try await session.synchronize() }
        await fulfillment(of: [entered], timeout: 5)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let handler = FilesystemSyncBatchHandler(coordinator: coordinator, session: session)
        let noReplay = expectation(description: "Cancelled startup cannot checkpoint")
        noReplay.isInverted = true
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { try await handler.handle($0) }, checkpoint: { _ in noReplay.fulfill() })
        try await processor.enqueue(.init(observations: [], highestEventID: 70))
        let delivery = processor.resumeAfterInitialSync(session)
        // Give the production task a chance to receive the already-true value.
        await Task.yield()
        delivery.cancel()
        await boundary.release()
        try await synchronization.value
        await fulfillment(of: [noReplay], timeout: 0.2)
    }

    func testAlreadyCompletedInitialSyncOpensDeliveryAndRetainsReplayFailureForRetry() async throws {
        let readiness = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: readiness)
        defer { fixture.cleanup() }
        let file = try await fixture.add("before.mp3")
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let saved = try Data(contentsOf: fixture.locator.databaseV2Url)
        let session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler, scanner: scanner(fixture), operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: readiness)
        try await session.synchronize()
        XCTAssertTrue(session.initialSyncComplete)
        let destination = fixture.directory.appendingPathComponent("after.mp3")
        try FileManager.default.moveItem(atPath: file.path, toPath: destination.path)
        try Data([1, 2]).write(to: fixture.locator.databaseV2Url)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let handler = FilesystemSyncBatchHandler(coordinator: coordinator, session: session)
        let probe = StartupReplayProbe()
        let attempted = expectation(description: "Already-true initial completion opens delivery")
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { batch in
            let firstAttempt = await probe.snapshot().handled.isEmpty
            await probe.handled(batch.highestEventID)
            if firstAttempt {
                attempted.fulfill()
            }
            try await handler.handle(batch)
        }, checkpoint: { await probe.checkpoint($0) })
        try await processor.enqueue(.init(observations: [.init(path: destination.path, isFile: true, wasRenamed: true, eventID: 80)], highestEventID: 80))
        let delivery = processor.resumeAfterInitialSync(session)
        defer { delivery.cancel() }
        await fulfillment(of: [attempted], timeout: 5)
        guard await !probe.snapshot().handled.isEmpty else { return }
        await delivery.value
        await session.waitUntilIdle()
        guard case .failed = session.state else { return XCTFail("Startup replay failure must be visible") }
        var observed = await probe.snapshot()
        XCTAssertEqual(observed.handled, [80])
        XCTAssertEqual(observed.checkpoints, [])
        do { try await processor.enqueue(.init(observations: [], highestEventID: 81)); XCTFail("Failed head must retain later batches") } catch {}
        try saved.write(to: fixture.locator.databaseV2Url)
        session.beginFilesystemRetry()
        try await processor.retry()
        session.finishFilesystemRetry(succeeded: true)
        try await session.synchronize(retryingFailedCleanup: true)
        let after = try await fixture.row(file)
        XCTAssertEqual(after.libraryMembership, .active)
        XCTAssertEqual(after.path, destination.path)
        XCTAssertEqual(try savedPaths(fixture), [destination.path])
        observed = await probe.snapshot()
        XCTAssertEqual(observed.handled, [80, 80, 81])
        XCTAssertEqual(observed.checkpoints, [80, 81])
    }

    func testCaseAliasOnInsensitiveVolumePreservesMembershipAndRecording() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let directory = try ownedVolumeDirectory()
        defer { cleanupVolumeDirectory(directory) }
        let local = try await fixture.add("CaseTrack.mp3")
        let original = directory.appendingPathComponent("CaseTrack.mp3")
        try FileManager.default.moveItem(atPath: local.path, toPath: original.path)
        var file = try await replaceFixturePath(local, path: original.path, fixture: fixture)
        file.trackId = 81
        file.chromaprintFingerprint = Data([6])
        file.fingerprintedSize = file.fileSize
        file.fingerprintedMtime = file.mtime
        file.fingerprintStatus = .done
        let associated = file
        try await fixture.database.writer.write { connection in
            var track = TrackRecord(id: 81, fingerprintHash: Data([7]))
            try track.insert(connection)
            try associated.update(connection)
        }
        let alternate = directory.appendingPathComponent("casetrack.MP3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alternate.path))
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: alternate.path)])
        let snapshot = try await fixture.reader.read()
        _ = try await fixture.reconciler.reconcile(snapshot)
        let result = try await scanner(fixture).scan(snapshot: snapshot, reader: fixture.reader)
        XCTAssertEqual(result.filesIndexed, 0)
        let after = try await fixture.row(file)
        XCTAssertEqual(after.path, alternate.path)
        XCTAssertEqual(after.inode, file.inode)
        XCTAssertEqual(after.trackId, file.trackId)
        XCTAssertEqual(after.chromaprintFingerprint, Data([6]))
        XCTAssertEqual(after.fingerprintedSize, file.fileSize)
        XCTAssertEqual(after.fingerprintedMtime, file.mtime)
        XCTAssertEqual(after.membershipRevision, file.membershipRevision)
        XCTAssertEqual(after.libraryMembership, .active)
    }

    func testDistinctHardLinkIsNotACaseAlias() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let directory = try ownedVolumeDirectory()
        defer { cleanupVolumeDirectory(directory) }
        let local = try await fixture.add("original.mp3")
        let original = directory.appendingPathComponent("original.mp3")
        try FileManager.default.moveItem(atPath: local.path, toPath: original.path)
        let file = try await replaceFixturePath(local, path: original.path, fixture: fixture)
        let linked = directory.appendingPathComponent("distinct.mp3")
        try FileManager.default.linkItem(at: original, to: linked)
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: linked.path)])
        do { _ = try await fixture.reconcile(); XCTFail("Hard links remain ambiguous") }
        catch SeratoReconciliationError.ambiguousIdentity {}
        let after = try await fixture.row(file)
        XCTAssertEqual(after, file)
    }

    private func ownedVolumeDirectory() throws -> URL {
        guard FileManager.default.fileExists(atPath: mountedRoot.appendingPathComponent(".task6-test-volume").path) else {
            throw XCTSkip("Requires task-owned APFS image")
        }
        XCTAssertEqual(try mountedRoot.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames, false)
        let directory = mountedRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.standardizedFileURL
    }

    private func cleanupVolumeDirectory(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Owned volume fixture cleanup failed: \(error)") }
    }

    private func replaceFixturePath(_ file: FileRecord, path: String, fixture: SeratoRemovalFixture) async throws -> FileRecord {
        let identity = try XCTUnwrap(FileMetadataCollector.collect(at: path, includeLightweightHash: true))
        return try await fixture.database.writer.write { connection in
            var updated = file
            updated.path = path
            updated.volumeUuid = identity.volumeUuid
            updated.inode = identity.inode
            updated.fileSize = identity.fileSize
            updated.mtime = identity.mtime
            updated.lightweightHash = identity.lightweightHash
            try updated.update(connection)
            return updated
        }
    }

    private func scanner(_ fixture: SeratoRemovalFixture) -> LibraryScanner {
        LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator)
    }

    private func savedPaths(_ fixture: SeratoRemovalFixture) throws -> [String] {
        try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).map { SeratoPath.normalized($0.path) }
    }
}

private actor StartupSnapshotBoundary {
    private let entered: XCTestExpectation
    private var reads = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) {
        self.entered = entered
    }

    func afterParsing() async {
        reads += 1
        if reads == 2 {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }
    }

    func release() {
        continuation?.resume(); continuation = nil
    }
}

private actor StartupReplayProbe {
    var handled: [UInt64] = []
    var checkpoints: [UInt64] = []
    func handled(_ eventID: UInt64) {
        handled.append(eventID)
    }

    func checkpoint(_ eventID: UInt64) {
        checkpoints.append(eventID)
    }

    func snapshot() -> (handled: [UInt64], checkpoints: [UInt64]) {
        (handled, checkpoints)
    }
}

private final class SourceRemovalIntervention: @unchecked Sendable {
    private let lock = NSLock()
    private let source: String
    private var didRemove = false
    var removed: Bool {
        lock.withLock { didRemove }
    }

    init(source: String) {
        self.source = source
    }

    func removeOnce() {
        lock.withLock {
            guard !didRemove else { return }
            do { try FileManager.default.removeItem(atPath: source); didRemove = true }
            catch { XCTFail("Fixture source removal failed: \(error)") }
        }
    }
}
