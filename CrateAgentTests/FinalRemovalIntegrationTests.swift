@testable import CrateAgent
import Foundation
import GRDB
import XCTest

@MainActor
final class FinalRemovalIntegrationTests: XCTestCase {
    func testNewlyIndexedStrictObservationSeedsQueuedExternalBaseline() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let audio = fixture.directory.appendingPathComponent("newly-indexed.wav")
        try Self.wav().write(to: audio)
        try save(fixture, paths: [audio.path])
        let session = makeSession(fixture)
        try await session.synchronize()
        let file = try await fixture.database.writer.read { database in
            try XCTUnwrap(FileRecord.filter(Column("path") == audio.path).fetchOne(database))
        }
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        try await fixture.engine.apply(.setMetadata(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "First queued edit"), isSeratoAuthoritative: false)))
        try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "First queued edit"))))
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await session.synchronize()
        let current = try await fixture.row(file)
        XCTAssertEqual(current.title, "First queued edit")
        XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first?.title, "First queued edit")
    }

    func testUnknownFirstObservationFencesHistoryWithoutClaimingProvenExternalChange() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("unknown-baseline.wav", bytes: Self.wav())
        try save(fixture, paths: [file.path])
        let fileID = try XCTUnwrap(file.id)
        try await fixture.engine.apply(.setMetadata(.init(fileId: fileID, metadata: .init(title: "Local B"), isSeratoAuthoritative: false)))
        try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: "Local B"))), batchId: "unknown-owner")
        try await fixture.engine.apply(.writeFileTags(.init(fileId: fileID, metadata: .init(title: "Independent tag"))), batchId: "unknown-owner")
        try setV2(fixture, file: file, metadata: .init(title: "Saved A"))
        let session = makeSession(fixture)
        try await session.synchronize()
        let observations = try await fixture.database.writer.read { database in
            try EventRecord.filter(Column("file_id") == fileID && Column("event_type") == EventType.fileIdentityObserved.rawValue).fetchAll(database)
        }
        let payloads = try observations.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.payloadJson.utf8)) as? [String: Any]) }
        let uncertain = payloads.first { ($0["uncertainV2Fields"] as? [String]) == ["title"] }
        XCTAssertNotNil(uncertain, "Unknown external provenance must be explicit in the real observation journal")
        XCTAssertNil(uncertain?["previousObservedMetadata"])
        let replay = try await fixture.engine.resyncSeratoForBatch("unknown-owner")
        XCTAssertEqual(replay.supersededCount, 1)
        XCTAssertTrue(replay.summaryMessage.contains("could not be verified"))
        XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first?.title, "Saved A")
        XCTAssertEqual(try readAudioTags(filePath: file.path).title, "Independent tag")
    }

    func testUnstartedQueuedCleanupCannotExemptExternalRemoval() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let keeper = try await fixture.add("keeper.wav", bytes: Self.wav())
        let target = try await fixture.add("target.wav", bytes: Self.wav())
        try save(fixture, paths: [keeper.path, target.path])
        let crates = try saveCrates(fixture, paths: [keeper.path, target.path])
        let engine = cleanupEngine(fixture)
        let session = makeSession(fixture, engine: engine)
        try await session.synchronize()
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        let group = DuplicateFinder.DuplicateGroup(groupKey: "unstarted", mode: .byteLevel, files: [keeper, target])
        let outcome = try await DuplicateResolver(operationEngine: engine, database: fixture.database).resolve(group: group, keeperId: XCTUnwrap(keeper.id))
        XCTAssertEqual(outcome.pendingCount, 1)
        try save(fixture, paths: [keeper.path])
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await session.synchronize()
        let retired = try await fixture.row(target)
        XCTAssertEqual(retired.libraryMembership, .retired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        for (url, bytes) in crates {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testFailedCleanupReadditionSupersedesRetainedRetry() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let keeper = try await fixture.add("keeper.wav", bytes: Self.wav())
        let target = try await fixture.add("target.wav", bytes: Self.wav())
        try save(fixture, paths: [keeper.path, target.path])
        let crates = try saveCrates(fixture, paths: [keeper.path, target.path])
        let broken = fixture.locator.smartCratesDirectoryUrl.appendingPathComponent("broken.scrate")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        let engine = cleanupEngine(fixture)
        let group = DuplicateFinder.DuplicateGroup(groupKey: "failed-readdition", mode: .byteLevel, files: [keeper, target])
        let outcome = try await DuplicateResolver(operationEngine: engine, database: fixture.database).resolve(group: group, keeperId: XCTUnwrap(keeper.id))
        XCTAssertEqual(outcome.failureCount, 1)
        try FileManager.default.removeItem(at: broken)
        try save(fixture, paths: [keeper.path, target.path])
        _ = try saveCrates(fixture, paths: [keeper.path, target.path])
        let crateBytes = try crates.map { try Data(contentsOf: $0.0) }
        let session = makeSession(fixture, engine: engine)
        try await session.synchronize(retryingFailedCleanup: true)
        let retained = try await fixture.row(target)
        XCTAssertEqual(retained.membershipRevision, target.membershipRevision + 1)
        XCTAssertEqual(retained.lastProjectionInvalidationRevision, retained.membershipRevision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try crates.map { try Data(contentsOf: $0.0) }, crateBytes)
        XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).count, 2)
        let pendingCount = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(pendingCount, 0)
    }

    func testQueuedUndoUsesOriginalExternalBaselineAndPreservesNewerSavedField() async throws {
        for externalChange in [false, true] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("undo.wav", bytes: Self.wav())
            try save(fixture, paths: [file.path])
            try setV2(fixture, file: file, metadata: .init(title: "Original"))
            let session = makeSession(fixture)
            try await session.synchronize()
            try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Owned B"), previousMetadata: .init(title: "Original"))), batchId: "undo-baseline")
            try await session.synchronize()
            fixture.lifecycle.running = true
            fixture.watchdog.refresh()
            _ = try await fixture.engine.undoBatch("undo-baseline")
            if externalChange {
                try setV2(fixture, file: file, metadata: .init(title: "Saved C"))
            }
            fixture.lifecycle.running = false
            fixture.watchdog.refresh()
            try await session.synchronize()
            let expected = externalChange ? "Saved C" : "Original"
            let current = try await fixture.row(file)
            XCTAssertEqual(current.title, expected)
            XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first?.title, expected)
        }
    }

    func testNewExternalOwnershipIsRecordedEvenWhenLocalMetadataAlreadyMatches() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("same-local.wav", bytes: Self.wav())
        try save(fixture, paths: [file.path])
        let session = makeSession(fixture)
        try await session.synchronize()
        try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Owned A"))), batchId: "old-owner")
        try await session.synchronize()
        try await fixture.engine.apply(.setMetadata(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "External C"), isSeratoAuthoritative: false)))
        try setV2(fixture, file: file, metadata: .init(title: "External C"))
        try await session.synchronize()
        _ = try await fixture.engine.resyncSeratoForBatch("old-owner")
        XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first?.title, "External C")
    }

    func testActualDrainUsesFreshStrictSnapshotForConcurrentSavedFields() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("fresh.wav", bytes: Self.wav())
        try save(fixture, paths: [file.path])
        let targetPath = SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)
        let engine = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator, seratoMetadataBatchWriter: { source, updates in
            let result = try batchUpdateDatabaseRecords(databasePath: source, updates: updates)
            _ = try batchUpdateDatabaseRecords(databasePath: source, updates: [.init(trackPath: targetPath, update: .init(artist: "Saved during drain", title: nil, album: nil, genre: nil, bpm: nil, key: nil, comment: nil, length: nil, label: nil))])
            return result
        })
        let session = makeSession(fixture, engine: engine)
        try await session.synchronize()
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        try await engine.apply(.setMetadata(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Queued title"), isSeratoAuthoritative: false)))
        try await engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Queued title"))))
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await session.synchronize()
        let current = try await fixture.row(file)
        XCTAssertEqual(current.title, "Queued title")
        XCTAssertEqual(current.artist, "Saved during drain")
    }

    func testRealMatchTagWriteAndStrictScanPreserveSharedRecordingAndFingerprint() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("matched.wav", bytes: Self.wav())
        let sibling = try await fixture.add("sibling.wav", bytes: Self.wav())
        try save(fixture, paths: [file.path, sibling.path])
        let session = makeSession(fixture)
        try await session.synchronize()
        let fileID = try XCTUnwrap(file.id)
        let siblingID = try XCTUnwrap(sibling.id)
        let fingerprint = Data([11, 22, 33, 44])
        let trackID = try await fixture.database.writer.write { database in
            var track = TrackRecord(fingerprintHash: fingerprint, artist: "Before match")
            try track.insert(database)
            for identifier in [fileID, siblingID] {
                var current = try XCTUnwrap(FileRecord.fetchOne(database, key: identifier))
                current.trackId = track.id
                current.chromaprintFingerprint = Data([5, 6, 7, 8])
                current.fingerprintStatus = .done
                current.fingerprintedSize = current.fileSize
                current.fingerprintedMtime = current.mtime
                current.fingerprintedMtimeNanoseconds = current.mtimeNanoseconds
                current.fingerprintedInode = current.inode
                try current.update(database)
            }
            return try XCTUnwrap(track.id)
        }
        try await fixture.engine.apply(.applyMusicBrainzMatch(.init(fileID: fileID, acoustID: "owned-acoustid", recordingMBID: "owned-recording", releaseMBID: nil, artistMBID: nil, isrc: nil, fingerprintHash: fingerprint, expectedFileSize: file.fileSize, expectedMtime: file.mtime, artist: "Matched artist", title: "Matched recording title", album: nil, year: nil)), batchId: "real-match")
        let matchedTrack = try await fixture.database.writer.read { try TrackRecord.fetchOne($0, key: trackID) }
        let siblingBefore = try await fixture.row(sibling)
        try await session.synchronize()
        let current = try await fixture.row(file)
        let siblingAfter = try await fixture.row(sibling)
        let scannedTrack = try await fixture.database.writer.read { try TrackRecord.fetchOne($0, key: trackID) }
        XCTAssertEqual(current.trackId, trackID)
        XCTAssertEqual(current.membershipRevision, file.membershipRevision)
        XCTAssertEqual(current.chromaprintFingerprint, Data([5, 6, 7, 8]))
        XCTAssertEqual(current.fingerprintBasis, current.freshness)
        XCTAssertEqual(siblingAfter, siblingBefore)
        XCTAssertEqual(scannedTrack, matchedTrack)
        XCTAssertEqual(try readAudioTags(filePath: file.path).title, "Matched recording title")
        let replay = try await fixture.engine.resyncSeratoForBatch("real-match")
        XCTAssertEqual(replay.supersededCount, 0)
        XCTAssertEqual(replay.appliedCount, 1)
        _ = try await fixture.engine.undoBatch("real-match")
    }

    func testCleanupCannotCompleteWhenOneCrateFormFails() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let keeper = try await fixture.add("keeper.wav", bytes: Self.wav())
        let target = try await fixture.add("target.wav", bytes: Self.wav())
        try save(fixture, paths: [keeper.path, target.path])
        _ = try saveCrates(fixture, paths: [keeper.path, target.path])
        try FileManager.default.createDirectory(at: fixture.locator.smartCratesDirectoryUrl.appendingPathComponent("broken.scrate"), withIntermediateDirectories: false)
        let engine = cleanupEngine(fixture)
        let group = DuplicateFinder.DuplicateGroup(groupKey: "partial-crates", mode: .byteLevel, files: [keeper, target])
        let outcome = try await DuplicateResolver(operationEngine: engine, database: fixture.database).resolve(group: group, keeperId: XCTUnwrap(keeper.id))
        XCTAssertEqual(outcome.trashedCount, 0)
        XCTAssertEqual(outcome.failureCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let row = try await fixture.database.writer.read { try FileRecord.fetchOne($0, key: target.id) }
        XCTAssertNotNil(row)
        let session = makeSession(fixture, engine: engine)
        do {
            try await session.synchronize()
            XCTFail("A failed cleanup stage must remain visible until explicit retry")
        } catch {}
        let retained = try await fixture.row(target)
        XCTAssertEqual(retained.libraryMembership, .active)
        try FileManager.default.removeItem(at: fixture.locator.smartCratesDirectoryUrl.appendingPathComponent("broken.scrate"))
        try await session.synchronize(retryingFailedCleanup: true)
        let completed = try await fixture.database.writer.read { try FileRecord.fetchOne($0, key: target.id) }
        XCTAssertNil(completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testPendingCleanupReappearanceFencesLegacyReplayAndBothOriginalPlanRoles() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let keeper = try await fixture.add("keeper.wav", bytes: Self.wav())
        let target = try await fixture.add("target.wav", bytes: Self.wav())
        try save(fixture, paths: [keeper.path, target.path])
        let engine = cleanupEngine(fixture)
        let session = makeSession(fixture, engine: engine)
        try await session.synchronize()
        let targetID = try XCTUnwrap(target.id)
        try await fixture.database.writer.write { database in
            let payload = "{\"fileId\":\(targetID),\"metadata\":{\"title\":\"Legacy title\"}}"
            try database.execute(sql: "INSERT INTO events (batch_id, timestamp, file_id, event_type, payload_json, inverse_payload_json) VALUES (?, ?, ?, ?, ?, ?)", arguments: ["legacy-owner", 1, targetID, EventType.metadataCommittedToSerato.rawValue, payload, payload])
            database.trace { event in
                if event.expandedDescription.contains("INSERT INTO \"events\""), event.expandedDescription.contains("file_removed_from_crates") {
                    DispatchQueue.main.sync { fixture.lifecycle.running = true; fixture.watchdog.refresh() }
                }
            }
        }
        let group = DuplicateFinder.DuplicateGroup(groupKey: "original", mode: .byteLevel, files: [keeper, target])
        let pending = try await DuplicateResolver(operationEngine: engine, database: fixture.database).resolve(group: group, keeperId: XCTUnwrap(keeper.id))
        XCTAssertEqual(pending.pendingCount, 1)
        try await fixture.database.writer.write { $0.trace(nil) }
        try save(fixture, paths: [keeper.path, target.path])
        let crates = try saveCrates(fixture, paths: [keeper.path, target.path])
        let v2 = try Data(contentsOf: fixture.locator.databaseV2Url)
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await session.synchronize()
        let current = try await fixture.row(target)
        XCTAssertEqual(current.libraryMembership, .active)
        XCTAssertEqual(current.membershipRevision, target.membershipRevision + 1)
        XCTAssertEqual(current.lastProjectionInvalidationRevision, current.membershipRevision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let legacy = try await engine.resyncSeratoForBatch("legacy-owner")
        XCTAssertEqual(legacy.supersededCount, 1)
        for keeperID in try [XCTUnwrap(keeper.id), targetID] {
            let outcome = try await DuplicateResolver(operationEngine: engine, database: fixture.database).resolve(group: group, keeperId: keeperID)
            XCTAssertEqual(outcome.failureCount, 1)
            XCTAssertEqual(outcome.trashedCount, 0)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), v2)
        for (url, bytes) in crates {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
    }

    func testReplacementAfterTrashCannotAuthorizeFinalRowDeletion() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let keeper = try await fixture.add("keeper.wav", bytes: Self.wav())
        let target = try await fixture.add("target.wav", bytes: Self.wav())
        try save(fixture, paths: [keeper.path, target.path])
        let retained = fixture.directory.appendingPathComponent("owned-trash.wav")
        let replacement = Self.wav(sample: 9)
        let engine = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator, fileTrasher: { path in
            try FileManager.default.moveItem(atPath: path, toPath: retained.path)
            try replacement.write(to: URL(fileURLWithPath: path))
        })
        let group = DuplicateFinder.DuplicateGroup(groupKey: "final-delete", mode: .byteLevel, files: [keeper, target])
        let outcome = try await DuplicateResolver(operationEngine: engine, database: fixture.database).resolve(group: group, keeperId: XCTUnwrap(keeper.id))
        XCTAssertEqual(outcome.failureCount, 1)
        XCTAssertEqual(outcome.trashedCount, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target.path)), replacement)
        let row = try await fixture.database.writer.read { try FileRecord.fetchOne($0, key: target.id) }
        XCTAssertNotNil(row)
        let deletions = try await fixture.database.writer.read { try EventRecord.filter(Column("batch_id") == outcome.batchId && Column("event_type") == EventType.fileRemoved.rawValue).fetchCount($0) }
        XCTAssertEqual(deletions, 0)
    }

    func testReplacementPreventsQueuedTrashAddAndReferenceRemovalAtActualBoundary() async throws {
        for operation in ["trash", "add", "database removal", "crate removal"] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let target = try await fixture.add("target.wav", membership: operation == "add" ? .pendingImport : .active, bytes: Self.wav())
            let engine = cleanupEngine(fixture)
            try save(fixture, paths: operation == "add" ? [] : [target.path])
            let crates = try saveCrates(fixture, paths: [target.path])
            let v2 = try Data(contentsOf: fixture.locator.databaseV2Url)
            let fileID = try XCTUnwrap(target.id)
            fixture.lifecycle.running = true
            fixture.watchdog.refresh()
            let mutation: TrackMutation = switch operation {
            case "trash": .trashFile(.init(fileId: fileID))
            case "add": .addTrackToSerato(.init(fileId: fileID, metadata: .init(title: "Wrong recording")))
            case "database removal": .removeTrackFromSerato(.init(fileId: fileID))
            default: .removeFileFromCrates(.init(fileId: fileID))
            }
            try await engine.apply(mutation)
            let replacement = Self.wav(sample: 5)
            try FileManager.default.moveItem(atPath: target.path, toPath: fixture.directory.appendingPathComponent("retained.wav").path)
            try replacement.write(to: URL(fileURLWithPath: target.path))
            fixture.lifecycle.running = false
            fixture.watchdog.refresh()
            let outcome = try await engine.drainPendingSeratoUpdates()
            XCTAssertEqual(outcome.supersededCount, 1, operation)
            XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), v2, operation)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target.path)), replacement, operation)
            for (url, bytes) in crates {
                XCTAssertEqual(try Data(contentsOf: url), bytes, operation)
            }
        }
    }

    func testReplacementAtFinalWriterBoundarySupersedesOnlyItsQueuedWork() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let target = try await fixture.add("target.wav", bytes: Self.wav())
        let other = try await fixture.add("other.wav", bytes: Self.wav())
        try save(fixture, paths: [target.path, other.path])
        try await makeSession(fixture).synchronize()
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        try await fixture.engine.apply(.writeFileTags(.init(fileId: XCTUnwrap(target.id), metadata: .init(title: "Must not write"))))
        try await fixture.engine.apply(.writeFileTags(.init(fileId: XCTUnwrap(other.id), metadata: .init(title: "Other applies"))))
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        let replacement = Self.wav(sample: 11)
        let replacementURL = URL(fileURLWithPath: target.path)
        let replaced = LockedTestFlag()
        try await fixture.database.writer.write { database in
            database.trace { event in
                if event.expandedDescription.contains("SELECT"), event.expandedDescription.contains("file_identity_observed"), replaced.setOnce() {
                    do {
                        try FileManager.default.removeItem(at: replacementURL)
                        try replacement.write(to: replacementURL)
                    } catch { XCTFail("Replacement injection failed: \(error)") }
                }
            }
        }
        let outcome = try await fixture.engine.drainPendingSeratoUpdates()
        try await fixture.database.writer.write { $0.trace(nil) }
        XCTAssertTrue(replaced.value)
        XCTAssertEqual(try Data(contentsOf: replacementURL), replacement)
        XCTAssertEqual(try readAudioTags(filePath: other.path).title, "Other applies")
        XCTAssertEqual(outcome.supersededCount, 1)
        XCTAssertEqual(outcome.appliedCount, 1)
        let depth = try await fixture.engine.pendingSeratoWriteCount
        XCTAssertEqual(depth, 0)
    }

    func testChangedOrClearedSavedValueDefeatsMultipleQueuedV2IntentsButKeepsTagOwnership() async throws {
        for externalTitle in ["External C", ""] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("conflict.wav", bytes: Self.wav())
            try save(fixture, paths: [file.path])
            try setV2(fixture, file: file, metadata: .init(artist: "Original artist", title: "External A"))
            let session = makeSession(fixture)
            try await session.synchronize()
            fixture.lifecycle.running = true
            fixture.watchdog.refresh()
            for title in ["Queued B", "Queued D"] {
                try await fixture.engine.apply(.setMetadata(.init(fileId: XCTUnwrap(file.id), metadata: .init(artist: "Original artist", title: title), isSeratoAuthoritative: false)))
                try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: title), previousMetadata: .init(title: "External A"))), batchId: title)
            }
            try await fixture.engine.apply(.writeFileTags(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Independent audio title"))), batchId: "audio-owner")
            try setV2(fixture, file: file, metadata: .init(artist: "Independent artist", title: externalTitle))
            fixture.lifecycle.running = false
            fixture.watchdog.refresh()
            try await session.synchronize()
            let current = try await fixture.row(file)
            XCTAssertEqual(current.title ?? "", externalTitle)
            XCTAssertEqual(current.artist, "Independent artist")
            let record = try XCTUnwrap(readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first)
            XCTAssertEqual(record.title ?? "", externalTitle)
            XCTAssertEqual(try readAudioTags(filePath: file.path).title, "Independent audio title")
            guard case let .ready(summary) = session.state else { return XCTFail("\(session.state)") }
            XCTAssertEqual(summary.notAppliedWrites.total, 2)
            let replay = try await fixture.engine.resyncSeratoForBatch("audio-owner")
            XCTAssertEqual(replay.appliedCount, 1)
            XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first?.title ?? "", externalTitle)
        }
    }

    func testStaleDuplicatePlanCannotTrashReaddedReplacedTargetOrInvalidKeeper() async throws {
        for change in ["readded target", "replaced target", "retired keeper"] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let keeper = try await fixture.add("keeper.wav", bytes: Self.wav())
            let target = try await fixture.add("target.wav", bytes: Self.wav())
            try save(fixture, paths: [keeper.path, target.path])
            let engine = cleanupEngine(fixture)
            let session = makeSession(fixture, engine: engine)
            try await session.synchronize()
            let group = DuplicateFinder.DuplicateGroup(groupKey: "reviewed", mode: .byteLevel, files: [keeper, target])
            if change == "replaced target" {
                try FileManager.default.removeItem(atPath: target.path)
                try Self.wav(sample: 9).write(to: URL(fileURLWithPath: target.path))
                try await session.synchronize()
            } else {
                try save(fixture, paths: [change == "retired keeper" ? target.path : keeper.path])
                try await session.synchronize()
                if change == "readded target" {
                    try save(fixture, paths: [keeper.path, target.path])
                    try await session.synchronize()
                }
            }
            let crates = try saveCrates(fixture, paths: [keeper.path, target.path])
            let sourceBytes = try Data(contentsOf: URL(fileURLWithPath: target.path))
            let v2Bytes = try Data(contentsOf: fixture.locator.databaseV2Url)
            let eventsBefore = try await fixture.events()
            let outcome = try await DuplicateResolver(operationEngine: engine, database: fixture.database).resolve(group: group, keeperId: XCTUnwrap(keeper.id), batchId: "stale-cleanup")
            XCTAssertEqual(outcome.trashedCount, 0, change)
            XCTAssertEqual(outcome.failureCount, 1, change)
            XCTAssertTrue(outcome.errors.joined().contains("superseded"), "\(change): \(outcome.errors)")
            XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), v2Bytes, change)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), change)
            if FileManager.default.fileExists(atPath: target.path) {
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target.path)), sourceBytes)
            }
            for (url, bytes) in crates {
                XCTAssertEqual(try Data(contentsOf: url), bytes, change)
            }
            let current = try await fixture.database.writer.read { try FileRecord.fetchOne($0, key: target.id) }
            XCTAssertNotNil(current, change)
            let eventsAfter = try await fixture.events()
            XCTAssertEqual(eventsAfter, eventsBefore, change)
        }
    }

    func testQueuedTagFollowsVerifiedMoveWithoutWritingReusedOldPath() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("original.wav", bytes: Self.wav())
        try save(fixture, paths: [file.path])
        let session = makeSession(fixture)
        try await session.synchronize()
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        try await fixture.engine.apply(.writeFileTags(.init(fileId: XCTUnwrap(file.id), metadata: .init(title: "Queued title"))))
        let destination = fixture.directory.appendingPathComponent("moved.wav")
        try FileManager.default.moveItem(atPath: file.path, toPath: destination.path)
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        try await coordinator.handleObservations([.init(path: destination.path, isFile: true, wasRenamed: true)])
        let unrelated = Self.wav(sample: 7)
        try unrelated.write(to: URL(fileURLWithPath: file.path))
        try save(fixture, paths: [destination.path, file.path])
        let crates = try saveCrates(fixture, paths: [destination.path, file.path])
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await session.synchronize()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path)), unrelated)
        XCTAssertEqual(try readAudioTags(filePath: destination.path).title, "Queued title")
        XCTAssertEqual(try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).map { SeratoPath.normalized($0.path) }, [destination.path, file.path])
        for (url, bytes) in crates {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testOwnedTagWriteKeepsRecordingFingerprintRevisionAndHistoryAfterStrictSync() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("owned.wav", bytes: Self.wav())
        try save(fixture, paths: [file.path])
        let session = makeSession(fixture)
        try await session.synchronize()
        let fileID = try XCTUnwrap(file.id)
        let before = try await fixture.database.writer.write { database in
            var track = TrackRecord(fingerprintHash: Data([9, 8, 7]))
            try track.insert(database)
            var current = try XCTUnwrap(FileRecord.fetchOne(database, key: fileID))
            current.trackId = track.id
            current.chromaprintFingerprint = Data([1, 2, 3])
            current.fingerprintStatus = .done
            current.fingerprintedSize = current.fileSize
            current.fingerprintedMtime = current.mtime
            current.fingerprintedMtimeNanoseconds = current.mtimeNanoseconds
            current.fingerprintedInode = current.inode
            try current.update(database)
            return current
        }
        try await fixture.engine.apply(.writeFileTags(.init(fileId: fileID, metadata: .init(title: "A materially longer owned title"), previousMetadata: .init(title: ""))), batchId: "owned-tags")
        try await session.synchronize()
        let current = try await fixture.row(file)
        XCTAssertEqual(current.trackId, before.trackId)
        XCTAssertEqual(current.chromaprintFingerprint, before.chromaprintFingerprint)
        XCTAssertEqual(current.membershipRevision, before.membershipRevision)
        XCTAssertNil(current.lastProjectionInvalidationRevision)
        XCTAssertEqual(current.fingerprintBasis, current.freshness)
        let replay = try await fixture.engine.resyncSeratoForBatch("owned-tags")
        XCTAssertEqual(replay.supersededCount, 0)
        XCTAssertEqual(replay.appliedCount, 1)
        _ = try await fixture.engine.undoBatch("owned-tags")
        XCTAssertEqual(try readAudioTags(filePath: file.path).title ?? "", "")
    }

    func testQueuedV2MetadataAndIndependentSavedFieldConvergeAfterSession() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("queued.wav", bytes: Self.wav())
        try save(fixture, paths: [file.path])
        try setV2(fixture, file: file, metadata: .init(artist: "Original artist", title: "Old"))
        let session = makeSession(fixture)
        try await session.synchronize()
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        let fileID = try XCTUnwrap(file.id)
        try await fixture.engine.apply(.setMetadata(.init(fileId: fileID, metadata: .init(artist: "Original artist", title: "New"), isSeratoAuthoritative: false)))
        try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: fileID, metadata: .init(title: "New"), previousMetadata: .init(title: "Old"))), batchId: "queued-local")
        try setV2(fixture, file: file, metadata: .init(artist: "Independent Serato artist"))
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        try await session.synchronize()
        let current = try await fixture.row(file)
        XCTAssertEqual(current.title, "New")
        XCTAssertEqual(current.artist, "Independent Serato artist")
        let record = try XCTUnwrap(readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first)
        XCTAssertEqual(record.title, current.title)
        XCTAssertEqual(record.artist, current.artist)
    }

    func testStrictObservationChangedAndClearedFieldsSupersedeOnlyV2Ownership() async throws {
        for savedArtist in ["Serato B", ""] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("ownership.wav", bytes: Self.wav())
            try save(fixture, paths: [file.path])
            let session = makeSession(fixture)
            try await session.synchronize()
            let metadata = SeratoMetadata(artist: "Owned A", title: "Owned title")
            try await fixture.engine.apply(.commitMetadataToSerato(.init(fileId: XCTUnwrap(file.id), metadata: metadata)), batchId: "older-v2")
            try await session.synchronize()
            try setV2(fixture, file: file, metadata: .init(artist: savedArtist))
            try await session.synchronize()
            _ = try await fixture.engine.resyncSeratoForBatch("older-v2")
            let record = try XCTUnwrap(readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first)
            XCTAssertEqual(record.artist ?? "", savedArtist)
            XCTAssertEqual(record.title, "Owned title")
            try setV2(fixture, file: file, metadata: .init(title: "Unapplied title repair"))
            let repair = try await fixture.engine.resyncSeratoForBatch("older-v2")
            XCTAssertEqual(repair.appliedCount, 1, "An unchanged co-imported title keeps the old V2 owner")
            let repaired = try XCTUnwrap(readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first)
            XCTAssertEqual(repaired.artist ?? "", savedArtist)
            XCTAssertEqual(repaired.title, "Owned title")
        }
    }

    private func makeSession(_ fixture: SeratoRemovalFixture, engine: OperationEngine? = nil) -> SeratoLibrarySyncSession {
        let engine = engine ?? fixture.engine
        return SeratoLibrarySyncSession(reader: fixture.reader, reconciler: SeratoMembershipReconciler(database: fixture.database, operationEngine: engine, reader: fixture.reader),
                                        scanner: LibraryScanner(operationEngine: engine, database: fixture.database, seratoLocator: fixture.locator),
                                        operationEngine: engine, watchdog: fixture.watchdog, readiness: LibrarySyncReadiness())
    }

    private func cleanupEngine(_ fixture: SeratoRemovalFixture) -> OperationEngine {
        let directory = fixture.directory
        return OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator, fileTrasher: { path in
            try FileManager.default.moveItem(atPath: path, toPath: directory.appendingPathComponent("owned-trash-" + (path as NSString).lastPathComponent).path)
        })
    }

    private func saveCrates(_ fixture: SeratoRemovalFixture, paths: [String]) throws -> [(URL, Data)] {
        let bytes = paths.reduce(SeratoTestEncoding.record("vrsn", Data("1.0/Serato ScratchLive Crate".data(using: .utf16BigEndian)!))) { bytes, path in
            bytes + SeratoTestEncoding.record("otrk", SeratoTestEncoding.record("ptrk", SeratoLibraryLocator.seratoRelativePath(fromAbsolute: path).data(using: .utf16BigEndian)!))
        }
        return try [fixture.locator.subcratesDirectoryUrl.appendingPathComponent("owned.crate"), fixture.locator.smartCratesDirectoryUrl.appendingPathComponent("owned.scrate")].map { url in
            try bytes.write(to: url)
            return (url, bytes)
        }
    }

    private func save(_ fixture: SeratoRemovalFixture, paths: [String]) throws {
        try fixture.save(paths: paths.map(SeratoLibraryLocator.seratoRelativePath))
    }

    private func setV2(_ fixture: SeratoRemovalFixture, file: FileRecord, metadata: SeratoMetadata) throws {
        _ = try batchUpdateDatabaseRecords(databasePath: fixture.locator.databaseV2Url.path, updates: [.init(trackPath: SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path), update: .init(artist: metadata.artist, title: metadata.title, album: metadata.album, genre: metadata.genre, bpm: metadata.bpm, key: metadata.musicalKey, comment: metadata.comment, length: metadata.length, label: metadata.label))])
    }

    static func wav(sample: UInt8 = 0, durationSeconds: Int = 1) -> Data {
        let sampleBytes = Data(repeating: sample, count: 88200 * durationSeconds)
        func little(_ value: some FixedWidthInteger) -> Data {
            var encoded = value.littleEndian
            return withUnsafeBytes(of: &encoded) { Data($0) }
        }
        var bytes = Data("RIFF".utf8)
        bytes += little(UInt32(36 + sampleBytes.count))
        bytes += Data("WAVEfmt ".utf8)
        bytes += little(UInt32(16))
        bytes += little(UInt16(1))
        bytes += little(UInt16(1))
        bytes += little(UInt32(44100))
        bytes += little(UInt32(88200))
        bytes += little(UInt16(2))
        bytes += little(UInt16(16))
        bytes += Data("data".utf8)
        bytes += little(UInt32(sampleBytes.count))
        bytes += sampleBytes
        return bytes
    }
}

private final class LockedTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }; return stored
    }

    func setOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stored else { return false }
        stored = true
        return true
    }
}
