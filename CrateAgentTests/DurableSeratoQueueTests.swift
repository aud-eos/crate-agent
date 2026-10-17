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

    func testNewestQueuedEditWinsWhenAnEarlierEditLandedBeforeItsRowCleared() async throws {
        for interruption in ["crash before commit", "Serato relaunched"] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("edited.wav", bytes: FinalRemovalIntegrationTests.wav())
            try save(fixture, paths: [file.path])
            try setV2(fixture, path: file.path, title: "Original A")
            try await makeSession(fixture, engine: fixture.engine).synchronize()
            let fileID = try XCTUnwrap(file.id)
            setRunning(fixture, true)
            for title in ["Queued B", "Newest C"] {
                try await fixture.engine.apply(.setMetadata(.init(fileId: fileID, metadata: .init(title: title), isSeratoAuthoritative: false)))
                try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: title))))
            }
            setRunning(fixture, false)
            if interruption == "crash before commit" {
                try await fixture.database.writer.write { database in
                    try database.execute(sql: """
                    CREATE TEMP TRIGGER crash_after_io BEFORE DELETE ON serato_write_queue
                    BEGIN SELECT RAISE(ABORT, 'process exited after external I/O'); END
                    """)
                }
                do { _ = try await fixture.engine.drainPendingSeratoUpdates(); XCTFail("The simulated crash did not interrupt the drain") }
                catch {}
                try await fixture.database.writer.write { database in try database.execute(sql: "DROP TRIGGER crash_after_io") }
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
                do { try await makeSession(fixture, engine: engine).synchronize(); XCTFail("Serato relaunch did not stop the drain") }
                catch SeratoMembershipSnapshotError.seratoRunning {}
                setRunning(fixture, false)
            }
            XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first?.title, "Queued B", interruption)

            let restarted = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator)
            let session = makeSession(fixture, engine: restarted)
            try await session.synchronize()

            XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first?.title, "Newest C", interruption)
            guard case let .ready(summary) = session.state else { return XCTFail("\(interruption): sync did not reach ready") }
            XCTAssertEqual(summary.supersededWrites, 0, interruption)
        }
    }

    func testCleanupInterruptedAfterTrashFinishesOnRestart() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let keeper = try await fixture.add("keeper.wav", bytes: FinalRemovalIntegrationTests.wav())
        let target = try await fixture.add("target.wav", bytes: FinalRemovalIntegrationTests.wav())
        try save(fixture, paths: [keeper.path, target.path])
        let recorder = BoundaryRecorder()
        let first = recordingEngine(fixture, recorder: recorder)
        try await makeSession(fixture, engine: first).synchronize()
        try await fixture.database.writer.write { database in
            try database.execute(sql: """
            CREATE TEMP TRIGGER crash_after_trash BEFORE DELETE ON serato_write_queue WHEN OLD.kind = 'trashFile'
            BEGIN SELECT RAISE(ABORT, 'process exited after moving audio to Trash'); END
            """)
        }
        let group = DuplicateFinder.DuplicateGroup(groupKey: "interrupted", mode: .byteLevel, files: [keeper, target])
        _ = try await DuplicateResolver(operationEngine: first, database: fixture.database).resolve(group: group, keeperId: XCTUnwrap(keeper.id), batchId: "interrupted-trash")
        try await fixture.database.writer.write { database in try database.execute(sql: "DROP TRIGGER crash_after_trash") }
        XCTAssertEqual(recorder.trashed, [target.path])

        let restarted = recordingEngine(fixture, recorder: recorder)
        let session = makeSession(fixture, engine: restarted)
        try await session.synchronize()

        let targetRow = try await fixture.database.writer.read { database in try FileRecord.fetchOne(database, key: target.id) }
        XCTAssertNil(targetRow, "The cleanup must finish, not retire the target")
        XCTAssertEqual(recorder.trashed, [target.path])
        let remaining = try await restarted.pendingSeratoWriteCount
        XCTAssertEqual(remaining, 0)
        guard case let .ready(summary) = session.state else { return XCTFail("Sync did not reach ready") }
        XCTAssertEqual(summary.supersededWrites + summary.interruptedWrites, 0)
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
        XCTAssertEqual(summary.supersededWrites + summary.interruptedWrites, 1)
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
