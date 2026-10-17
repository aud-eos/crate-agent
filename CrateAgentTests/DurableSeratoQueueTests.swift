@testable import CrateAgent
import Foundation
import GRDB
import XCTest

/// Restart is a new `OperationEngine` and session over the same database:
/// everything the engine kept in memory is gone, only SQLite survives.
@MainActor
final class DurableSeratoQueueTests: XCTestCase {
    func testQueuedWritesSurviveRestartAndApplyOnceWhenSeratoQuits() async throws {
        for seratoRunningAtRelaunch in [true, false] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("queued.wav", bytes: FinalRemovalIntegrationTests.wav())
            try save(fixture, paths: [file.path])
            let store = SyncCheckpointStore(database: fixture.database)
            try await makeSession(fixture, engine: fixture.engine, store: store).synchronize()
            let fileID = try XCTUnwrap(file.id)
            let fingerprint = try await makeMatchable(fixture, fileID: fileID)
            setRunning(fixture, true)
            try await fixture.engine.apply(.applyMusicBrainzMatch(matchPayload(file, fingerprint: fingerprint, title: "Matched title")), batchId: "queued-match")
            let renamed = fixture.directory.appendingPathComponent("renamed.wav").path
            try await fixture.engine.apply(.renameFile(.init(fileId: fileID, newPath: renamed, previousPath: file.path, physicalMove: true)), batchId: "queued-rename")

            let recorder = BoundaryRecorder()
            let relaunched = recordingEngine(fixture, recorder: recorder)
            let readiness = LibrarySyncReadiness()
            let session = makeSession(fixture, engine: relaunched, store: store, readiness: readiness)
            setRunning(fixture, seratoRunningAtRelaunch)
            if seratoRunningAtRelaunch {
                do { try await session.synchronize(); XCTFail("Sync ran while Serato was running") }
                catch SeratoMembershipSnapshotError.seratoRunning {}
                XCTAssertEqual(session.state, .waitingForSerato)
                let queued = try await relaunched.pendingSeratoWriteCount
                XCTAssertEqual(queued, 3, "Match metadata, match tags, and rename survive the restart")
                setRunning(fixture, false)
            }
            try await session.synchronize()

            let record = try XCTUnwrap(readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first)
            XCTAssertEqual(SeratoPath.normalized(record.path), renamed)
            XCTAssertEqual(record.title, "Matched title")
            XCTAssertEqual(try readAudioTags(filePath: renamed).title, "Matched title")
            XCTAssertEqual(recorder.tagWrites, 1)
            let remaining = try await relaunched.pendingSeratoWriteCount
            XCTAssertEqual(remaining, 0)
            let header = try await store.loadHeader()
            XCTAssertNotNil(header)
            XCTAssertNoThrow(try readiness.capture())
        }
    }

    func testInterruptedDrainResumesWithoutReapplyingOrRejournaling() async throws {
        for kind in [SeratoWriteKind.metadataUpdate, .rename, .removeFromCrates, .addTrack, .fileTagWrite] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("interrupted.wav", membership: kind == .addTrack ? .pendingImport : .active, bytes: FinalRemovalIntegrationTests.wav())
            let fileID = try XCTUnwrap(file.id)
            try save(fixture, paths: kind == .addTrack ? [] : [file.path])
            let crates = try saveCrates(fixture, paths: [file.path])
            setRunning(fixture, true)
            switch kind {
            case .metadataUpdate:
                try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: "Queued title"))))
            case .rename:
                let renamed = fixture.directory.appendingPathComponent("renamed.wav").path
                try await fixture.engine.apply(.renameFile(.init(fileId: fileID, newPath: renamed, previousPath: file.path, physicalMove: true)))
            case .removeFromCrates:
                try await fixture.engine.apply(.removeFileFromCrates(.init(fileId: fileID)))
            case .addTrack:
                try await fixture.engine.apply(.addTrackToSerato(.init(fileId: fileID, metadata: .init(title: "Imported"))))
            default:
                try await fixture.engine.apply(.writeFileTags(.init(fileId: fileID, metadata: .init(title: "Queued tag"))))
            }
            setRunning(fixture, false)
            let crashingRecorder = BoundaryRecorder()
            let crashing = recordingEngine(fixture, recorder: crashingRecorder)
            try await fixture.database.writer.write { database in
                try database.execute(sql: """
                CREATE TEMP TRIGGER crash_after_io BEFORE DELETE ON serato_write_queue
                BEGIN SELECT RAISE(ABORT, 'process exited after external I/O'); END
                """)
            }
            do { _ = try await crashing.drainPendingSeratoUpdates(); XCTFail("\(kind): the simulated crash did not interrupt the drain") }
            catch {}
            try await fixture.database.writer.write { database in try database.execute(sql: "DROP TRIGGER crash_after_io") }
            let libraryBytes = try Data(contentsOf: fixture.locator.databaseV2Url)
            let crateBytes = try crates.map { url, _ in try Data(contentsOf: url) }
            let eventCount = try await fixture.events()

            let recorder = BoundaryRecorder()
            let relaunched = recordingEngine(fixture, recorder: recorder)
            _ = try await relaunched.drainPendingSeratoUpdates()

            XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), libraryBytes, "\(kind): replay rewrote database V2")
            XCTAssertEqual(try crates.map { url, _ in try Data(contentsOf: url) }, crateBytes, "\(kind): replay rewrote a crate")
            let replayedEvents = try await fixture.events()
            XCTAssertEqual(replayedEvents - eventCount, kind == .addTrack ? 1 : 0, "\(kind): only the rolled-back import activation is journaled on replay")
            if kind == .addTrack {
                let imported = try await fixture.row(file)
                XCTAssertEqual(imported.libraryMembership, .active)
            }
            let remaining = try await relaunched.pendingSeratoWriteCount
            XCTAssertEqual(remaining, 0, "\(kind)")
            XCTAssertEqual(recorder.tagWrites, 0, "\(kind): an attempted audio write was repeated")
            let dispositions = try await fixture.database.writer.read { database in
                try String.fetchAll(database, sql: "SELECT disposition FROM serato_write_dispositions")
            }
            XCTAssertEqual(dispositions, kind == .fileTagWrite ? [SeratoWriteDisposition.interrupted.rawValue] : [], "\(kind)")
        }
    }

    func testDuplicateCleanupResumesAfterRestart() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let keeper = try await fixture.add("keeper.wav", bytes: FinalRemovalIntegrationTests.wav())
        let target = try await fixture.add("target.wav", bytes: FinalRemovalIntegrationTests.wav())
        try save(fixture, paths: [keeper.path, target.path])
        let crates = try saveCrates(fixture, paths: [keeper.path, target.path])
        let firstRecorder = BoundaryRecorder()
        let first = recordingEngine(fixture, recorder: firstRecorder)
        try await makeSession(fixture, engine: first).synchronize()
        try await fixture.database.writer.write { database in
            database.trace { event in
                if event.expandedDescription.contains("INSERT INTO \"events\""), event.expandedDescription.contains("file_removed_from_crates") {
                    DispatchQueue.main.sync { self.setRunning(fixture, true) }
                }
            }
        }
        let group = DuplicateFinder.DuplicateGroup(groupKey: "restart", mode: .byteLevel, files: [keeper, target])
        let outcome = try await DuplicateResolver(operationEngine: first, database: fixture.database).resolve(group: group, keeperId: XCTUnwrap(keeper.id), batchId: "restart-cleanup")
        try await fixture.database.writer.write { database in database.trace(nil) }
        XCTAssertTrue(fixture.lifecycle.running, "The real mutation boundary must restart Serato")
        XCTAssertEqual(outcome.trashedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let pendingOwner = try await fixture.database.writer.read { database in try FileRecord.fetchOne(database, key: target.id) }
        XCTAssertNotNil(pendingOwner, "The target row is retained until every queued step finishes")

        let recorder = BoundaryRecorder()
        let relaunched = recordingEngine(fixture, recorder: recorder)
        setRunning(fixture, false)
        try await makeSession(fixture, engine: relaunched).synchronize()

        XCTAssertEqual(firstRecorder.trashed + recorder.trashed, [target.path])
        let targetRow = try await fixture.database.writer.read { database in try FileRecord.fetchOne(database, key: target.id) }
        XCTAssertNil(targetRow)
        XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).map { record in SeratoPath.normalized(record.path) }, [keeper.path])
        for (url, _) in crates {
            XCTAssertEqual(try readCratePaths(cratePath: url.path).map(SeratoPath.normalized), [keeper.path])
        }
        let intents = try await fixture.database.writer.read { database in try DuplicateCleanupStore.exists(in: database) }
        XCTAssertFalse(intents)
    }

    /// B then C are queued for one file. An interruption leaves C's row behind
    /// after B (or the coalesced B+C) reached V2; the next sync must still end
    /// at C without reporting our own edit as superseded. If nothing was sent
    /// and the user saved B in Serato themselves, that edit is theirs and wins.
    func testNewestQueuedEditWinsWhenAnEarlierEditLandedBeforeItsRowCleared() async throws {
        let cases: [(interruption: String, renameBetween: Bool, baselineKnown: Bool)] = [
            ("crash during one coalesced rewrite", false, true),
            ("crash before commit", true, true),
            ("crash before commit, then a failed retry", true, true),
            ("crash before commit, then a retry that failed before its fold", true, true),
            ("Serato relaunched", true, true),
            ("Serato relaunched, baseline unknown", true, false),
            ("Serato saved B itself", false, true),
            ("Serato saved B after a failed send", false, true),
        ]
        for testCase in cases {
            let label = testCase.interruption
            let seratoSavedB = label.hasPrefix("Serato saved B")
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("edited.wav", bytes: FinalRemovalIntegrationTests.wav())
            try save(fixture, paths: [file.path])
            try setV2(fixture, path: file.path, title: "Original A")
            if testCase.baselineKnown {
                try await makeSession(fixture, engine: fixture.engine).synchronize()
            }
            let fileID = try XCTUnwrap(file.id)
            setRunning(fixture, true)
            for title in ["Queued B", "Newest C"] {
                if title == "Newest C", testCase.renameBetween {
                    let renamed = fixture.directory.appendingPathComponent("renamed.wav").path
                    try await fixture.engine.apply(.renameFile(.init(fileId: fileID, newPath: renamed, previousPath: file.path, physicalMove: true)))
                }
                try await fixture.engine.apply(.setMetadata(.init(fileId: fileID, metadata: .init(title: title), isSeratoAuthoritative: false)))
                try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: title))))
            }
            if label == "Serato saved B after a failed send" {
                // A thrown write recorded its error, so it cannot have landed.
                setRunning(fixture, false)
                let failing = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                                              seratoMetadataBatchWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) })
                do { _ = try await failing.drainPendingSeratoUpdates(); XCTFail("\(label): the failing writer accepted the edits") }
                catch {}
                setRunning(fixture, true)
            }
            if seratoSavedB {
                try setV2(fixture, path: file.path, title: "Queued B")
            }
            setRunning(fixture, false)
            if seratoSavedB {
                let session = makeSession(fixture, engine: fixture.engine)
                try await session.synchronize()
                XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first?.title, "Queued B", label)
                guard case let .ready(summary) = session.state else { return XCTFail("\(label): sync did not reach ready") }
                XCTAssertEqual(summary.notAppliedWrites[.superseded], 1, label)
                continue
            }
            if label.hasPrefix("crash") {
                try await fixture.database.writer.write { database in
                    try database.execute(sql: """
                    CREATE TEMP TRIGGER crash_after_io BEFORE DELETE ON serato_write_queue
                    BEGIN SELECT RAISE(ABORT, 'process exited after external I/O'); END
                    """)
                }
                do { _ = try await fixture.engine.drainPendingSeratoUpdates(); XCTFail("\(label): the simulated crash did not interrupt the drain") }
                catch {}
                try await fixture.database.writer.write { database in
                    try database.execute(sql: "DROP TRIGGER crash_after_io")
                }
                if label.hasSuffix("failed retry") {
                    // The retry's error must not erase that the crashed attempt may have landed B.
                    let failing = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                                                  seratoMetadataBatchWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) })
                    do { _ = try await failing.drainPendingSeratoUpdates(); XCTFail("\(label): the failing writer accepted the edits") }
                    catch {}
                } else if label.hasSuffix("before its fold") {
                    // A failure before the retry folds the crashed attempt's mark must not erase it.
                    try await fixture.database.writer.write { database in
                        try database.execute(sql: """
                        CREATE TEMP TRIGGER fail_before_fold BEFORE UPDATE ON serato_write_queue WHEN NEW.attempts = OLD.attempts + 1
                        BEGIN SELECT RAISE(ABORT, 'the attempt failed before folding the earlier mark'); END
                        """)
                    }
                    let relaunched = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator)
                    _ = try? await relaunched.drainPendingSeratoUpdates()
                    let failedBeforeFold = try await fixture.database.writer.write { database in
                        try database.execute(sql: "DROP TRIGGER fail_before_fold")
                        return try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM serato_write_queue WHERE last_error LIKE '%before folding%'") ?? 0
                    }
                    XCTAssertGreaterThan(failedBeforeFold, 0, "\(label): the retry did not fail before its fold")
                }
            } else {
                let relaunched = LockedTestFlag()
                let engine = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                                             seratoMetadataBatchWriter: { databasePath, updates in
                                                 let result = try batchUpdateDatabaseRecords(databasePath: databasePath, updates: updates)
                                                 if relaunched.setOnce() {
                                                     DispatchQueue.main.sync { self.setRunning(fixture, true) }
                                                 }
                                                 return result
                                             })
                // An unknown baseline would make a strict sync drop B before
                // draining it, so that case drains directly.
                if testCase.baselineKnown {
                    do { try await makeSession(fixture, engine: engine).synchronize(); XCTFail("\(label): Serato relaunch did not stop the drain") }
                    catch SeratoMembershipSnapshotError.seratoRunning {}
                } else {
                    _ = try await engine.drainPendingSeratoUpdates()
                }
                setRunning(fixture, false)
            }
            let landed = testCase.renameBetween ? "Queued B" : "Newest C"
            XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first?.title, landed, label)

            let restarted = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator)
            let session = makeSession(fixture, engine: restarted)
            try await session.synchronize()

            XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first?.title, "Newest C", label)
            guard case let .ready(summary) = session.state else { return XCTFail("\(label): sync did not reach ready") }
            XCTAssertEqual(summary.notAppliedWrites.total, 0, label)
        }
    }

    func testResyncReportsChangesWhoseTrackSeratoNoLongerHolds() async throws {
        for (change, missing) in [("metadata", 1), ("rename", 1), ("crate-only rename", 0)] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("held.wav", bytes: FinalRemovalIntegrationTests.wav())
            try save(fixture, paths: [file.path])
            try await makeSession(fixture, engine: fixture.engine).synchronize()
            let fileID = try XCTUnwrap(file.id)
            if change == "metadata" {
                try await fixture.engine.apply(.setMetadata(.init(fileId: fileID, metadata: .init(title: "Committed"), isSeratoAuthoritative: false)), batchId: "replayed")
                try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: "Committed"))), batchId: "replayed")
            } else {
                let renamed = fixture.directory.appendingPathComponent("renamed.wav").path
                try await fixture.engine.apply(.renameFile(.init(fileId: fileID, newPath: renamed, previousPath: file.path, physicalMove: true)), batchId: "replayed")
            }
            try save(fixture, paths: [])
            if change == "crate-only rename" {
                _ = try saveCrates(fixture, paths: [file.path])
            }

            let outcome = try await fixture.engine.resyncSeratoForBatch("replayed")

            XCTAssertEqual(outcome.appliedCount, 1 - missing, "\(change): written only when some Serato file held the path")
            XCTAssertEqual(outcome.missingTargetCount, missing, change)
            XCTAssertEqual(outcome.queuedCount, 0, change)
        }
    }

    func testAnAttemptStoppedBeforeItsWriteDoesNotLookLandedAfterAFailedRetry() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("edited.wav", bytes: FinalRemovalIntegrationTests.wav())
        let sibling = try await fixture.add("sibling.wav", bytes: FinalRemovalIntegrationTests.wav(sample: 1))
        try save(fixture, paths: [file.path, sibling.path])
        try setV2(fixture, path: file.path, title: "Original A")
        try await makeSession(fixture, engine: fixture.engine).synchronize()
        setRunning(fixture, true)
        for (target, title) in [(file, "Queued B"), (file, "Newest C"), (sibling, "Sibling edit")] {
            let fileID = try XCTUnwrap(target.id)
            try await fixture.engine.apply(.setMetadata(.init(fileId: fileID, metadata: .init(title: title), isSeratoAuthoritative: false)))
            try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: title))))
        }
        setRunning(fixture, false)
        // The sibling's audio changes once the attempt starts, so the writer
        // boundary supersedes it and the pass retries before any write ran.
        let siblingChanged = LockedTestFlag()
        let siblingPath = sibling.path
        let changedSibling = FinalRemovalIntegrationTests.wav(sample: 9, durationSeconds: 2)
        try await fixture.database.writer.write { connection in
            connection.trace { event in
                guard event.expandedDescription.hasPrefix("UPDATE serato_write_queue SET"), event.expandedDescription.contains("attempts = attempts + 1"),
                      siblingChanged.setOnce() else { return }
                do { try changedSibling.write(to: URL(fileURLWithPath: siblingPath)) }
                catch { XCTFail("Could not change the sibling: \(error)") }
            }
        }
        let failing = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                                      seratoMetadataBatchWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        do { _ = try await failing.drainPendingSeratoUpdates(); XCTFail("The failing writer accepted the edits") }
        catch {}
        try await fixture.database.writer.write { connection in connection.trace(nil) }
        XCTAssertTrue(siblingChanged.setOnce() == false, "The sibling was never changed at the boundary")
        try setV2(fixture, path: file.path, title: "Queued B")

        let restarted = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator)
        try await makeSession(fixture, engine: restarted).synchronize()

        let record = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first { record in
            SeratoPath.normalized(record.path) == file.path
        }
        XCTAssertEqual(record?.title, "Queued B", "A queued edit that never reached Serato was taken for our own write")
    }

    func testARenameIntoAPathAnotherRenameVacatedLandsBothRecords() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let (one, two, three) = try await chainFixture(fixture)
        try await fixture.engine.applyBatch(chainRenames(one: one, two: two, three: three), batchId: "chain")

        XCTAssertEqual(try titlesByPath(fixture), [two.path: "One", three: "Two"])
        for crate in try fixture.locator.enumerateCrateFiles() {
            XCTAssertEqual(try readCratePaths(cratePath: crate.path).map(SeratoPath.normalized).sorted(), [three, two.path].sorted(), crate.lastPathComponent)
        }
    }

    func testAChainAcrossTwoSegmentsLandsBothRecords() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let (one, two, three) = try await chainFixture(fixture)
        var fillers: [TrackMutation] = []
        for index in 1 ..< SeratoWriteSegmenter.maximumEntriesPerSegment {
            let filler = try await fixture.add("filler-\(index).wav", bytes: FinalRemovalIntegrationTests.wav(sample: UInt8(index % 250)))
            let renamed = fixture.directory.appendingPathComponent("filler-\(index) renamed.wav").path
            try fillers.append(.renameFile(RenameFilePayload(fileId: XCTUnwrap(filler.id), newPath: renamed, previousPath: filler.path, physicalMove: true)))
        }
        setRunning(fixture, true)
        try await fixture.engine.applyBatch(fillers + chainRenames(one: one, two: two, three: three), batchId: "chain")
        setRunning(fixture, false)
        _ = try await fixture.engine.drainPendingSeratoUpdates()

        let titles = try titlesByPath(fixture)
        XCTAssertEqual(titles[two.path], "One")
        XCTAssertEqual(titles[three], "Two")
    }

    func testARenameIntoAPathWhoseDepartureWasSupersededDoesNotLand() async throws {
        for shape in ["swap", "chain"] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let (one, two, three) = try await chainFixture(fixture)
            let hop = fixture.directory.appendingPathComponent("hop.wav").path
            let renames: [TrackMutation] = try shape == "swap" ? [
                .renameFile(RenameFilePayload(fileId: XCTUnwrap(one.id), newPath: hop, previousPath: one.path, physicalMove: true)),
                .renameFile(RenameFilePayload(fileId: XCTUnwrap(two.id), newPath: one.path, previousPath: two.path, physicalMove: true)),
                .renameFile(RenameFilePayload(fileId: XCTUnwrap(one.id), newPath: two.path, previousPath: hop, physicalMove: true)),
            ] : chainRenames(one: one, two: two, three: three)
            setRunning(fixture, true)
            try await fixture.engine.applyBatch(renames, batchId: shape)
            setRunning(fixture, false)
            // The file that left its path changes, so its renames are superseded.
            let departed = shape == "swap" ? two.path : three
            try FinalRemovalIntegrationTests.wav(sample: 9, durationSeconds: 2).write(to: URL(fileURLWithPath: departed))
            _ = try await fixture.engine.drainPendingSeratoUpdates()

            let paths = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).map { record in SeratoPath.normalized(record.path) }
            XCTAssertEqual(paths.count, Set(paths).count, "\(shape): database V2 holds two records at one path")
            XCTAssertEqual(try titlesByPath(fixture), [one.path: "One", two.path: "Two"], shape)
            for crate in try fixture.locator.enumerateCrateFiles() {
                XCTAssertEqual(try readCratePaths(cratePath: crate.path).map(SeratoPath.normalized).sorted(), [one.path, two.path].sorted(), "\(shape): \(crate.lastPathComponent)")
            }
        }
    }

    func testARenameIntoAPathWhoseDepartureWasDroppedInAnEarlierPassDoesNotLand() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let (one, two, three) = try await chainFixture(fixture)
        let other = try await fixture.add("other.wav", bytes: FinalRemovalIntegrationTests.wav(sample: 3))
        try setV2(fixture, path: other.path, title: "Other")
        let chain = try chainRenames(one: one, two: two, three: three)
        setRunning(fixture, true)
        // The metadata edit between them puts the chain's two renames in separate segments.
        try await fixture.engine.applyBatch([
            chain[0],
            .commitMetadataToSerato(.init(fileId: XCTUnwrap(other.id), metadata: .init(title: "Other edit"))),
            chain[1],
        ], batchId: "chain")
        setRunning(fixture, false)
        try FinalRemovalIntegrationTests.wav(sample: 9, durationSeconds: 2).write(to: URL(fileURLWithPath: three))
        // Serato starts once the departure is dropped, so the pass stops before the arrival's segment.
        let lifecycle = fixture.lifecycle
        let watchdog = fixture.watchdog
        let launched = LockedTestFlag()
        try await fixture.database.writer.write { connection in
            connection.trace { event in
                guard event.expandedDescription.hasPrefix("INSERT INTO serato_write_dispositions"), launched.setOnce() else { return }
                lifecycle.running = true
                Task { @MainActor in watchdog.refresh() }
            }
        }
        _ = try await fixture.engine.drainPendingSeratoUpdates()
        try await fixture.database.writer.write { connection in connection.trace(nil) }
        XCTAssertFalse(launched.setOnce(), "The departure was never dropped")
        setRunning(fixture, false)
        _ = try await fixture.engine.drainPendingSeratoUpdates()

        let paths = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).map { record in SeratoPath.normalized(record.path) }
        XCTAssertEqual(paths.count, Set(paths).count, "Database V2 holds two records at one path")
        XCTAssertEqual(try titlesByPath(fixture)[two.path], "Two")
        XCTAssertEqual(try titlesByPath(fixture)[one.path], "One")
    }

    func testARenameIntoAPathADroppedRenameNeverReachedStillLands() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let (one, two, three) = try await chainFixture(fixture)
        let hop = fixture.directory.appendingPathComponent("hop.wav").path
        setRunning(fixture, true)
        try await fixture.engine.applyBatch([
            .renameFile(RenameFilePayload(fileId: XCTUnwrap(one.id), newPath: hop, previousPath: one.path, physicalMove: true)),
            .renameFile(RenameFilePayload(fileId: XCTUnwrap(one.id), newPath: three, previousPath: hop, physicalMove: true)),
            .renameFile(RenameFilePayload(fileId: XCTUnwrap(two.id), newPath: hop, previousPath: two.path, physicalMove: true)),
        ], batchId: "renames")
        setRunning(fixture, false)
        // The first file's renames are dropped, so its record never reached the hop path.
        try FinalRemovalIntegrationTests.wav(sample: 9, durationSeconds: 2).write(to: URL(fileURLWithPath: three))
        _ = try await fixture.engine.drainPendingSeratoUpdates()

        XCTAssertEqual(try titlesByPath(fixture), [one.path: "One", hop: "Two"])
    }

    func testAPartlyLandedChainRenameFinishesAfterItsArrivalIsSuperseded() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let (one, two, three) = try await chainFixture(fixture)
        setRunning(fixture, true)
        try await fixture.engine.applyBatch(chainRenames(one: one, two: two, three: three), batchId: "chain")
        setRunning(fixture, false)
        let subcrates = fixture.locator.subcratesDirectoryUrl.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: subcrates)
        do { _ = try await fixture.engine.drainPendingSeratoUpdates(); XCTFail("The read-only crate accepted the renames") }
        catch let OperationEngineError.seratoRewriteFailed(path, _) { XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent, "Subcrates", path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: subcrates)
        // The file that moved in becomes inaccessible, so its rename is dropped
        // before the next pass, and the departure no longer has a later arrival.
        let arrived = try await fixture.database.writer.read { database in try XCTUnwrap(FileRecord.fetchOne(database, key: one.id)) }
        try await fixture.engine.apply(.setFileLibraryState(.init(
            fileId: XCTUnwrap(arrived.id), expectedRevision: arrived.membershipRevision,
            state: .init(membership: .active, availability: .inaccessible, libraryID: arrived.seratoLibraryId, retiredAt: nil)
        )))
        _ = try await fixture.engine.drainPendingSeratoUpdates()

        let crate = fixture.locator.subcratesDirectoryUrl.appendingPathComponent("queued.crate").path
        XCTAssertEqual(try readCratePaths(cratePath: crate).map(SeratoPath.normalized).sorted(), [one.path, three].sorted(),
                       "The rename that landed in database V2 never reached the crate")
        XCTAssertEqual(try titlesByPath(fixture)[three], "Two")
    }

    func testRetryAfterASupersededSiblingDoesNotReapplyALandedChain() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let (one, two, three) = try await chainFixture(fixture)
        let sibling = try await fixture.add("sibling.wav", bytes: FinalRemovalIntegrationTests.wav(sample: 2))
        let renamedSibling = fixture.directory.appendingPathComponent("sibling renamed.wav").path
        setRunning(fixture, true)
        try await fixture.engine.applyBatch(chainRenames(one: one, two: two, three: three) + [
            .renameFile(RenameFilePayload(fileId: XCTUnwrap(sibling.id), newPath: renamedSibling, previousPath: sibling.path, physicalMove: true)),
        ], batchId: "chain")
        setRunning(fixture, false)
        // Once database V2 is rewritten, the sibling's audio changes, so its
        // rename is superseded at the crate write and the chain retries.
        let databasePath = fixture.locator.databaseV2Url.path
        let originalDatabase = try Data(contentsOf: URL(fileURLWithPath: databasePath))
        let siblingChanged = LockedTestFlag()
        let changedSibling = FinalRemovalIntegrationTests.wav(sample: 9, durationSeconds: 2)
        try await fixture.database.writer.write { connection in
            connection.trace { _ in
                guard (try? Data(contentsOf: URL(fileURLWithPath: databasePath))) != originalDatabase, siblingChanged.setOnce() else { return }
                do { try changedSibling.write(to: URL(fileURLWithPath: renamedSibling)) }
                catch { XCTFail("Could not change the sibling: \(error)") }
            }
        }
        let outcome = try await fixture.engine.drainPendingSeratoUpdates()
        try await fixture.database.writer.write { connection in connection.trace(nil) }
        XCTAssertFalse(siblingChanged.setOnce(), "The sibling was never changed after the database V2 write")

        XCTAssertEqual(outcome.appliedCount, 2)
        XCTAssertEqual(outcome.supersededCount, 1)
        XCTAssertEqual(outcome.missingTargetCount, 0)
        XCTAssertEqual(try titlesByPath(fixture), [two.path: "One", three: "Two"], "The retry applied the landed chain to database V2 a second time")
    }

    func testCleanupFinishesOnRestartOnlyWhenTrashActuallyRan() async throws {
        for trashSucceeded in [true, false] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let keeper = try await fixture.add("keeper.wav", bytes: FinalRemovalIntegrationTests.wav())
            let target = try await fixture.add("target.wav", bytes: FinalRemovalIntegrationTests.wav())
            try save(fixture, paths: [keeper.path, target.path])
            let recorder = BoundaryRecorder()
            let first = trashSucceeded ? recordingEngine(fixture, recorder: recorder)
                : OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                                  fileTrasher: { _ in throw CocoaError(.fileWriteNoPermission) })
            try await makeSession(fixture, engine: first).synchronize()
            if trashSucceeded {
                try await fixture.database.writer.write { database in
                    try database.execute(sql: """
                    CREATE TEMP TRIGGER fail_after_trash BEFORE DELETE ON duplicate_cleanup_intents
                    BEGIN SELECT RAISE(ABORT, 'the Trash transaction failed after moving audio to Trash'); END
                    """)
                }
            }
            let group = DuplicateFinder.DuplicateGroup(groupKey: "interrupted", mode: .byteLevel, files: [keeper, target])
            _ = try await DuplicateResolver(operationEngine: first, database: fixture.database).resolve(group: group, keeperId: XCTUnwrap(keeper.id), batchId: "interrupted-trash")
            if trashSucceeded {
                // A throw after the Trash, inside its transaction, does not prove the audio stayed put.
                try await fixture.database.writer.write { database in try database.execute(sql: "DROP TRIGGER fail_after_trash") }
                XCTAssertEqual(recorder.trashed, [target.path])
            } else {
                try FileManager.default.moveItem(atPath: target.path, toPath: fixture.directory.appendingPathComponent("moved-by-user.wav").path)
            }

            let restarted = recordingEngine(fixture, recorder: recorder)
            let session = makeSession(fixture, engine: restarted)
            try await session.synchronize()

            let targetRow = try await fixture.database.writer.read { database in try FileRecord.fetchOne(database, key: target.id) }
            guard case let .ready(summary) = session.state else { return XCTFail("Sync did not reach ready") }
            if trashSucceeded {
                XCTAssertNil(targetRow, "The cleanup must finish, not retire the target")
                XCTAssertEqual(recorder.trashed, [target.path])
                XCTAssertEqual(summary.notAppliedWrites.total, 0)
            } else {
                XCTAssertNotNil(targetRow, "A failed Trash attempt must not be taken as proof the audio was trashed")
                XCTAssertEqual(recorder.trashed, [])
                XCTAssertGreaterThan(summary.notAppliedWrites.total, 0)
            }
            let remaining = try await restarted.pendingSeratoWriteCount
            XCTAssertEqual(remaining, 0)
        }
    }

    func testDrainCoalescesQueuedV2MetadataIntoOneRewrite() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        var files: [FileRecord] = []
        for name in ["first.wav", "second.wav", "third.wav"] {
            try await files.append(fixture.add(name, bytes: FinalRemovalIntegrationTests.wav()))
        }
        try save(fixture, paths: files.map(\.path))
        try await makeSession(fixture, engine: fixture.engine).synchronize()
        setRunning(fixture, true)
        for file in files {
            try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Title \((file.path as NSString).lastPathComponent)"))))
            try await fixture.engine.apply(.writeFileTags(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Tag"))))
        }
        try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(files[0].id), metadata: .init(artist: "Second edit artist"))))
        setRunning(fixture, false)

        let recorder = BoundaryRecorder()
        let relaunched = recordingEngine(fixture, recorder: recorder)
        try await makeSession(fixture, engine: relaunched).synchronize()

        XCTAssertEqual(recorder.libraryRewrites, 1)
        XCTAssertEqual(recorder.tagWrites, 3)
        let records = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path)
        let first = try XCTUnwrap(records.first { record in SeratoPath.normalized(record.path) == files[0].path })
        XCTAssertEqual(first.title, "Title first.wav")
        XCTAssertEqual(first.artist, "Second edit artist")
    }

    func testALargeQueuedBacklogIsWrittenInBoundedRewrites() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        var files: [FileRecord] = []
        for index in 0 ... SeratoWriteSegmenter.maximumEntriesPerSegment {
            try await files.append(fixture.add("track-\(index).wav", bytes: FinalRemovalIntegrationTests.wav(sample: UInt8(index % 250))))
        }
        try save(fixture, paths: files.map(\.path))
        try await makeSession(fixture, engine: fixture.engine).synchronize()
        setRunning(fixture, true)
        for file in files {
            try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Edited \(file.id ?? 0)"))))
        }
        setRunning(fixture, false)

        let rewriteSizes = LockedRewriteSizes()
        let relaunched = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                                         seratoMetadataBatchWriter: { databasePath, updates in
                                             rewriteSizes.append(updates.count)
                                             return try batchUpdateDatabaseRecords(databasePath: databasePath, updates: updates)
                                         })
        _ = try await relaunched.drainPendingSeratoUpdates()

        XCTAssertGreaterThan(rewriteSizes.values.count, 1, "One writer transaction held every queued row")
        XCTAssertTrue(rewriteSizes.values.allSatisfy { size in size <= SeratoWriteSegmenter.maximumEntriesPerSegment })
        let titles = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).reduce(into: [String: String]()) { titles, record in
            titles[SeratoPath.normalized(record.path)] = record.title
        }
        for file in files {
            XCTAssertEqual(titles[file.path], "Edited \(file.id ?? 0)")
        }
        let remaining = try await relaunched.pendingSeratoWriteCount
        XCTAssertEqual(remaining, 0)

        // A failing store fails the pass once; later segments for it stay queued for Retry Sync.
        setRunning(fixture, true)
        for file in files {
            try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Retitled \(file.id ?? 0)"))))
        }
        setRunning(fixture, false)
        let failedRewrites = LockedRewriteSizes()
        let failing = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                                      seratoMetadataBatchWriter: { _, updates in
                                          failedRewrites.append(updates.count)
                                          throw CocoaError(.fileWriteNoPermission)
                                      })
        do {
            _ = try await failing.drainPendingSeratoUpdates()
            XCTFail("The failing store accepted the edits")
        } catch {
            let message = error.localizedDescription
            let failure = CocoaError(.fileWriteNoPermission).localizedDescription
            XCTAssertEqual(message.components(separatedBy: failure).count - 1, 1, "The same store failure was reported per segment: \(message)")
        }
        XCTAssertEqual(failedRewrites.values.count, 1, "The pass kept retrying a store that already failed")
        let retained = try await failing.pendingSeratoWriteCount
        XCTAssertEqual(retained, files.count)
    }

    func testImmediateBatchAppliesMetadataAfterItsFilesRename() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("before.wav", bytes: FinalRemovalIntegrationTests.wav())
        try save(fixture, paths: [file.path])
        try await makeSession(fixture, engine: fixture.engine).synchronize()
        let fileID = try XCTUnwrap(file.id)
        let renamed = fixture.directory.appendingPathComponent("after.wav").path
        _ = try await fixture.engine.applyBatch([
            .renameFile(.init(fileId: fileID, newPath: renamed, previousPath: file.path, physicalMove: true)),
            .commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: "Title after rename"))),
        ], batchId: "rename-then-title")

        let record = try XCTUnwrap(readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first)
        XCTAssertEqual(SeratoPath.normalized(record.path), renamed)
        XCTAssertEqual(record.title, "Title after rename")
    }

    func testSeratoEditAtOldPathOfQueuedRenameIsPreserved() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("old.wav", bytes: FinalRemovalIntegrationTests.wav())
        try save(fixture, paths: [file.path])
        try setV2(fixture, path: file.path, title: "Original A")
        try await makeSession(fixture, engine: fixture.engine).synchronize()
        let fileID = try XCTUnwrap(file.id)
        setRunning(fixture, true)
        let renamed = fixture.directory.appendingPathComponent("new.wav").path
        try await fixture.engine.apply(.renameFile(.init(fileId: fileID, newPath: renamed, previousPath: file.path, physicalMove: true)))
        try await fixture.engine.apply(.setMetadata(.init(fileId: fileID, metadata: .init(title: "Local B"), isSeratoAuthoritative: false)))
        try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: "Local B"))))
        try setV2(fixture, path: file.path, title: "Serato C")
        setRunning(fixture, false)

        let session = makeSession(fixture, engine: fixture.engine)
        try await session.synchronize()

        let record = try XCTUnwrap(readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first)
        XCTAssertEqual(SeratoPath.normalized(record.path), renamed)
        XCTAssertEqual(record.title, "Serato C")
        let current = try await fixture.row(file)
        XCTAssertEqual(current.title, "Serato C")
    }

    func testQueuedRenameOntoAPathSeratoAlreadyHoldsIsBlockedVisibly() async throws {
        let readiness = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: readiness)
        defer { fixture.cleanup() }
        let file = try await fixture.add("old.wav", bytes: FinalRemovalIntegrationTests.wav())
        try save(fixture, paths: [file.path])
        try await makeSession(fixture, engine: fixture.engine, readiness: readiness).synchronize()
        setRunning(fixture, true)
        let renamed = fixture.directory.appendingPathComponent("new.wav").path
        try await fixture.engine.apply(.renameFile(.init(fileId: XCTUnwrap(file.id), newPath: renamed, previousPath: file.path, physicalMove: true)))
        try save(fixture, paths: [file.path, renamed])
        let library = try Data(contentsOf: fixture.locator.databaseV2Url)
        setRunning(fixture, false)

        let session = makeSession(fixture, engine: fixture.engine, readiness: readiness)
        try await session.synchronize()

        XCTAssertEqual(session.conflicts.map(\.id), [SeratoPath.normalized(renamed)])
        XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), library, "Neither saved record may be rewritten while the rename is blocked")
        let queued = try await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(queued, 1)
    }

    /// #117: Finder moves the file twice while its tags are queued; the drain
    /// must reach the file at its final path and carry every Serato surface
    /// through both renames, old → middle → new.
    func testQueuedTagWriteFollowsChainedFinderRenamesToEveryLibrarySurface() async throws {
        for source in ["fresh match", "hygiene fill"] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("old.wav", bytes: FinalRemovalIntegrationTests.wav())
            let fileID = try XCTUnwrap(file.id)
            try save(fixture, paths: [file.path])
            let crates = try saveCrates(fixture, paths: [file.path])
            try await makeSession(fixture, engine: fixture.engine).synchronize()
            let title = source == "fresh match" ? "Matched title" : "Filled title"
            if source == "fresh match" {
                let fingerprint = try await makeMatchable(fixture, fileID: fileID)
                setRunning(fixture, true)
                try await fixture.engine.apply(.applyMusicBrainzMatch(matchPayload(file, fingerprint: fingerprint, title: title)), batchId: "queued-match")
            } else {
                setRunning(fixture, true)
                let current = try await fixture.row(file)
                try await LibraryHygieneRunner(operationEngine: fixture.engine)
                    .applyMissingFieldFill(field: .title, value: title, fileIds: [fileID], files: [current], batchId: "queued-hygiene")
            }
            let queued = try await fixture.engine.pendingSeratoWriteCount
            XCTAssertGreaterThan(queued, 0, source)
            let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
            var currentPath = file.path
            for name in ["middle.wav", "new.wav"] {
                let destination = fixture.directory.appendingPathComponent(name).path
                try FileManager.default.moveItem(atPath: currentPath, toPath: destination)
                try await coordinator.handleObservations([.init(path: destination, isFile: true, wasRenamed: true)])
                currentPath = destination
            }
            setRunning(fixture, false)

            let recorder = BoundaryRecorder()
            let relaunched = recordingEngine(fixture, recorder: recorder)
            let session = makeSession(fixture, engine: relaunched)
            try await session.synchronize()

            XCTAssertEqual(try readAudioTags(filePath: currentPath).title, title, source)
            XCTAssertEqual(recorder.tagWrites, 1, source)
            let records = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path)
            XCTAssertEqual(records.map { record in SeratoPath.normalized(record.path) }, [currentPath], source)
            XCTAssertEqual(records.first?.title, title, source)
            for (url, _) in crates {
                XCTAssertEqual(try readCratePaths(cratePath: url.path).map(SeratoPath.normalized), [currentPath], source)
            }
            let remaining = try await relaunched.pendingSeratoWriteCount
            XCTAssertEqual(remaining, 0, source)
            guard case let .ready(summary) = session.state else { return XCTFail("\(source): sync did not reach ready: \(session.state)") }
            XCTAssertEqual(summary.notAppliedWrites.total, 0, source)
        }
    }

    /// #117: removing a row leaves its queued work naming that row. Indexing
    /// the same audio again creates a new row, which must not inherit it.
    /// Undo refuses to remove an indexed row once its membership changed, so
    /// the row is removed with `removeFile` directly, as duplicate cleanup does.
    func testReindexedFileCannotInheritItsRemovedRowsQueuedWork() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let independent = try await fixture.add("independent.wav", bytes: FinalRemovalIntegrationTests.wav())
        let path = fixture.directory.appendingPathComponent("reindexed.wav").path
        let audio = FinalRemovalIntegrationTests.wav(sample: 3)
        try audio.write(to: URL(fileURLWithPath: path))
        // Both rows reach the same membership revision, so only the file ID
        // tells the removed row's queued work from the new row's.
        let owner = try await fixture.reader.read().libraryID
        let removedID = try await indexAndActivate(fixture, path: path, owner: owner)
        try save(fixture, paths: [independent.path, path])
        try await makeSession(fixture, engine: fixture.engine).synchronize()
        setRunning(fixture, true)
        try await fixture.engine.apply(.writeFileTags(.init(fileId: removedID, metadata: .init(title: "Never inherited"))))
        try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(independent.id), metadata: .init(title: "Independent title"))))
        try await fixture.engine.apply(.removeFile(.init(fileId: removedID)))
        _ = try await indexAndActivate(fixture, path: path, owner: owner)
        setRunning(fixture, false)

        let recorder = BoundaryRecorder()
        let relaunched = recordingEngine(fixture, recorder: recorder)
        let session = makeSession(fixture, engine: relaunched)
        try await session.synchronize()

        XCTAssertEqual(recorder.tagWrites, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), audio)
        let record = try XCTUnwrap(readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first { record in
            SeratoPath.normalized(record.path) == independent.path
        })
        XCTAssertEqual(record.title, "Independent title")
        let remaining = try await relaunched.pendingSeratoWriteCount
        XCTAssertEqual(remaining, 0)
        guard case let .ready(summary) = session.state else { return XCTFail("Sync did not reach ready: \(session.state)") }
        XCTAssertEqual(summary.notAppliedWrites, SeratoWriteDispositionCounts(counts: [.superseded: 1]))
    }

    /// #117: a rename lands while a drain, or the immediate pass of another
    /// edit, still owes an earlier write to the same file. The rename waits
    /// for that write instead of overtaking it, and must still reach Serato
    /// once the earlier pass finishes.
    func testRenameDuringAnotherPassOnTheSameFileStillReachesSerato() async throws {
        for draining in [false, true] {
            let label = draining ? "during a drain" : "during an immediate pass"
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("before.wav", bytes: FinalRemovalIntegrationTests.wav())
            let fileID = try XCTUnwrap(file.id)
            try save(fixture, paths: [file.path])
            let crates = try saveCrates(fixture, paths: [file.path])
            try await makeSession(fixture, engine: fixture.engine).synchronize()
            let renamed = fixture.directory.appendingPathComponent("after.wav").path
            let concurrentRename = ConcurrentRename()
            let engine = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                                         seratoMetadataBatchWriter: { databasePath, updates in
                                             let result = try batchUpdateDatabaseRecords(databasePath: databasePath, updates: updates)
                                             concurrentRename.startOnce()
                                             return result
                                         })
            concurrentRename.prepare {
                try await engine.apply(.renameFile(.init(fileId: fileID, newPath: renamed, previousPath: file.path, physicalMove: true)), batchId: "concurrent-rename")
            }
            setRunning(fixture, draining)
            let current = try await fixture.row(file)
            try await LibraryHygieneRunner(operationEngine: engine)
                .applyMissingFieldFill(field: .title, value: "Filled title", fileIds: [fileID], files: [current], batchId: "hygiene-pass")
            if draining {
                setRunning(fixture, false)
                _ = try await engine.drainPendingSeratoUpdates()
            }
            try await concurrentRename.finished()

            XCTAssertEqual(try readAudioTags(filePath: renamed).title, "Filled title", label)
            let records = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path)
            XCTAssertEqual(records.map { record in SeratoPath.normalized(record.path) }, [renamed], label)
            XCTAssertEqual(records.first?.title, "Filled title", label)
            for (url, _) in crates {
                XCTAssertEqual(try readCratePaths(cratePath: url.path).map(SeratoPath.normalized), [renamed], label)
            }
            let remaining = try await engine.pendingSeratoWriteCount
            XCTAssertEqual(remaining, 0, "\(label): the rename was left queued with Serato closed")
        }
    }

    func testSeratoSessionEditsWinAcrossRestartAndFastStartup() async throws {
        for savedDuringSession in ["Original A", "Serato C", ""] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("edited.wav", bytes: FinalRemovalIntegrationTests.wav())
            let other = try await fixture.add("other.wav", bytes: FinalRemovalIntegrationTests.wav())
            try save(fixture, paths: [file.path, other.path])
            try setV2(fixture, path: file.path, title: "Original A")
            let store = SyncCheckpointStore(database: fixture.database)
            try await makeSession(fixture, engine: fixture.engine, store: store).synchronize()
            let launched = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator)
            let fastSession = makeSession(fixture, engine: launched, store: store)
            try await fastSession.synchronize()
            try await launched.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(other.id), metadata: .init(title: "Own immediate write"))))
            setRunning(fixture, true)
            let fileID = try XCTUnwrap(file.id)
            try await launched.apply(.setMetadata(.init(fileId: fileID, metadata: .init(title: "Local B"), isSeratoAuthoritative: false)))
            try await launched.apply(.commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: "Local B"))))
            try await launched.apply(.writeFileTags(.init(fileId: fileID, metadata: .init(title: "Tag B"))))
            try setV2(fixture, path: file.path, title: savedDuringSession)
            setRunning(fixture, false)

            let relaunched = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator)
            try await makeSession(fixture, engine: relaunched, store: store).synchronize()

            let records = try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path)
            let record = try XCTUnwrap(records.first { record in SeratoPath.normalized(record.path) == file.path })
            let expected = savedDuringSession == "Original A" ? "Local B" : savedDuringSession
            XCTAssertEqual(record.title ?? "", expected, "Saved \(savedDuringSession.isEmpty ? "cleared" : savedDuringSession)")
            XCTAssertEqual(try readAudioTags(filePath: file.path).title, "Tag B")
        }
    }

    /// No sync has observed Serato yet, so only the edit's journal records what
    /// Serato held before it (#115: A, queued B, unchanged A must apply B).
    func testQueuedEditUsesItsJournaledPreviousValueWhenNoBaselineWasObserved() async throws {
        for savedDuringSession in ["Original A", "Serato C"] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("edited.wav", bytes: FinalRemovalIntegrationTests.wav())
            try save(fixture, paths: [file.path])
            try setV2(fixture, path: file.path, title: "Original A")
            let fileID = try XCTUnwrap(file.id)
            setRunning(fixture, true)
            try await fixture.engine.apply(.setMetadata(.init(fileId: fileID, metadata: .init(title: "Local B"), isSeratoAuthoritative: false)))
            try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: "Local B"),
                                                                         previousMetadata: .init(title: "Original A"))))
            try setV2(fixture, path: file.path, title: savedDuringSession)
            setRunning(fixture, false)

            let session = makeSession(fixture, engine: fixture.engine)
            try await session.synchronize()

            let unchanged = savedDuringSession == "Original A"
            XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first?.title,
                           unchanged ? "Local B" : savedDuringSession, savedDuringSession)
            guard case let .ready(summary) = session.state else { return XCTFail("\(savedDuringSession): sync did not reach ready") }
            XCTAssertEqual(summary.notAppliedWrites, SeratoWriteDispositionCounts(counts: unchanged ? [:] : [.superseded: 1]), savedDuringSession)
        }
    }

    func testReplacedTargetIsDroppedVisiblyAcrossRestart() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let replaced = try await fixture.add("replaced.wav", bytes: FinalRemovalIntegrationTests.wav())
        let independent = try await fixture.add("independent.wav", bytes: FinalRemovalIntegrationTests.wav())
        try save(fixture, paths: [replaced.path, independent.path])
        try await makeSession(fixture, engine: fixture.engine).synchronize()
        setRunning(fixture, true)
        try await fixture.engine.apply(.writeFileTags(.init(fileId: XCTUnwrap(replaced.id), metadata: .init(title: "Never written"))))
        try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(independent.id), metadata: .init(title: "Independent title"))))
        let replacement = FinalRemovalIntegrationTests.wav(sample: 9, durationSeconds: 2)
        try replacement.write(to: URL(fileURLWithPath: replaced.path))
        setRunning(fixture, false)

        let recorder = BoundaryRecorder()
        let relaunched = recordingEngine(fixture, recorder: recorder)
        let session = makeSession(fixture, engine: relaunched)
        try await session.synchronize()

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: replaced.path)), replacement)
        XCTAssertEqual(recorder.tagWrites, 0)
        let record = try XCTUnwrap(readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first { record in
            SeratoPath.normalized(record.path) == independent.path
        })
        XCTAssertEqual(record.title, "Independent title")
        guard case let .ready(summary) = session.state else { return XCTFail("Sync did not reach ready: \(session.state)") }
        XCTAssertEqual(summary.notAppliedWrites.total, 1)
    }

    func testHistoryResyncWhileQueuedDoesNotDoubleApply() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("resynced.wav", bytes: FinalRemovalIntegrationTests.wav())
        try save(fixture, paths: [file.path])
        let recorder = BoundaryRecorder()
        let engine = recordingEngine(fixture, recorder: recorder)
        let session = makeSession(fixture, engine: engine)
        try await session.synchronize()
        let fileID = try XCTUnwrap(file.id)
        let fingerprint = try await makeMatchable(fixture, fileID: fileID)
        setRunning(fixture, true)
        try await engine.apply(.applyMusicBrainzMatch(matchPayload(file, fingerprint: fingerprint, title: "Matched once")), batchId: "resynced-match")
        let queued = try await engine.pendingSeratoWriteCount
        _ = try await engine.resyncSeratoForBatch("resynced-match")
        let afterResync = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(afterResync, queued)
        setRunning(fixture, false)
        try await session.synchronize()
        XCTAssertEqual(recorder.tagWrites, 1)
        XCTAssertEqual(recorder.libraryRewrites, 1)

        let pathOnly = try await fixture.add("failed.wav", bytes: FinalRemovalIntegrationTests.wav())
        try save(fixture, paths: [file.path, pathOnly.path])
        try await session.synchronize()
        let validLibrary = try Data(contentsOf: fixture.locator.databaseV2Url)
        try Data("corrupt V2".utf8).write(to: fixture.locator.databaseV2Url)
        do {
            try await engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(pathOnly.id), metadata: .init(title: "Retried title"))), batchId: "failed-write")
            XCTFail("A corrupt database V2 accepted the write")
        } catch {}
        let retained = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(retained, 1)
        try validLibrary.write(to: fixture.locator.databaseV2Url)
        let rewritesBeforeRetry = recorder.libraryRewrites
        let retry = try await engine.resyncSeratoForBatch("failed-write")
        XCTAssertEqual(retry.appliedCount, 1)
        XCTAssertEqual(recorder.libraryRewrites, rewritesBeforeRetry + 1)
        let remaining = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(remaining, 0)
    }

    func testLegacyEffectFenceRecoversOnStartup() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("legacy.wav", bytes: FinalRemovalIntegrationTests.wav())
        try save(fixture, paths: [file.path])
        let store = SyncCheckpointStore(database: fixture.database)
        try await makeSession(fixture, engine: fixture.engine, store: store).synchronize()
        setRunning(fixture, true)
        let eventID = try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Pre-upgrade title"))))
        try await fixture.database.writer.write { database in
            try database.execute(sql: "DELETE FROM serato_write_queue")
            try SyncCheckpointStore.beginEffect(batchID: SyncCheckpointStore.legacyEventFencePrefix + String(XCTUnwrap(eventID)), in: database)
        }
        setRunning(fixture, false)

        let relaunched = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator)
        let session = makeSession(fixture, engine: relaunched, store: store)
        try await session.synchronize()

        XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first?.title, "Pre-upgrade title")
        let fences = try await store.pendingEffects()
        XCTAssertEqual(fences, [])
        let header = try await store.loadHeader()
        XCTAssertNotNil(header)
    }

    /// An outcome written by a newer build must not keep readiness closed
    /// after a downgrade; it is reported as not applied instead.
    func testUnrecognizedRecordedOutcomeIsReportedWithoutBlockingSync() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("downgraded.wav", bytes: FinalRemovalIntegrationTests.wav())
        try save(fixture, paths: [file.path])
        try await fixture.database.writer.write { database in
            try database.execute(sql: """
            INSERT INTO serato_write_dispositions (event_id, batch_id, kind, disposition, detail, created_at, reported)
            VALUES (1, 'newer-build', 'metadataUpdate', 'deferredByNewerBuild', NULL, 0, 0)
            """)
        }

        let session = makeSession(fixture, engine: fixture.engine)
        // The sync's own error is the failure under test, so the state is asserted.
        try? await session.synchronize()

        guard case let .ready(summary) = session.state else { return XCTFail("Sync did not reach ready: \(session.state)") }
        XCTAssertEqual(summary.notAppliedWrites.total, 1)
    }

    /// Two tracks in database V2 and every crate, plus the free path the
    /// second one moves to before the first takes its place.
    private func chainFixture(_ fixture: SeratoRemovalFixture) async throws -> (FileRecord, FileRecord, String) {
        let one = try await fixture.add("one.wav", bytes: FinalRemovalIntegrationTests.wav())
        let two = try await fixture.add("two.wav", bytes: FinalRemovalIntegrationTests.wav(sample: 1))
        try save(fixture, paths: [one.path, two.path])
        try setV2(fixture, path: one.path, title: "One")
        try setV2(fixture, path: two.path, title: "Two")
        _ = try saveCrates(fixture, paths: [one.path, two.path])
        try await makeSession(fixture, engine: fixture.engine).synchronize()
        return (one, two, fixture.directory.appendingPathComponent("three.wav").path)
    }

    private func chainRenames(one: FileRecord, two: FileRecord, three: String) throws -> [TrackMutation] {
        try [
            .renameFile(RenameFilePayload(fileId: XCTUnwrap(two.id), newPath: three, previousPath: two.path, physicalMove: true)),
            .renameFile(RenameFilePayload(fileId: XCTUnwrap(one.id), newPath: two.path, previousPath: one.path, physicalMove: true)),
        ]
    }

    private func titlesByPath(_ fixture: SeratoRemovalFixture) throws -> [String: String] {
        try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).reduce(into: [:]) { titles, record in
            titles[SeratoPath.normalized(record.path)] = record.title
        }
    }

    private func setRunning(_ fixture: SeratoRemovalFixture, _ running: Bool) {
        fixture.lifecycle.running = running
        fixture.watchdog.refresh()
    }

    private func recordingEngine(_ fixture: SeratoRemovalFixture, recorder: BoundaryRecorder) -> OperationEngine {
        OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                        fileTagWriter: { path, update in
                            try writeAudioTags(filePath: path, update: update)
                            recorder.recordTagWrite()
                        },
                        seratoMetadataBatchWriter: { databasePath, updates in
                            let result = try batchUpdateDatabaseRecords(databasePath: databasePath, updates: updates)
                            recorder.recordLibraryRewrite()
                            return result
                        },
                        fileTrasher: { path in
                            try FileManager.default.moveItem(atPath: path, toPath: fixture.directory.appendingPathComponent("trashed-" + (path as NSString).lastPathComponent).path)
                            recorder.recordTrash(path)
                        })
    }

    private func makeSession(_ fixture: SeratoRemovalFixture, engine: OperationEngine, store: SyncCheckpointStore? = nil,
                             readiness: LibrarySyncReadiness = LibrarySyncReadiness()) -> SeratoLibrarySyncSession
    {
        SeratoLibrarySyncSession(reader: fixture.reader, reconciler: SeratoMembershipReconciler(database: fixture.database, operationEngine: engine, reader: fixture.reader),
                                 scanner: LibraryScanner(operationEngine: engine, database: fixture.database, seratoLocator: fixture.locator),
                                 operationEngine: engine, watchdog: fixture.watchdog, readiness: readiness, checkpointStore: store)
    }

    private func makeMatchable(_ fixture: SeratoRemovalFixture, fileID: Int64) async throws -> Data {
        let fingerprint = Data([11, 22, 33, 44])
        try await fixture.database.writer.write { database in
            var track = TrackRecord(fingerprintHash: fingerprint, artist: "Before match")
            try track.insert(database)
            var current = try XCTUnwrap(FileRecord.fetchOne(database, key: fileID))
            current.trackId = track.id
            current.chromaprintFingerprint = Data([5, 6, 7, 8])
            current.fingerprintStatus = .done
            current.fingerprintedSize = current.fileSize
            current.fingerprintedMtime = current.mtime
            try current.update(database)
        }
        return fingerprint
    }

    private func matchPayload(_ file: FileRecord, fingerprint: Data, title: String) throws -> ApplyMusicBrainzMatchPayload {
        try ApplyMusicBrainzMatchPayload(fileID: XCTUnwrap(file.id), acoustID: "acoustid", recordingMBID: "recording", releaseMBID: nil, artistMBID: nil, isrc: nil,
                                         fingerprintHash: fingerprint, expectedFileSize: file.fileSize, expectedMtime: file.mtime,
                                         artist: "Matched artist", title: title, album: nil, year: nil)
    }

    private func indexAndActivate(_ fixture: SeratoRemovalFixture, path: String, owner: String) async throws -> Int64 {
        let identity = try FileMetadataCollector.collectVerified(at: path)
        try await fixture.engine.apply(.indexNewFile(.init(path: path, volumeUuid: identity.volumeUuid, inode: identity.inode, fileSize: identity.fileSize,
                                                           mtime: identity.mtime, lightweightHash: identity.lightweightHash)))
        let indexed = try await fixture.database.writer.read { database in try XCTUnwrap(FileRecord.filter(Column("path") == path).fetchOne(database)) }
        let fileID = try XCTUnwrap(indexed.id)
        try await fixture.engine.apply(.setFileLibraryState(.init(fileId: fileID, expectedRevision: indexed.membershipRevision,
                                                                  state: FileLibraryState(membership: .active, availability: .available, libraryID: owner, retiredAt: nil))))
        return fileID
    }

    private func save(_ fixture: SeratoRemovalFixture, paths: [String]) throws {
        try fixture.save(paths: paths.map(SeratoLibraryLocator.seratoRelativePath))
    }

    private func setV2(_ fixture: SeratoRemovalFixture, path: String, title: String) throws {
        _ = try batchUpdateDatabaseRecords(databasePath: fixture.locator.databaseV2Url.path,
                                           updates: [.init(trackPath: SeratoLibraryLocator.seratoRelativePath(fromAbsolute: path), update: .init(artist: nil, title: title, album: nil, genre: nil, bpm: nil, key: nil, comment: nil, length: nil, label: nil))])
    }

    private func saveCrates(_ fixture: SeratoRemovalFixture, paths: [String]) throws -> [(URL, Data)] {
        let bytes = paths.reduce(SeratoTestEncoding.record("vrsn", Data("1.0/Serato ScratchLive Crate".data(using: .utf16BigEndian)!))) { bytes, path in
            bytes + SeratoTestEncoding.record("otrk", SeratoTestEncoding.record("ptrk", SeratoLibraryLocator.seratoRelativePath(fromAbsolute: path).data(using: .utf16BigEndian)!))
        }
        return try [fixture.locator.subcratesDirectoryUrl.appendingPathComponent("queued.crate"), fixture.locator.smartCratesDirectoryUrl.appendingPathComponent("queued.scrate")].map { url in
            try bytes.write(to: url)
            return (url, bytes)
        }
    }
}

private final class LockedTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func setOnce() -> Bool {
        lock.withLock {
            guard !stored else { return false }
            stored = true
            return true
        }
    }
}

/// Starts an operation from inside a writer boundary, where it cannot run
/// until the boundary's transaction commits, and lets the test await it.
private final class ConcurrentRename: @unchecked Sendable {
    private struct NeverStarted: Error {}
    private let lock = NSLock()
    private var operation: (@Sendable () async throws -> Void)?
    private var task: Task<Void, Error>?

    func prepare(_ operation: @escaping @Sendable () async throws -> Void) {
        lock.withLock { self.operation = operation }
    }

    func startOnce() {
        lock.withLock {
            guard task == nil, let operation else { return }
            task = Task { try await operation() }
        }
    }

    func finished() async throws {
        guard let task = lock.withLock({ task }) else { throw NeverStarted() }
        try await task.value
    }
}

/// Counts real I/O at the engine's injectable boundaries.
private final class BoundaryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var tagWriteCount = 0
    private var libraryRewriteCount = 0
    private var trashedPaths: [String] = []

    var tagWrites: Int {
        lock.withLock { tagWriteCount }
    }

    var libraryRewrites: Int {
        lock.withLock { libraryRewriteCount }
    }

    var trashed: [String] {
        lock.withLock { trashedPaths }
    }

    func recordTagWrite() {
        lock.withLock { tagWriteCount += 1 }
    }

    func recordLibraryRewrite() {
        lock.withLock { libraryRewriteCount += 1 }
    }

    func recordTrash(_ path: String) {
        lock.withLock { trashedPaths.append(path) }
    }
}

private final class LockedRewriteSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []

    var values: [Int] {
        lock.withLock { stored }
    }

    func append(_ size: Int) {
        lock.withLock { stored.append(size) }
    }
}
