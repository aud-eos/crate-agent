@testable import CrateAgent
import GRDB
import XCTest

final class RetiredFileWriteGuardTests: XCTestCase {
    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func reaches(_ target: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count == target
        }
    }

    @MainActor
    func testLifecycleCommitCannotInterleaveFinalValidationAndSynchronousAudioWrite() async throws {
        let retirementCommitted = DispatchSemaphore(value: 0)
        let retirementFinished = expectation(description: "Serialized retirement completed")
        let fixture = try await Fixture.make(tagWriter: { path, _ in
            XCTAssertEqual(retirementCommitted.wait(timeout: .now() + 1), .timedOut,
                           "A lifecycle transaction committed between final validation and actual audio I/O")
            try Data("authorized audio".utf8).write(to: URL(fileURLWithPath: path))
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.engine.apply(.writeFileTags(WriteFileTagsPayload(fileId: fixture.fileID, metadata: SeratoMetadata(title: "authorized"))))
        let writer = fixture.database.writer
        let fileID = fixture.fileID
        let counter = ReadCounter()
        try await writer.write { database in
            database.trace { event in
                guard event.expandedDescription.contains("SELECT"), event.expandedDescription.contains("file_identity_observed"), counter.reaches(1) else { return }
                writer.asyncWrite { database in
                    _ = try FileLibraryStateMutation.apply(SetFileLibraryStatePayload(fileId: fileID, expectedRevision: 0,
                                                                                      state: FileLibraryState(membership: .retired, availability: .available, libraryID: "test", retiredAt: 1)),
                                                           batchId: "serialized-retirement", timestamp: 1, in: database)
                } completion: { _, result in
                    if case let .failure(error) = result {
                        XCTFail("Lifecycle transaction failed: \(error)")
                    }
                    retirementCommitted.signal()
                    retirementFinished.fulfill()
                }
            }
        }
        fixture.closeSerato()
        _ = try await fixture.engine.drainPendingSeratoUpdates()
        await fulfillment(of: [retirementFinished], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: fixture.audio), Data("authorized audio".utf8))
        try await writer.write { database in database.trace(options: []) }
    }

    @MainActor
    func testRetirementBetweenFinalReadAndIOBlocksSingleAndBulkWrites() async throws {
        for bulk in [false, true] {
            for reactivate in [false, true] {
                let fixture = try await Fixture.make()
                defer { try? FileManager.default.removeItem(at: fixture.root) }
                try await fixture.engine.apply(.commitMetadataToSerato(CommitMetadataToSeratoPayload(
                    fileId: fixture.fileID, metadata: SeratoMetadata(title: "stale race")
                )), batchId: "race")
                if bulk {
                    try await fixture.engine.apply(.commitMetadataToSerato(CommitMetadataToSeratoPayload(
                        fileId: fixture.fileID, metadata: SeratoMetadata(artist: "stale bulk artist")
                    )), batchId: "race")
                }
                let databaseURL = fixture.library.appendingPathComponent("database V2")
                let before = try Data(contentsOf: databaseURL)
                let mainActorBlocked = DispatchSemaphore(value: 0)
                let releaseMainActor = DispatchSemaphore(value: 0)
                let mutationCommitted = expectation(description: "Lifecycle mutation committed after old final read")
                let counter = ReadCounter()
                let writer = fixture.database.writer
                let fileID = fixture.fileID
                try await writer.write { database in
                    database.trace { event in
                        guard event.description.contains("SELECT"), event.description.contains("FROM \"files\""),
                              counter.reaches(bulk ? 3 : 2) else { return }
                        Task { @MainActor in
                            mainActorBlocked.signal()
                            XCTAssertEqual(releaseMainActor.wait(timeout: .now() + 10), .success)
                        }
                        XCTAssertEqual(mainActorBlocked.wait(timeout: .now() + 10), .success)
                        writer.asyncWrite { database in
                            _ = try FileLibraryStateMutation.apply(SetFileLibraryStatePayload(fileId: fileID, expectedRevision: 0,
                                                                                              state: FileLibraryState(membership: .retired, availability: .available, libraryID: "test", retiredAt: 1)),
                                                                   batchId: "race-retire", timestamp: 1, in: database)
                            if reactivate {
                                _ = try FileLibraryStateMutation.apply(SetFileLibraryStatePayload(fileId: fileID, expectedRevision: 1,
                                                                                                  state: FileLibraryState(membership: .active, availability: .available, libraryID: "test", retiredAt: nil)),
                                                                       batchId: "race-reactivate", timestamp: 2, in: database)
                            }
                        } completion: { _, result in
                            if case let .failure(error) = result {
                                XCTFail("Lifecycle intervention failed: \(error)")
                            }
                            mutationCommitted.fulfill()
                            releaseMainActor.signal()
                        }
                    }
                }
                fixture.closeSerato()
                let outcome: ResyncOutcome = if bulk {
                    try await fixture.engine.resyncSeratoForBatch("race")
                } else {
                    try await fixture.engine.drainPendingSeratoUpdates()
                }
                await fulfillment(of: [mutationCommitted], timeout: 10)
                XCTAssertEqual(outcome.appliedCount, 0)
                XCTAssertEqual(outcome.supersededCount, bulk ? 2 : 1)
                XCTAssertEqual(try Data(contentsOf: databaseURL), before, "bulk=\(bulk), reactivate=\(reactivate)")
                try await writer.write { database in database.trace(options: []) }
            }
        }
    }

    @MainActor
    func testWatchdogSynchronousSnapshotMatchesPublishedTransitions() async {
        let state = RunningState()
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { state.running ? ["com.serato.djpro"] : [] })
        let observation = watchdog.$isSeratoRunning.sink { running in
            XCTAssertEqual(watchdog.isRunningForExternalWrite, running)
        }
        defer { observation.cancel() }
        for running in [false, true, false] {
            let previousRevision = watchdog.stateRevision
            state.running = running
            watchdog.refresh()
            XCTAssertEqual(watchdog.stateRevision, previousRevision + 1)
            XCTAssertEqual(watchdog.isSeratoRunning, running)
            let snapshot = await Task.detached { watchdog.isRunningForExternalWrite }.value
            XCTAssertEqual(snapshot, running)
            watchdog.refresh()
            XCTAssertEqual(watchdog.stateRevision, previousRevision + 1)
        }
    }

    @MainActor
    func testOldIndexUndoPreservesRetiredAndReactivatedFileIdentityAndHistory() async throws {
        for reactivate in [false, true] {
            for legacy in [false, true] {
                let fixture = try await Fixture.make()
                defer { try? FileManager.default.removeItem(at: fixture.root) }
                let indexedPath = fixture.root.appendingPathComponent("indexed.mp3").path
                try await fixture.engine.apply(.indexNewFile(IndexNewFilePayload(path: indexedPath, volumeUuid: "test", inode: 2,
                                                                                 fileSize: 14, mtime: 1)), batchId: "old-index")
                if legacy {
                    try await fixture.database.writer.write { database in
                        var event = try XCTUnwrap(EventRecord.filter(Column("batch_id") == "old-index").fetchOne(database))
                        let payload = try JSONDecoder().decode(IndexNewFilePayload.self, from: Data(event.payloadJson.utf8))
                        event.payloadJson = try XCTUnwrap(String(data: JSONEncoder().encode(payload), encoding: .utf8))
                        try event.update(database)
                    }
                }
                let indexedID = try await fixture.database.writer.write { database in
                    var track = TrackRecord(fingerprintHash: Data("same-recording".utf8))
                    try track.insert(database)
                    var indexed = try XCTUnwrap(FileRecord.filter(Column("path") == indexedPath).fetchOne(database))
                    var sibling = try XCTUnwrap(FileRecord.fetchOne(database, key: fixture.fileID))
                    indexed.trackId = track.id
                    sibling.trackId = track.id
                    try indexed.update(database)
                    try sibling.update(database)
                    return try XCTUnwrap(indexed.id)
                }
                try await fixture.engine.apply(.setFileLibraryState(SetFileLibraryStatePayload(fileId: indexedID, expectedRevision: 0,
                                                                                               state: FileLibraryState(membership: .retired, availability: .available, libraryID: "test", retiredAt: 1))))
                if reactivate {
                    try await fixture.engine.apply(.setFileLibraryState(SetFileLibraryStatePayload(fileId: indexedID, expectedRevision: 1,
                                                                                                   state: FileLibraryState(membership: .active, availability: .available, libraryID: "test", retiredAt: nil))))
                }
                let before = try await fixture.database.writer.read { database in try EventRecord.order(Column("event_id")).fetchAll(database) }
                do {
                    try await fixture.engine.undoBatch("old-index")
                    XCTFail("Old index undo deleted a retired or reactivated file")
                } catch is FileProcessingEligibilityError {}
                try await fixture.database.writer.read { database in
                    let indexed = try FileRecord.fetchOne(database, key: indexedID)
                    let sibling = try XCTUnwrap(FileRecord.fetchOne(database, key: fixture.fileID))
                    XCTAssertEqual(indexed?.id, indexedID)
                    XCTAssertEqual(indexed?.trackId, sibling.trackId)
                    let after = try EventRecord.order(Column("event_id")).fetchAll(database)
                    XCTAssertEqual(after.map(\.eventId), before.map(\.eventId))
                    XCTAssertEqual(after.map(\.fileId), before.map(\.fileId))
                    XCTAssertEqual(after.map(\.trackId), before.map(\.trackId))
                }
            }
        }
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let audio: URL
        let library: URL
        let crate: URL
        let database: LibraryDatabase
        let state: RunningState
        let watchdog: SeratoWatchdog
        let engine: OperationEngine
        let fileID: Int64

        static func make(membership: LibraryMembership = .active, tagWriter: OperationEngine.FileTagWriter? = nil) async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let library = root.appendingPathComponent("_Serato_")
            let crate = library.appendingPathComponent("Subcrates/test.crate")
            try FileManager.default.createDirectory(at: crate.deletingLastPathComponent(), withIntermediateDirectories: true)
            let audio = root.appendingPathComponent("track.mp3")
            try Data("original audio".utf8).write(to: audio)
            let seratoPath = SeratoLibraryLocator.seratoRelativePath(fromAbsolute: audio.path)
            try OperationEngineTests.synthesizeDatabaseV2BytesForTest(withTrackPaths: [seratoPath]).write(to: library.appendingPathComponent("database V2"))
            try OperationEngineTests.synthesizeCrateBytesForTest(withTrackPaths: [seratoPath]).write(to: crate)
            let database = try LibraryDatabase.openInMemory()
            let fileID = try await database.writer.write { database in
                let identity = try FileMetadataCollector.collectVerified(at: audio.path)
                var file = FileRecord(path: audio.path, volumeUuid: identity.volumeUuid, inode: identity.inode, fileSize: identity.fileSize, mtime: identity.mtime, lightweightHash: identity.lightweightHash)
                file.libraryMembership = membership
                file.fileAvailability = .available
                try file.insert(database)
                return try XCTUnwrap(file.id)
            }
            let state = RunningState()
            let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { state.running ? ["com.serato.djpro"] : [] })
            let engine = OperationEngine(database: database, seratoWatchdog: watchdog,
                                         seratoLocator: SeratoLibraryLocator(seratoDirectory: library),
                                         fileTagWriter: tagWriter ?? { path, _ in try Data("changed audio".utf8).write(to: URL(fileURLWithPath: path)) },
                                         fileTrasher: { path in
                                             try FileManager.default.moveItem(atPath: path, toPath: path + ".trashed")
                                             return path + ".trashed"
                                         })
            return Fixture(root: root, audio: audio, library: library, crate: crate, database: database,
                           state: state, watchdog: watchdog, engine: engine, fileID: fileID)
        }

        func transition(_ membership: LibraryMembership, availability: FileAvailability = .available) async throws {
            let revision = try await database.writer.read { database in
                try XCTUnwrap(FileRecord.fetchOne(database, key: fileID)).membershipRevision
            }
            try await engine.apply(.setFileLibraryState(SetFileLibraryStatePayload(fileId: fileID, expectedRevision: revision,
                                                                                   state: FileLibraryState(membership: membership, availability: availability, libraryID: "test", retiredAt: membership == .retired ? 1 : nil))))
        }

        func closeSerato() {
            state.running = false
            watchdog.refresh()
        }
    }

    @MainActor
    func testEveryQueuedVariantIsFencedAcrossRetirementAndReadd() async throws {
        for variant in ["add", "rename", "remove", "crates", "trash"] {
            let fixture = try await Fixture.make(membership: variant == "add" ? .pendingImport : .active)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let v2URL = fixture.library.appendingPathComponent("database V2")
            if variant == "add" {
                try OperationEngineTests.synthesizeDatabaseV2BytesForTest(withTrackPaths: []).write(to: v2URL)
            }
            let v2Before = try Data(contentsOf: v2URL)
            let crateBefore = try Data(contentsOf: fixture.crate)
            let mutation: TrackMutation = switch variant {
            case "add": .addTrackToSerato(AddTrackToSeratoPayload(fileId: fixture.fileID, metadata: SeratoMetadata(title: "stale")))
            case "rename": .renameFile(RenameFilePayload(fileId: fixture.fileID, newPath: fixture.root.appendingPathComponent("renamed.mp3").path))
            case "remove": .removeTrackFromSerato(RemoveTrackFromSeratoPayload(fileId: fixture.fileID))
            case "crates": .removeFileFromCrates(RemoveFileFromCratesPayload(fileId: fixture.fileID))
            default: .trashFile(TrashFilePayload(fileId: fixture.fileID))
            }
            try await fixture.engine.apply(mutation, batchId: variant)
            try await fixture.transition(.retired)
            try await fixture.transition(variant == "add" ? .pendingImport : .active)
            fixture.closeSerato()
            let outcome = try await fixture.engine.drainPendingSeratoUpdates()
            XCTAssertEqual(outcome.appliedCount, 0, variant)
            XCTAssertEqual(outcome.supersededCount, 1, variant)
            XCTAssertEqual(try Data(contentsOf: v2URL), v2Before, variant)
            XCTAssertEqual(try Data(contentsOf: fixture.crate), crateBefore, variant)
            XCTAssertEqual(try Data(contentsOf: fixture.audio), Data("original audio".utf8), variant)
        }
    }

    @MainActor
    func testCurrentStateRejectsProcessingWithoutRevisionChange() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.engine.apply(.writeFileTags(WriteFileTagsPayload(fileId: fixture.fileID, metadata: SeratoMetadata(title: "stale"))), batchId: "unavailable")
        try await fixture.transition(.active, availability: .missing)
        fixture.closeSerato()
        let outcome = try await fixture.engine.drainPendingSeratoUpdates()
        XCTAssertEqual(outcome.supersededCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.audio), Data("original audio".utf8))
        for membership in [LibraryMembership.retired, .legacyUnverified, .pendingImport] {
            try await fixture.transition(membership)
            let mutations: [TrackMutation] = [
                .setMetadata(SetMetadataPayload(fileId: fixture.fileID, metadata: SeratoMetadata(title: "rejected"))),
                .renameFile(RenameFilePayload(fileId: fixture.fileID, newPath: fixture.root.appendingPathComponent("rejected.mp3").path)),
                .applyMusicBrainzMatch(ApplyMusicBrainzMatchPayload(fileID: fixture.fileID, acoustID: nil,
                                                                    recordingMBID: "recording", releaseMBID: nil, artistMBID: nil, isrc: nil, fingerprintHash: Data("fingerprint".utf8),
                                                                    artist: nil, title: "rejected", album: nil, year: nil)),
            ]
            for mutation in mutations {
                do {
                    try await fixture.engine.apply(mutation)
                    XCTFail("Unexpected processing of \(membership)")
                } catch is FileProcessingEligibilityError {}
            }
        }
        try await fixture.engine.apply(.setMetadata(SetMetadataPayload(fileId: fixture.fileID, metadata: SeratoMetadata(title: "observed"), isSeratoAuthoritative: true)))
    }

    @MainActor
    func testLegacyHistorySurvivesInitialActivationButNeverRetirement() async throws {
        let fixture = try await Fixture.make(membership: .legacyUnverified)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.database.writer.write { database in
            let payload = CommitMetadataToSeratoPayload(fileId: fixture.fileID, metadata: SeratoMetadata(title: "legacy"))
            let json = try XCTUnwrap(String(data: JSONEncoder().encode(payload), encoding: .utf8))
            var event = EventRecord(batchId: "legacy", timestamp: 0, fileId: fixture.fileID,
                                    eventType: .metadataCommittedToSerato, payloadJson: json, inversePayloadJson: "{}")
            try event.insert(database)
        }
        try await fixture.transition(.active)
        fixture.closeSerato()
        let initial = try await fixture.engine.resyncSeratoForBatch("legacy")
        XCTAssertEqual(initial.appliedCount, 1)
        try await fixture.transition(.retired)
        try await fixture.transition(.active)
        let v2URL = fixture.library.appendingPathComponent("database V2")
        try OperationEngineTests.synthesizeDatabaseV2BytesForTest(withTrackPaths: []).write(to: v2URL)
        let bytes = try Data(contentsOf: v2URL)
        let after = try await fixture.engine.resyncSeratoForBatch("legacy")
        XCTAssertEqual(after.appliedCount, 0)
        XCTAssertEqual(after.supersededCount, 1)
        XCTAssertEqual(try Data(contentsOf: v2URL), bytes)
        let file = try await fixture.database.writer.read { database in try XCTUnwrap(FileRecord.fetchOne(database, key: fixture.fileID)) }
        XCTAssertEqual(file.lastProjectionInvalidationRevision, 2)
    }

    @MainActor
    func testOldCompletionTokenAndOldUndoCannotBecomeFreshIntent() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mutation = TrackMutation.setMetadata(SetMetadataPayload(fileId: fixture.fileID, metadata: SeratoMetadata(title: "before"), isSeratoAuthoritative: false))
        try await fixture.engine.apply(mutation, batchId: "old")
        let token = FileMembershipToken(fileId: fixture.fileID, revision: 0)
        try await fixture.transition(.retired)
        try await fixture.transition(.active)
        do {
            try await fixture.engine.apply(mutation, expectedMembershipToken: token)
            XCTFail("Accepted stale completion")
        } catch is FileProcessingEligibilityError {}
        do {
            try await fixture.engine.undoBatch("old")
            XCTFail("Accepted stale undo")
        } catch is FileProcessingEligibilityError {}
        do {
            try await fixture.engine.applyBatch([mutation], batchId: "missing-token", expectedMembershipTokens: [:])
            XCTFail("Accepted guarded batch without its file token")
        } catch is FileProcessingEligibilityError {}
        try await fixture.engine.applyBatch([mutation], batchId: "current-token", expectedMembershipTokens: [
            fixture.fileID: FileMembershipToken(fileId: fixture.fileID, revision: 2),
        ])
    }

    @MainActor
    func testRestartBetweenRealExternalWritesRetainsTheRemainder() async throws {
        let firstWrite = expectation(description: "First queued audio write reached disk")
        let releaseWriter = DispatchSemaphore(value: 0)
        let fixture = try await Fixture.make(tagWriter: { path, _ in
            try Data("changed audio".utf8).write(to: URL(fileURLWithPath: path))
            firstWrite.fulfill()
            guard releaseWriter.wait(timeout: .now() + 10) == .success else {
                throw NSError(domain: "guard-test-timeout", code: 1)
            }
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.engine.applyBatch([
            .writeFileTags(WriteFileTagsPayload(fileId: fixture.fileID, metadata: SeratoMetadata(title: "first"))),
            .removeTrackFromSerato(RemoveTrackFromSeratoPayload(fileId: fixture.fileID)),
        ], batchId: "restart")
        let v2URL = fixture.library.appendingPathComponent("database V2")
        let originalV2 = try Data(contentsOf: v2URL)
        fixture.closeSerato()
        let drain = Task { try await fixture.engine.drainPendingSeratoUpdates() }
        await fulfillment(of: [firstWrite], timeout: 10)
        fixture.state.running = true
        fixture.watchdog.refresh()
        releaseWriter.signal()
        let outcome = try await drain.value
        XCTAssertEqual(outcome.appliedCount, 1)
        XCTAssertEqual(outcome.queuedCount, 1)
        XCTAssertEqual(try Data(contentsOf: v2URL), originalV2)
        fixture.closeSerato()
        let resumed = try await fixture.engine.drainPendingSeratoUpdates()
        XCTAssertEqual(resumed.appliedCount, 1)
        XCTAssertTrue(try readDatabaseRecords(databasePath: v2URL.path).isEmpty)
    }

    @MainActor
    func testPendingExplicitAddIsPermittedButDoesNotAuthorizeProcessing() async throws {
        let fixture = try await Fixture.make(membership: .pendingImport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let v2URL = fixture.library.appendingPathComponent("database V2")
        try OperationEngineTests.synthesizeDatabaseV2BytesForTest(withTrackPaths: []).write(to: v2URL)
        do {
            try await fixture.engine.apply(.writeFileTags(WriteFileTagsPayload(fileId: fixture.fileID, metadata: SeratoMetadata(title: "blocked"))))
            XCTFail("Pending import was processed")
        } catch is FileProcessingEligibilityError {}
        try await fixture.engine.apply(.addTrackToSerato(AddTrackToSeratoPayload(fileId: fixture.fileID, metadata: SeratoMetadata(title: "new import"))))
        fixture.closeSerato()
        let result = try await fixture.engine.drainPendingSeratoUpdates()
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(try readDatabaseRecords(databasePath: v2URL.path).count, 1)
        let confirmed = try await fixture.database.writer.read { database in try XCTUnwrap(FileRecord.fetchOne(database, key: fixture.fileID)) }
        XCTAssertEqual(confirmed.libraryMembership, .active)
        XCTAssertEqual(confirmed.membershipRevision, 1)
    }

    @MainActor
    func testExplicitImportReactivatesOnlyTheVerifiedSameFile() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let audio = fixture.root.appendingPathComponent("import.mp3")
        try Data("import audio".utf8).write(to: audio)
        let coordinator = ImportCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let first = await coordinator.importDroppedItems([audio])
        XCTAssertEqual(first.filesImported, 1)
        let pending = try await fixture.database.writer.read { database in
            try XCTUnwrap(FileRecord.filter(Column("path") == audio.path).fetchOne(database))
        }
        XCTAssertEqual(pending.libraryMembership, .pendingImport)
        XCTAssertEqual(pending.membershipRevision, 1)
        let fileID = try XCTUnwrap(pending.id)
        fixture.closeSerato()
        _ = try await fixture.engine.drainPendingSeratoUpdates()
        try await fixture.engine.apply(.setFileLibraryState(SetFileLibraryStatePayload(fileId: fileID, expectedRevision: 2,
                                                                                       state: FileLibraryState(membership: .retired, availability: .available, libraryID: "test", retiredAt: 1))))
        let readded = await coordinator.importDroppedItems([audio])
        XCTAssertEqual(readded.filesImported, 1)
        let active = try await fixture.database.writer.read { database in try XCTUnwrap(FileRecord.fetchOne(database, key: fileID)) }
        XCTAssertEqual(active.libraryMembership, .active)
        XCTAssertEqual(active.membershipRevision, 5)
        XCTAssertEqual(active.lastProjectionInvalidationRevision, 3)
        try await fixture.engine.apply(.setFileLibraryState(SetFileLibraryStatePayload(fileId: fileID, expectedRevision: 5,
                                                                                       state: FileLibraryState(membership: .retired, availability: .available, libraryID: "test", retiredAt: 1))))
        try Data("replacement audio with a different size".utf8).write(to: audio)
        let replacement = await coordinator.importDroppedItems([audio])
        XCTAssertEqual(replacement.filesImported, 0)
        XCTAssertEqual(replacement.filesSkipped, 1)
    }

    @MainActor
    func testExplicitRetryReplacesPendingIntentAfterRealAddFailure() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.closeSerato()
        let audio = fixture.root.appendingPathComponent("retry.mp3")
        try Data("retry audio".utf8).write(to: audio)
        let v2URL = fixture.library.appendingPathComponent("database V2")
        try Data("corrupt V2".utf8).write(to: v2URL)
        let coordinator = ImportCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let failed = await coordinator.importDroppedItems([audio])
        XCTAssertEqual(failed.filesImported, 0)
        let pending = try await fixture.database.writer.read { database in
            try XCTUnwrap(FileRecord.filter(Column("path") == audio.path).fetchOne(database))
        }
        XCTAssertEqual(pending.libraryMembership, .pendingImport)
        XCTAssertEqual(pending.membershipRevision, 1)
        try OperationEngineTests.synthesizeDatabaseV2BytesForTest(withTrackPaths: []).write(to: v2URL)
        let retry = await coordinator.importDroppedItems([audio])
        XCTAssertEqual(retry.filesImported, 1)
        let active = try await fixture.database.writer.read { database in try XCTUnwrap(FileRecord.fetchOne(database, key: pending.id)) }
        XCTAssertEqual(active.libraryMembership, .active)
        XCTAssertEqual(active.membershipRevision, 3)
        XCTAssertEqual(try readDatabaseRecords(databasePath: v2URL.path).count, 1)
    }

    @MainActor
    func testNewExplicitImportIntentSupersedesAlreadyQueuedAdd() async throws {
        let fixture = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let audio = fixture.root.appendingPathComponent("retry-queued.mp3")
        try Data("queued retry audio".utf8).write(to: audio)
        let coordinator = ImportCoordinator(operationEngine: fixture.engine, database: fixture.database)
        _ = await coordinator.importDroppedItems([audio])
        let retry = await coordinator.importDroppedItems([audio])
        XCTAssertEqual(retry.filesImported, 1)
        let requests = try await fixture.database.writer.read { database in
            try EventRecord.filter(Column("event_type") == EventType.fileImportRequested.rawValue)
                .order(Column("event_id")).fetchAll(database)
        }
        XCTAssertEqual(requests.count, 2)
        let request = try XCTUnwrap(requests.last)
        let inverse = try JSONDecoder().decode(SetFileLibraryStatePayload.self, from: Data(request.inversePayloadJson.utf8))
        XCTAssertEqual(inverse.state.membership, .pendingImport)
        XCTAssertEqual(inverse.expectedRevision, 2)
        XCTAssertFalse(EventHistoryQuery.canUndoBatch(typeList: [EventType.fileImportRequested.rawValue]))
        fixture.closeSerato()
        let result = try await fixture.engine.drainPendingSeratoUpdates()
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.supersededCount, 1)
        let active = try await fixture.database.writer.read { database in
            try XCTUnwrap(FileRecord.filter(Column("path") == audio.path).fetchOne(database))
        }
        XCTAssertEqual(active.membershipRevision, 3)
    }

    @MainActor
    private final class RunningState {
        var running = true
    }

    @MainActor
    func testQueuedMetadataCannotWriteAfterRetirementOrReactivation() async throws {
        for reactivate in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let audio = directory.appendingPathComponent("track.mp3")
            try Data("original audio".utf8).write(to: audio)
            let databaseV2 = directory.appendingPathComponent("database V2")
            try OperationEngineTests.synthesizeDatabaseV2BytesForTest(withTrackPaths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: audio.path)]).write(to: databaseV2)
            let originalV2 = try Data(contentsOf: databaseV2)
            let originalAudio = try Data(contentsOf: audio)
            let database = try LibraryDatabase.openInMemory()
            let fileID = try await database.writer.write { db in
                let identity = try FileMetadataCollector.collectVerified(at: audio.path)
                var file = FileRecord(path: audio.path, volumeUuid: identity.volumeUuid, inode: identity.inode, fileSize: identity.fileSize, mtime: identity.mtime, lightweightHash: identity.lightweightHash)
                file.libraryMembership = .active
                file.fileAvailability = .available
                try file.insert(db)
                return try XCTUnwrap(file.id)
            }
            let state = RunningState()
            let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { state.running ? ["com.serato.djpro"] : [] })
            let engine = OperationEngine(database: database, seratoWatchdog: watchdog,
                                         seratoLocator: SeratoLibraryLocator(seratoDirectory: directory),
                                         fileTagWriter: { path, _ in try Data("changed audio".utf8).write(to: URL(fileURLWithPath: path)) })
            try await engine.applyBatch([
                .commitMetadataToSerato(CommitMetadataToSeratoPayload(fileId: fileID, metadata: SeratoMetadata(title: "STALE"))),
                .writeFileTags(WriteFileTagsPayload(fileId: fileID, metadata: SeratoMetadata(title: "STALE"))),
            ], batchId: "stale")
            try await engine.apply(.setFileLibraryState(SetFileLibraryStatePayload(fileId: fileID, expectedRevision: 0,
                                                                                   state: FileLibraryState(membership: .retired, availability: .available, libraryID: "test", retiredAt: 1))))
            if reactivate {
                try await engine.apply(.setFileLibraryState(SetFileLibraryStatePayload(fileId: fileID, expectedRevision: 1,
                                                                                       state: FileLibraryState(membership: .active, availability: .available, libraryID: "test", retiredAt: nil))))
            }
            state.running = false
            watchdog.refresh()
            try await engine.drainPendingSeratoUpdates()
            XCTAssertEqual(try Data(contentsOf: databaseV2), originalV2)
            XCTAssertEqual(try Data(contentsOf: audio), originalAudio)
            _ = try await engine.resyncSeratoForBatch("stale")
            XCTAssertEqual(try Data(contentsOf: databaseV2), originalV2)
            XCTAssertEqual(try Data(contentsOf: audio), originalAudio)
        }
    }
}
