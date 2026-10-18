@testable import CrateAgent
import GRDB
import XCTest

@MainActor
final class SeratoMembershipReconcilerTests: XCTestCase {
    /// #118: a same-length edit in the same second, outside the sampled hash windows, is new
    /// audio. Reconciliation must treat it as a replacement, not an identity-only update that
    /// keeps the old fingerprint and revision.
    func testSameSecondInPlaceEditIsReconciledAsReplacement() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("edited.wav", bytes: Data(repeating: 0, count: 3 * LightweightHashCalculator.windowSize))
        let fileID = try XCTUnwrap(file.id)
        try fixture.save(paths: [file.path])
        try await fixture.database.writer.write { database in
            try database.execute(sql: "UPDATE files SET chromaprint_fingerprint = x'01', fingerprint_status = 'done' WHERE id = ?", arguments: [fileID])
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file.path))
        try handle.seek(toOffset: UInt64(LightweightHashCalculator.windowSize + 1024))
        try handle.write(contentsOf: Data([1, 2, 3, 4]))
        try handle.close()
        let recordedNanoseconds = try XCTUnwrap(file.mtimeNanoseconds)
        try setModificationTime(of: file.path, seconds: Int(file.mtime), nanoseconds: Int((recordedNanoseconds + 500_000_000) % 1_000_000_000))
        let edited = try XCTUnwrap(FileMetadataCollector.collect(at: file.path, includeLightweightHash: true))
        XCTAssertEqual(edited.mtime, file.mtime)
        XCTAssertEqual(edited.lightweightHash, file.lightweightHash, "the edit must leave the sampled hash unchanged")

        _ = try await fixture.reconcile()

        let row = try await fixture.row(file)
        XCTAssertNil(row.chromaprintFingerprint)
        XCTAssertEqual(row.fingerprintStatus, .pending)
        XCTAssertEqual(row.membershipRevision, file.membershipRevision + 1)
    }

    func testSameRevisionFilesystemObservationRejectsStaleReconciliationState() async throws {
        for (relocate, currentAvailability) in [(false, FileAvailability.available), (true, .available), (true, .missing)] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("race.mp3")
            let held = fixture.directory.appendingPathComponent("held.mp3").path
            let destination = relocate ? fixture.directory.appendingPathComponent("saved.mp3").path : file.path
            let fileID = try XCTUnwrap(file.id)
            try FileManager.default.moveItem(atPath: file.path, toPath: held)
            _ = try await fixture.engine.apply(.setFileLibraryState(.init(fileId: fileID, expectedRevision: 0,
                                                                          state: .init(membership: .active, availability: .missing, libraryID: file.seratoLibraryId, retiredAt: nil))))
            try fixture.save(paths: [destination])
            let engine = fixture.engine
            let reconciler = SeratoMembershipReconciler(database: fixture.database, operationEngine: engine, reader: fixture.reader, beforeCommit: {
                try FileManager.default.moveItem(atPath: held, toPath: destination)
                _ = try await engine.applyBatch([
                    .observeFileLocation(.init(fileId: fileID, expectedRevision: 0, path: destination, volumeUuid: file.volumeUuid, inode: file.inode)),
                    .setFileLibraryState(.init(fileId: fileID, expectedRevision: 0, state: .init(membership: .active, availability: currentAvailability, libraryID: file.seratoLibraryId, retiredAt: nil))),
                ], batchId: "interleaved-filesystem")
            })
            do {
                _ = try await reconciler.reconcile(fixture.reader.read())
                XCTFail("Stale reconciliation overwrote a same-revision filesystem observation")
            } catch {
                guard case FileProcessingEligibilityError.superseded(fileId: fileID) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            let result = try await fixture.row(file)
            XCTAssertEqual(result.path, destination)
            XCTAssertEqual(result.fileAvailability, currentAvailability)
            XCTAssertEqual(result.libraryMembership, .active)
            XCTAssertEqual(result.membershipRevision, 0)
            let count = try await fixture.events()
            XCTAssertEqual(count, 1 + (relocate ? 1 : 0) + (currentAvailability == .available ? 1 : 0))
        }
    }

    func testRestoredPendingRenameUsesCurrentAvailabilityInsteadOfCachedState() async throws {
        for cachedAvailability in [FileAvailability.missing, .unknown] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await fixture.add("before.mp3")
            let fileID = try XCTUnwrap(file.id)
            try fixture.save(paths: [file.path])
            fixture.lifecycle.running = true
            fixture.watchdog.refresh()
            let destination = fixture.directory.appendingPathComponent("after.mp3").path
            let held = fixture.directory.appendingPathComponent("temporarily-gone.mp3").path
            try FileManager.default.moveItem(atPath: file.path, toPath: destination)
            _ = try await fixture.engine.apply(.renameFile(.init(fileId: fileID, newPath: destination)))
            try FileManager.default.moveItem(atPath: destination, toPath: held)
            _ = try await fixture.engine.apply(.setFileLibraryState(.init(fileId: fileID, expectedRevision: 0,
                                                                          state: .init(membership: .active, availability: cachedAvailability, libraryID: file.seratoLibraryId, retiredAt: nil))))
            try FileManager.default.moveItem(atPath: held, toPath: destination)
            fixture.lifecycle.running = false
            fixture.watchdog.refresh()
            let before = try Data(contentsOf: fixture.locator.databaseV2Url)
            let summary = try await fixture.reconcile()
            let result = try await fixture.row(file)
            XCTAssertEqual(summary.retired, 0)
            XCTAssertEqual(result.libraryMembership, .active)
            XCTAssertEqual(result.fileAvailability, .available)
            XCTAssertEqual(result.membershipRevision, 0)
            XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), before)
        }
    }

    func testReplacementInvalidatesLegacyUnversionedHistoryProjection() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("legacy-history.mp3")
        try fixture.save(paths: [file.path])
        let payload = try CommitMetadataToSeratoPayload(fileId: XCTUnwrap(file.id), metadata: SeratoMetadata(artist: "Obsolete Artist"))
        let encoded = try String(decoding: JSONEncoder().encode(payload), as: UTF8.self)
        try await fixture.database.writer.write { connection in
            var event = EventRecord(batchId: "legacy-history", timestamp: 0, fileId: file.id, eventType: .metadataCommittedToSerato, payloadJson: encoded, inversePayloadJson: encoded)
            try event.insert(connection)
        }
        try FileManager.default.moveItem(atPath: file.path, toPath: fixture.directory.appendingPathComponent("old-content.mp3").path)
        try Data([9, 9, 9]).write(to: URL(fileURLWithPath: file.path))
        _ = try await fixture.reconcile()
        let before = try Data(contentsOf: fixture.locator.databaseV2Url)
        let result = try await fixture.engine.resyncSeratoForBatch("legacy-history")
        XCTAssertEqual(result.supersededCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.locator.databaseV2Url), before)
    }

    func testCrateOnlyRemovalDoesNotRetireMainLibraryMember() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("crate.mp3")
        try fixture.save(paths: [file.path])
        let crate = fixture.locator.subcratesDirectoryUrl.appendingPathComponent("test.crate")
        let bytes = try SeratoTestEncoding.record("vrsn", XCTUnwrap("1.0/Serato ScratchLive Crate".data(using: .utf16BigEndian)))
            + SeratoTestEncoding.record("otrk", SeratoTestEncoding.record("ptrk", XCTUnwrap(file.path.data(using: .utf16BigEndian))))
        try bytes.write(to: crate)
        _ = try await fixture.reconcile()
        try FileManager.default.removeItem(at: crate)
        _ = try await fixture.reconcile()
        let result = try await fixture.row(file)
        XCTAssertEqual(result.libraryMembership, .active)
        XCTAssertEqual(result.membershipRevision, 0)
    }

    func testRetirementPreservesRecordingFingerprintHistoryAndSibling() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("remove.mp3")
        let sibling = try await fixture.add("keep.mp3")
        try await fixture.database.writer.write { connection in
            var track = TrackRecord(id: 81, fingerprintHash: Data([7]))
            try track.insert(connection)
            try connection.execute(sql: "UPDATE files SET track_id = 81, chromaprint_fingerprint = ?", arguments: [Data([6])])
        }
        _ = try await fixture.engine.apply(.setMetadata(.init(fileId: XCTUnwrap(file.id), metadata: SeratoMetadata(artist: "History"), isSeratoAuthoritative: true)))
        try fixture.save(paths: [sibling.path])
        _ = try await fixture.reconcile()
        let retired = try await fixture.row(file)
        let kept = try await fixture.row(sibling)
        XCTAssertEqual(retired.libraryMembership, .retired)
        XCTAssertEqual(retired.trackId, 81)
        XCTAssertEqual(retired.chromaprintFingerprint, Data([6]))
        XCTAssertEqual(kept.libraryMembership, .active)
        XCTAssertEqual(kept.trackId, 81)
        let history = try await fixture.database.writer.read { connection in try EventRecord.filter(Column("file_id") == file.id).fetchAll(connection) }
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy { event in event.fileId == file.id && !event.inversePayloadJson.isEmpty })
    }

    func testNativeTrashRestoreDoesNotReactivateWithoutSavedReadd() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("trash.mp3")
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: &trashedURL)
        let trash = try XCTUnwrap(trashedURL as URL?)
        defer {
            if FileManager.default.fileExists(atPath: trash.path) {
                do { try FileManager.default.removeItem(at: trash) }
                catch { XCTFail("Could not clean native Trash fixture: \(error)") }
            }
        }
        let coordinator = FilesystemSyncCoordinator(operationEngine: fixture.engine, database: fixture.database)
        try await coordinator.handleObservations([.init(path: trash.path, isFile: true, wasRenamed: true)])
        _ = try await fixture.reconcile()
        let retired = try await fixture.row(file)
        XCTAssertEqual(retired.libraryMembership, .retired)
        XCTAssertEqual(retired.fileAvailability, .trashed)
        XCTAssertEqual(retired.path, file.path)
        try FileManager.default.moveItem(at: trash, to: URL(fileURLWithPath: file.path))
        try await coordinator.handleObservations([.init(path: file.path, isFile: true, wasCreated: true)])
        _ = try await fixture.reconcile()
        let restored = try await fixture.row(file)
        XCTAssertEqual(restored.libraryMembership, .retired)
        XCTAssertEqual(restored.fileAvailability, .available)
        try fixture.save(paths: [file.path])
        let readd = try await fixture.reconcile()
        XCTAssertEqual(readd.reactivated, 1)
    }

    func testColdSnapshotScannerIndexesNewMemberOnce() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let path = fixture.directory.appendingPathComponent("new.mp3").path
        try Data([3, 2, 1]).write(to: URL(fileURLWithPath: path))
        try fixture.save(paths: [path])
        let scanner = LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator)
        let snapshot = try await fixture.reader.read()
        _ = try await fixture.reconciler.reconcile(snapshot)
        let first = try await scanner.scan(snapshot: snapshot, reader: fixture.reader)
        XCTAssertEqual(first.filesIndexed, 1)
        let count = try await fixture.events()
        let second = try await scanner.scan(snapshot: snapshot, reader: fixture.reader)
        XCTAssertEqual(second.filesIndexed, 0)
        let repeated = try await fixture.events()
        XCTAssertEqual(count, repeated)
    }

    func testHistoricalRenameFromPriorMembershipDoesNotProtectAbsence() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("past.mp3")
        try fixture.save(paths: [file.path])
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        let destination = fixture.directory.appendingPathComponent("current.mp3").path
        try FileManager.default.moveItem(atPath: file.path, toPath: destination)
        _ = try await fixture.engine.apply(.renameFile(.init(fileId: XCTUnwrap(file.id), newPath: destination)))
        _ = try await fixture.engine.apply(.setFileLibraryState(.init(fileId: XCTUnwrap(file.id), expectedRevision: 0, state: .init(membership: .retired, availability: .available, libraryID: file.seratoLibraryId, retiredAt: 1))))
        _ = try await fixture.engine.apply(.setFileLibraryState(.init(fileId: XCTUnwrap(file.id), expectedRevision: 1, state: .init(membership: .active, availability: .available, libraryID: file.seratoLibraryId, retiredAt: nil))))
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        let summary = try await fixture.reconcile()
        XCTAssertEqual(summary.retired, 1)
    }

    func testNewerSnapshotInvalidatesMetadataAuthorizationWithoutMembershipChange() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("generation.mp3")
        try fixture.save(paths: [file.path])
        let oldSnapshot = try await fixture.reader.read()
        let authorization = try await fixture.reader.authorization(for: oldSnapshot)
        let current = try await fixture.reader.read()
        _ = try await fixture.reconciler.reconcile(current)
        let unchanged = try await fixture.row(file)
        XCTAssertEqual(unchanged.membershipRevision, file.membershipRevision)
        let count = try await fixture.events()
        do {
            _ = try await fixture.engine.applyObservedBatch([.observeFileIdentity(.init(fileId: XCTUnwrap(file.id), expectedRevision: file.membershipRevision,
                                                                                        previousIdentity: file.identity, identity: file.identity,
                                                                                        metadata: SeratoMetadata(artist: "stale"), expectedState: file.libraryState))], authorization: authorization)
            XCTFail("older generation committed")
        } catch { XCTAssertEqual(error as? SeratoMembershipSnapshotError, .sourceChanged) }
        let result = try await fixture.row(file)
        let finalCount = try await fixture.events()
        XCTAssertNil(result.artist)
        XCTAssertEqual(finalCount, count)
    }

    func testExplicitImportReactivatesAndFailedAddRemainsPending() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("import.mp3")
        _ = try await fixture.reconcile()
        let importer = ImportCoordinator(operationEngine: fixture.engine, database: fixture.database)
        let success = await importer.importDroppedItems([URL(fileURLWithPath: file.path)])
        XCTAssertEqual(success.filesImported, 1)
        let active = try await fixture.row(file)
        XCTAssertEqual(active.libraryMembership, .active)
        try fixture.save(paths: [])
        _ = try await fixture.reconcile()
        try Data("broken".utf8).write(to: fixture.locator.databaseV2Url)
        let failed = await importer.importDroppedItems([URL(fileURLWithPath: file.path)])
        XCTAssertEqual(failed.filesPendingSync, 1)
        XCTAssertEqual(failed.filesSkipped, 0)
        let pending = try await fixture.row(file)
        XCTAssertEqual(pending.libraryMembership, .pendingImport)
        try fixture.save(paths: [])
        _ = try await fixture.reconcile()
        let retained = try await fixture.row(file)
        XCTAssertEqual(retained.libraryMembership, .pendingImport)
    }

    func testUnicodeEquivalentPathsDoNotDuplicateOrRetire() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("Café.mp3")
        try fixture.save(paths: [String(file.path.dropFirst()).decomposedStringWithCanonicalMapping])
        _ = try await fixture.reconcile()
        let result = try await fixture.row(file)
        XCTAssertEqual(result.libraryMembership, .active)
        XCTAssertEqual(result.id, file.id)
    }

    func testValidatedScannerConsumesSnapshotAndRejectsLaterSource() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("scan.mp3")
        try fixture.save(paths: [file.path])
        let scanner = LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator)
        let snapshot = try await fixture.reader.read()
        _ = try await fixture.reconciler.reconcile(snapshot)
        _ = try await scanner.scan(snapshot: snapshot, reader: fixture.reader)
        let count = try await fixture.events()
        _ = try await scanner.scan(snapshot: snapshot, reader: fixture.reader)
        let repeated = try await fixture.events()
        XCTAssertEqual(repeated, count)
        try fixture.save(paths: [])
        do { _ = try await scanner.scan(snapshot: snapshot, reader: fixture.reader); XCTFail("stale scan accepted") } catch {}
    }

    func testObservedMetadataRejectsLateRetirementAndChangedBytes() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("late.mp3")
        let payload = try ObserveFileIdentityPayload(fileId: XCTUnwrap(file.id), expectedRevision: file.membershipRevision, previousIdentity: file.identity, identity: file.identity, metadata: SeratoMetadata(artist: "stale"), expectedState: file.libraryState)
        _ = try await fixture.reconcile()
        do { _ = try await fixture.engine.apply(.observeFileIdentity(payload)); XCTFail("late metadata applied") } catch {}
        let retired = try await fixture.row(file)
        XCTAssertNil(retired.artist)
    }

    func testApplicableQueuedRenameSurvivesSavedOldPath() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("before.mp3")
        try fixture.save(paths: [file.path])
        fixture.lifecycle.running = true
        fixture.watchdog.refresh()
        let destination = fixture.directory.appendingPathComponent("after.mp3").path
        try FileManager.default.moveItem(atPath: file.path, toPath: destination)
        _ = try await fixture.engine.apply(.renameFile(.init(fileId: XCTUnwrap(file.id), newPath: destination)))
        fixture.lifecycle.running = false
        fixture.watchdog.refresh()
        _ = try await fixture.reconcile()
        let result = try await fixture.row(file)
        XCTAssertEqual(result.libraryMembership, .active)
        XCTAssertEqual(result.path, destination)
        XCTAssertEqual(result.membershipRevision, file.membershipRevision)
    }

    func testReplacementClearsFileAssociationAndJournalsPriorIdentity() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("replaced.mp3")
        let sibling = try await fixture.add("sibling.mp3")
        try await fixture.database.writer.write { connection in
            var track = TrackRecord(id: 71, fingerprintHash: Data([9]), musicbrainzRecordingId: "old-recording")
            try track.insert(connection)
            try connection.execute(sql: "UPDATE files SET track_id = 71, chromaprint_fingerprint = ?, fingerprint_status = 'done', artist = 'Old Artist' WHERE id IN (?, ?)", arguments: [Data([8]), file.id, sibling.id])
        }
        try FileManager.default.moveItem(atPath: file.path, toPath: fixture.directory.appendingPathComponent("held.mp3").path)
        try Data([44, 55, 66]).write(to: URL(fileURLWithPath: file.path))
        try fixture.save(paths: [file.path, sibling.path])
        _ = try await fixture.reconcile()
        let result = try await fixture.row(file)
        let unaffected = try await fixture.row(sibling)
        XCTAssertEqual(result.id, file.id)
        XCTAssertNil(result.trackId)
        XCTAssertNil(result.chromaprintFingerprint)
        XCTAssertNil(result.artist)
        XCTAssertEqual(result.fingerprintStatus, .pending)
        XCTAssertEqual(result.membershipRevision, 1)
        XCTAssertEqual(unaffected.trackId, 71)
        let events = try await fixture.database.writer.read { connection in try EventRecord.fetchAll(connection) }
        XCTAssertTrue(events.contains { event in event.inversePayloadJson.contains("old-recording") || event.inversePayloadJson.contains("Old Artist") })
    }

    func testVerifiedSavedMoveKeepsIdentityAndDuplicateHardLinkIsAmbiguous() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("old.mp3")
        let destination = fixture.directory.appendingPathComponent("new.mp3").path
        try FileManager.default.moveItem(atPath: file.path, toPath: destination)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: destination)
        try fixture.save(paths: [destination])
        _ = try await fixture.reconcile()
        let moved = try await fixture.row(file)
        XCTAssertEqual(moved.path, destination)
        XCTAssertEqual(moved.inode, file.inode)
        XCTAssertEqual(moved.libraryMembership, .active)
        let link = fixture.directory.appendingPathComponent("link.mp3").path
        try FileManager.default.linkItem(atPath: destination, toPath: link)
        try fixture.save(paths: [destination, link])
        do { _ = try await fixture.reconcile(); XCTFail("hard-link association guessed") } catch {}
    }

    func testUnsupportedOwnerAndOfflineVolumeDoNotRetire() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let unsupported = try await fixture.add("unsupported.mp3")
        let offline = try await fixture.add("offline.mp3")
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET serato_library_id = 'other-library' WHERE id = ?", arguments: [unsupported.id])
            try connection.execute(sql: "UPDATE files SET volume_uuid = 'unmounted-volume' WHERE id = ?", arguments: [offline.id])
        }
        let summary = try await fixture.reconcile()
        XCTAssertEqual(summary.retired, 0)
        XCTAssertEqual(summary.skippedUnsupported, 2)
    }

    func testAbsentMembersRetireWithoutChangingAudioAndRepeatedSnapshotIsNoop() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let presentAudio = try await fixture.add("present.mp3")
        let missingAudio = try await fixture.add("missing.mp3")
        try FileManager.default.removeItem(atPath: missingAudio.path)
        let summary = try await fixture.reconcile()
        XCTAssertEqual(summary.retired, 2)
        let present = try await fixture.row(presentAudio)
        let missing = try await fixture.row(missingAudio)
        XCTAssertEqual(present.libraryMembership, .retired)
        XCTAssertEqual(missing.libraryMembership, .retired)
        XCTAssertEqual(missing.fileAvailability, .missing)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: present.path)), Data([1, 2, 3, 4]))
        let count = try await fixture.events()
        _ = try await fixture.reconcile()
        let repeatedCount = try await fixture.events()
        XCTAssertEqual(count, repeatedCount)
    }

    func testReferencedMissingLegacyMemberIsActiveAndCrateAbsenceIsIrrelevant() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("legacy.mp3", membership: .legacyUnverified)
        try fixture.save(paths: [String(file.path.dropFirst())])
        try FileManager.default.removeItem(atPath: file.path)
        _ = try await fixture.reconcile()
        let result = try await fixture.row(file)
        XCTAssertEqual(result.libraryMembership, .active)
        XCTAssertEqual(result.fileAvailability, .missing)
        XCTAssertNotNil(result.seratoLibraryId)
    }

    func testPendingImportSurvivesAbsence() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("pending.mp3", membership: .pendingImport)
        _ = try await fixture.reconcile()
        let result = try await fixture.row(file)
        XCTAssertEqual(result.libraryMembership, .pendingImport)
    }

    func testRestoreAloneStaysRetiredAndSavedReaddReactivatesOnce() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("restored.mp3")
        _ = try await fixture.reconcile()
        _ = try await fixture.reconcile()
        let retired = try await fixture.row(file)
        XCTAssertEqual(retired.libraryMembership, .retired)
        try fixture.save(paths: [file.path])
        let summary = try await fixture.reconcile()
        XCTAssertEqual(summary.reactivated, 1)
        let active = try await fixture.row(file)
        XCTAssertEqual(active.libraryMembership, .active)
        let next = try await fixture.reconcile()
        XCTAssertEqual(next.reactivated, 0)
    }

    func testOlderGenerationAndChangedSourceAreRejected() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await fixture.add("safe.mp3")
        let old = try await fixture.reader.read()
        _ = try await fixture.reader.read()
        do { _ = try await fixture.reconciler.reconcile(old); XCTFail("stale snapshot accepted") } catch {}
        let latest = try await fixture.reader.read()
        try fixture.save(paths: [file.path])
        do { _ = try await fixture.reconciler.reconcile(latest); XCTFail("changed source accepted") } catch {}
        let unchanged = try await fixture.row(file)
        XCTAssertEqual(unchanged.libraryMembership, .active)
    }
}
