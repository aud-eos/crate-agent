@testable import CrateAgent
import Foundation
import GRDB
import XCTest

@MainActor
final class PR123LegacyImportAndTrashTests: XCTestCase {
    func testProductionWatchRootsCaptureNativeTrashThroughRealPipeline() async throws {
        try await nativeTrashCapture(replaying: false)
    }

    func testCombinedWatchCursorReplaysNativeTrashWhileStopped() async throws {
        try await nativeTrashCapture(replaying: true)
    }

    private func nativeTrashCapture(replaying: Bool) async throws {
        let mount = URL(fileURLWithPath: "/private/tmp/crate-agent-task6-volume").standardizedFileURL
        guard FileManager.default.fileExists(atPath: mount.appendingPathComponent(".task6-test-volume").path) else {
            throw XCTSkip("Requires task-owned APFS volume")
        }
        let music = mount.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: music) }
        let readiness = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: readiness)
        defer { fixture.cleanup() }
        let local = try await fixture.add("native-trash.wav", bytes: FinalRemovalIntegrationTests.wav())
        let source = music.appendingPathComponent("native-trash.wav")
        try FileManager.default.moveItem(atPath: local.path, toPath: source.path)
        let identity = try FileMetadataCollector.collectVerified(at: source.path)
        let file = try await fixture.database.writer.write { connection in
            var moved = local
            moved.path = identity.path
            moved.volumeUuid = identity.volumeUuid
            moved.inode = identity.inode
            moved.fileSize = identity.fileSize
            moved.mtime = identity.mtime
            moved.lightweightHash = identity.lightweightHash
            try moved.update(connection)
            return moved
        }
        try fixture.save(paths: [file.path])
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: music, create: true).standardizedFileURL
        guard trash.path.hasPrefix(mount.path + "/") else { return XCTFail("Native Trash must belong to the owned volume") }
        let configuration = try FilesystemWatchConfiguration(musicFolder: music)
        XCTAssertTrue(configuration.watchedPaths.contains(trash.path), "Production watch derivation must include the applicable native Trash")
        let scanner = LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator)
        let session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler, scanner: scanner, operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: readiness)
        try await session.synchronize()
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let handler = FilesystemSyncBatchHandler(coordinator: coordinator, session: session)
        let processed = expectation(description: "Native Trash destination captured and checkpointed")
        processed.assertForOverFulfill = false
        let initialCheckpoint = replaying ? expectation(description: "Owned marker establishes a real stream cursor") : nil
        initialCheckpoint?.assertForOverFulfill = false
        let probe = NativeTrashPipelineProbe()
        let processor = FilesystemEventProcessor(handler: { batch in
            await probe.record(batch)
            try await handler.handle(batch)
        }, checkpoint: { eventID in
            let row = try await fixture.database.writer.read { try FileRecord.fetchOne($0, key: file.id) }
            await probe.checkpoint(eventID)
            if replaying, await probe.snapshot().paths.contains(where: { $0.hasSuffix("checkpoint-marker.txt") }) {
                initialCheckpoint?.fulfill()
            }
            if row?.fileAvailability == .trashed {
                processed.fulfill()
            }
        })
        let stream = AsyncStream<FilesystemEventBatch>.makeStream()
        let delivery = Task {
            for await batch in stream.stream {
                do { try await processor.enqueue(batch) }
                catch { XCTFail("Native event pipeline failed: \(error)") }
            }
        }
        var watcher = FSEventsWatcher(watchedPaths: configuration.watchedPaths, coalescingLatency: 0.05) { stream.continuation.yield($0) }
        try watcher.start()
        defer { watcher.stop(); stream.continuation.finish(); delivery.cancel() }
        try await Task.sleep(nanoseconds: 200_000_000)
        var resumeCursor: UInt64?
        if let initialCheckpoint {
            try Data([1]).write(to: music.appendingPathComponent("checkpoint-marker.txt"))
            await fulfillment(of: [initialCheckpoint], timeout: 5)
            resumeCursor = await probe.snapshot().checkpoints.last
            XCTAssertGreaterThan(try XCTUnwrap(resumeCursor), 0)
            watcher.stop()
        }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
        let destination = try XCTUnwrap(resultingURL as URL?).standardizedFileURL
        guard destination.path.hasPrefix(trash.path + "/") else { return XCTFail("Native move escaped the owned Trash") }
        defer { try? FileManager.default.removeItem(at: destination) }
        if let resumeCursor {
            let since = configuration.resumeEventID { $0 == configuration.checkpointKey ? resumeCursor : nil }
            watcher = FSEventsWatcher(watchedPaths: configuration.watchedPaths, sinceWhen: since, coalescingLatency: 0.05) { stream.continuation.yield($0) }
            try watcher.start()
        }
        await fulfillment(of: [processed], timeout: 5)
        watcher.stop()
        stream.continuation.finish()
        await delivery.value
        let observed = await probe.snapshot()
        XCTAssertTrue(observed.paths.contains { SeratoPath.normalized($0) == SeratoPath.normalized(destination.path) })
        XCTAssertFalse(observed.checkpoints.isEmpty)
        let after = try await fixture.row(file)
        XCTAssertEqual(after.path, file.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileAvailabilityResolver().inspect(path: destination.path, volumeID: identity.volumeUuid), .trashed)
        XCTAssertEqual(after.fileAvailability, .trashed, "Observed: \(observed.observations)")
        XCTAssertEqual(after.libraryMembership, .active)
        XCTAssertEqual(try savedPaths(fixture), [file.path])
        let events = try await fixture.database.writer.read { try EventRecord.fetchAll($0) }
        XCTAssertFalse(events.contains { $0.eventType == .fileRenamed })
    }

    func testWatchConfigurationCreatesOwnedTrashAndScopesCombinedCursor() throws {
        let mount = URL(fileURLWithPath: "/private/tmp/crate-agent-task6-volume").standardizedFileURL
        guard FileManager.default.fileExists(atPath: mount.appendingPathComponent(".task6-test-volume").path) else {
            throw XCTSkip("Requires task-owned APFS volume")
        }
        let music = mount.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: music) }
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: music, create: true).standardizedFileURL
        guard trash.path.hasPrefix(mount.path + "/") else { return XCTFail("Trash setup must remain on the owned volume") }
        try FileManager.default.removeItem(at: trash)
        let configuration = try FilesystemWatchConfiguration(musicFolder: music)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
        XCTAssertEqual(Set(configuration.watchedPaths), Set([music.path, trash.path]))
        let duplicate = try FilesystemWatchConfiguration(musicFolder: music, trashDirectory: { $0.appendingPathComponent(".") })
        XCTAssertEqual(duplicate.watchedPaths, [music.path])
        XCTAssertNotEqual(duplicate.checkpointKey, configuration.checkpointKey)
        XCTAssertEqual(configuration.resumeEventID { _ in nil }, FSEventsWatcher.sinceNow)
        XCTAssertEqual(configuration.resumeEventID { $0 == music.path ? 7 : nil }, 7)
        XCTAssertEqual(configuration.resumeEventID { $0 == configuration.checkpointKey ? 12 : 7 }, 12)
        XCTAssertThrowsError(try FilesystemWatchConfiguration(musicFolder: music, trashDirectory: { _ in throw CocoaError(.fileWriteNoPermission) }))
    }

    func testEmptyWatchConfigurationFailsVisibly() {
        let watcher = FSEventsWatcher(watchedPaths: [], handler: { _ in })
        XCTAssertThrowsError(try watcher.start())
    }

    func testExplicitImportBackfillsLegacyHashThroughJournal() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await legacyFile(fixture, membership: .retired)
        let result = await ImportCoordinator(operationEngine: fixture.engine, database: fixture.database)
            .importDroppedItems([URL(fileURLWithPath: file.path)])
        XCTAssertEqual(result.filesImported, 1)
        XCTAssertEqual(result.filesSkipped, 0)
        let imported = try await fixture.row(file)
        XCTAssertEqual(imported.id, file.id)
        XCTAssertEqual(imported.lightweightHash, try FileMetadataCollector.collectVerified(at: file.path).lightweightHash)
        XCTAssertEqual(imported.libraryMembership, .active)
        XCTAssertEqual(imported.membershipRevision, file.membershipRevision + 2)
        XCTAssertEqual(try savedPaths(fixture), [file.path])
        try await assertJournaledBackfill(fixture, original: file)
    }

    func testBeginImportTransactionBackfillsUnknownHashBeforeIntent() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await legacyFile(fixture, membership: .retired)
        let identity = try FileMetadataCollector.collectVerified(at: file.path)
        _ = try await fixture.engine.apply(.beginFileImport(.init(fileId: XCTUnwrap(file.id), expectedRevision: file.membershipRevision, identity: identity)), batchId: "legacy-import")
        let imported = try await fixture.row(file)
        XCTAssertEqual(imported.identity, identity)
        XCTAssertEqual(imported.libraryMembership, .pendingImport)
        XCTAssertEqual(imported.membershipRevision, file.membershipRevision + 1)
        try await assertJournaledBackfill(fixture, original: file)
    }

    func testImportRejectsKnownHashAndPhysicalIdentityMismatch() async throws {
        for mismatch in ["hash", "inode", "size", "mtime", "volume"] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            var file = try await legacyFile(fixture, membership: .retired)
            switch mismatch {
            case "hash": file.lightweightHash = Data([99])
            case "inode": file.inode += 1
            case "size": file.fileSize += 1
            case "mtime": file.mtime -= 1
            case "volume": file.volumeUuid = UUID().uuidString
            default: XCTFail("Unknown fixture mismatch")
            }
            let original = file
            try await fixture.database.writer.write { try original.update($0) }
            let result = await ImportCoordinator(operationEngine: fixture.engine, database: fixture.database)
                .importDroppedItems([URL(fileURLWithPath: file.path)])
            XCTAssertEqual(result.filesImported, 0, mismatch)
            let identity = try FileMetadataCollector.collectVerified(at: file.path)
            do {
                _ = try await fixture.engine.apply(.beginFileImport(.init(fileId: XCTUnwrap(file.id), expectedRevision: file.membershipRevision, identity: identity)))
                XCTFail("Transaction accepted \(mismatch) mismatch")
            } catch is FileProcessingEligibilityError {}
            let after = try await fixture.row(file)
            XCTAssertEqual(after, original)
            let count = try await fixture.events()
            XCTAssertEqual(count, 0)
            XCTAssertEqual(try savedPaths(fixture), [])
        }
    }

    func testBeginImportRechecksActualFileAfterPreflight() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("changed.wav", membership: .retired, bytes: FinalRemovalIntegrationTests.wav())
        let preflight = try FileMetadataCollector.collectVerified(at: file.path)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file.path))
        try handle.seek(toOffset: 44)
        try handle.write(contentsOf: Data([4, 3, 2, 1]))
        try handle.close()
        XCTAssertEqual(try FileMetadataCollector.collectVerified(at: file.path).inode, preflight.inode)
        XCTAssertNotEqual(try FileMetadataCollector.collectVerified(at: file.path).lightweightHash, preflight.lightweightHash)
        do {
            _ = try await fixture.engine.apply(.beginFileImport(.init(fileId: XCTUnwrap(file.id), expectedRevision: file.membershipRevision, identity: preflight)))
            XCTFail("Import transaction must reject a file changed after preflight")
        } catch is FileProcessingEligibilityError {}
        let after = try await fixture.row(file)
        XCTAssertEqual(after, file)
        let count = try await fixture.events()
        XCTAssertEqual(count, 0)
    }

    func testObservationPreviousIdentityRemainsStrictForUnknownHash() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await legacyFile(fixture, membership: .retired)
        let identity = try FileMetadataCollector.collectVerified(at: file.path)
        do {
            _ = try await fixture.engine.apply(.observeFileIdentity(.init(fileId: XCTUnwrap(file.id), expectedRevision: file.membershipRevision,
                                                                          previousIdentity: identity, identity: identity)))
            XCTFail("An import-compatible unknown hash is not an exact previous observation")
        } catch is FileProcessingEligibilityError {}
        let after = try await fixture.row(file)
        XCTAssertEqual(after, file)
        let count = try await fixture.events()
        XCTAssertEqual(count, 0)
    }

    func testUnknownVolumeRejectsLegacyIdentityMismatch() async throws {
        for mismatch in ["hash", "inode", "size", "mtime"] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            var file = try await legacyFile(fixture, membership: .legacyUnverified)
            file.volumeUuid = LegacyFileIdentity.unknownVolume
            switch mismatch {
            case "hash": file.lightweightHash = Data([99])
            case "inode": file.inode += 1
            case "size": file.fileSize += 1
            case "mtime": file.mtime -= 1
            default: XCTFail("Unknown fixture mismatch")
            }
            let original = file
            try await fixture.database.writer.write { try original.update($0) }
            try fixture.save(paths: [file.path])
            do { _ = try await fixture.reconcile(); XCTFail("Unknown-volume \(mismatch) mismatch must surface ambiguity") }
            catch SeratoReconciliationError.ambiguousIdentity {}
            let after = try await fixture.row(file)
            XCTAssertEqual(after, original)
        }
    }

    func testUnknownVolumeTransactionRejectsUnverifiedAdoption() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        var file = try await legacyFile(fixture, membership: .legacyUnverified)
        file.volumeUuid = LegacyFileIdentity.unknownVolume
        file.lightweightHash = Data([99])
        let original = file
        try await fixture.database.writer.write { try original.update($0) }
        let identity = try FileMetadataCollector.collectVerified(at: file.path)
        do {
            _ = try await fixture.engine.apply(.observeFileIdentity(.init(fileId: XCTUnwrap(file.id), expectedRevision: file.membershipRevision,
                                                                          previousIdentity: file.identity, identity: identity)))
            XCTFail("Transaction must reject an unknown-volume row whose content does not verify")
        } catch SeratoReconciliationError.ambiguousIdentity {}
        let after = try await fixture.row(file)
        XCTAssertEqual(after, original)
        let count = try await fixture.events()
        XCTAssertEqual(count, 0)
    }

    func testUnknownVolumeAdoptionRechecksPhysicalFileAtCommit() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        var file = try await legacyFile(fixture, membership: .legacyUnverified)
        file.volumeUuid = LegacyFileIdentity.unknownVolume
        let original = file
        try await fixture.database.writer.write { try original.update($0) }
        try fixture.save(paths: [file.path])
        let reconciler = SeratoMembershipReconciler(database: fixture.database, operationEngine: fixture.engine, reader: fixture.reader, beforeCommit: {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: original.path))
            try handle.seek(toOffset: 44)
            try handle.write(contentsOf: Data([9, 8, 7, 6]))
            try handle.close()
        })
        do { _ = try await reconciler.reconcile(fixture.reader.read()); XCTFail("Changed physical source must reject adoption at commit") }
        catch is FileProcessingEligibilityError {}
        let after = try await fixture.row(file)
        XCTAssertEqual(after, original)
        let count = try await fixture.events()
        XCTAssertEqual(count, 0)
    }

    func testArbitraryUnknownVolumeDoesNotAdoptReadablePath() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        var file = try await legacyFile(fixture, membership: .legacyUnverified)
        file.volumeUuid = UUID().uuidString
        let original = file
        try await fixture.database.writer.write { try original.update($0) }
        try fixture.save(paths: [file.path])
        _ = try await fixture.reconcile()
        let after = try await fixture.row(file)
        XCTAssertEqual(after.identity, original.identity)
        XCTAssertEqual(after.libraryMembership, .legacyUnverified)
        XCTAssertEqual(after.fileAvailability, .offline)
    }

    func testReadableUnknownVolumeRepairsBeforeLegacyActivation() async throws {
        for hashKnown in [false, true] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            var file = try await legacyFile(fixture, membership: .legacyUnverified)
            let identity = try FileMetadataCollector.collectVerified(at: file.path)
            file.volumeUuid = LegacyFileIdentity.unknownVolume
            file.lightweightHash = hashKnown ? identity.lightweightHash : nil
            file.trackId = 88
            file.chromaprintFingerprint = Data([3, 4])
            file.fingerprintStatus = .done
            file.fingerprintedSize = file.fileSize
            file.fingerprintedMtime = file.mtime
            let original = file
            try await fixture.database.writer.write { connection in
                var track = TrackRecord(id: 88, fingerprintHash: Data([8]))
                try track.insert(connection)
                try original.update(connection)
            }
            try fixture.save(paths: [file.path])
            _ = try await fixture.reconcile()
            let after = try await fixture.row(file)
            XCTAssertEqual(after.identity, identity)
            XCTAssertEqual(after.libraryMembership, .active)
            XCTAssertEqual(after.fileAvailability, .available)
            XCTAssertEqual(after.membershipRevision, original.membershipRevision + 1)
            XCTAssertEqual(after.trackId, original.trackId)
            XCTAssertEqual(after.chromaprintFingerprint, original.chromaprintFingerprint)
            XCTAssertEqual(after.fingerprintStatus, original.fingerprintStatus)
            XCTAssertEqual(after.fingerprintedSize, original.fingerprintedSize)
            let observations = try await fixture.database.writer.read { connection in
                try EventRecord.filter(Column("event_type") == EventType.fileIdentityObserved.rawValue).fetchAll(connection)
            }
            XCTAssertEqual(observations.count, 1)
            if let observation = observations.first {
                let inverse = try JSONDecoder().decode(FileRecord.self, from: Data(observation.inversePayloadJson.utf8))
                XCTAssertEqual(inverse, original)
            }
        }
    }

    func testMissingUnknownVolumeRemainsUnresolvedWithoutIdentityAdoption() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        var file = try await legacyFile(fixture, membership: .legacyUnverified)
        file.volumeUuid = LegacyFileIdentity.unknownVolume
        let original = file
        try await fixture.database.writer.write { try original.update($0) }
        try fixture.save(paths: [file.path])
        try FileManager.default.removeItem(atPath: file.path)
        _ = try await fixture.reconcile()
        let after = try await fixture.row(file)
        XCTAssertEqual(after.identity, original.identity)
        XCTAssertEqual(after.libraryMembership, .legacyUnverified)
        XCTAssertEqual(after.fileAvailability, .offline)
        XCTAssertEqual(after.membershipRevision, original.membershipRevision)
    }

    private func legacyFile(_ fixture: SeratoRemovalFixture, membership: LibraryMembership) async throws -> FileRecord {
        var file = try await fixture.add("legacy.wav", membership: membership, bytes: FinalRemovalIntegrationTests.wav())
        file.lightweightHash = nil
        let legacy = file
        try await fixture.database.writer.write { try legacy.update($0) }
        return legacy
    }

    private func assertJournaledBackfill(_ fixture: SeratoRemovalFixture, original: FileRecord) async throws {
        let events = try await fixture.database.writer.read { connection in
            try EventRecord.order(Column("event_id")).fetchAll(connection)
        }
        XCTAssertEqual(events.first?.eventType, .fileIdentityObserved)
        XCTAssertTrue(events.contains { $0.eventType == .fileImportRequested })
        if let observation = events.first, observation.eventType == .fileIdentityObserved {
            let inverse = try JSONDecoder().decode(FileRecord.self, from: Data(observation.inversePayloadJson.utf8))
            XCTAssertEqual(inverse, original)
            let payload = try JSONDecoder().decode(ObserveFileIdentityPayload.self, from: Data(observation.payloadJson.utf8))
            XCTAssertNil(payload.previousIdentity.lightweightHash)
            XCTAssertNotNil(payload.identity.lightweightHash)
        }
    }

    private func savedPaths(_ fixture: SeratoRemovalFixture) throws -> [String] {
        try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).map { SeratoPath.normalized($0.path) }
    }
}

private actor NativeTrashPipelineProbe {
    private var observations: [FSEventsObservation] = []
    private var checkpoints: [UInt64] = []

    func record(_ batch: FilesystemEventBatch) {
        observations += batch.observations
    }

    func checkpoint(_ eventID: UInt64) {
        checkpoints.append(eventID)
    }

    func snapshot() -> (paths: [String], checkpoints: [UInt64], observations: [FSEventsObservation]) {
        (observations.map(\.path), checkpoints, observations)
    }
}
