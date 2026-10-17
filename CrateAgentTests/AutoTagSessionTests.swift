import Combine
@testable import CrateAgent
import CryptoKit
import GRDB
import SwiftUI
import XCTest

@MainActor
final class AutoTagSessionTests: XCTestCase {
    func testApplyKeepsOriginalTokenAcrossFreshnessSuspensionAndReactivation() async throws {
        let started = expectation(description: "apply freshness suspended")
        let freshness = SessionFreshnessSuspension(started: started)
        let fixture = try SessionFixture(fileCount: 1, fileFreshnessReader: { freshness.read($0) })
        let recorded = SessionTokenRecorder()
        let engine = OperationEngine(database: fixture.database,
                                     seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }),
                                     seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")),
                                     fileTagWriter: { _, _ in })
        let session = AutoTagSession(database: fixture.database, lookupService: fixture.service, applyBatch: { mutations, batchID, tokens in
            await recorded.record(tokens)
            _ = try await engine.applyBatch(mutations, batchId: batchID, expectedMembershipTokens: tokens)
        }, resyncBatch: { _ in ResyncOutcome(appliedCount: 0, queuedCount: 0) }, preferences: nil)
        session.selectVisibleFileIDs(fixture.fileIDs)
        await session.startScan()
        session.approveAllSuggested()
        freshness.arm()
        let apply = Task { await session.applyConfirmed() }
        await fulfillment(of: [started], timeout: 5)
        let fileID = fixture.fileIDs[0]
        _ = try await engine.apply(.setFileLibraryState(.init(fileId: fileID, expectedRevision: 0, state: .init(membership: .retired, availability: .available, libraryID: nil, retiredAt: 1))))
        _ = try await engine.apply(.setFileLibraryState(.init(fileId: fileID, expectedRevision: 1, state: .init(membership: .active, availability: .available, libraryID: nil, retiredAt: nil))))
        freshness.release()
        await apply.value
        let tokens = await recorded.tokens
        XCTAssertEqual(tokens, [fileID: FileMembershipToken(fileId: fileID, revision: 0)])
        XCTAssertTrue(session.appliedFileIDs.isEmpty)
        XCTAssertTrue(session.actionError?.contains("superseded") == true)
        let file = try await fixture.database.writer.read { try XCTUnwrap(FileRecord.fetchOne($0, key: fileID)) }
        XCTAssertEqual(file.membershipRevision, 2)
        XCTAssertNil(file.artist)
        let matchCount = try await fixture.database.writer.read { try EventRecord.filter(Column("event_type") == EventType.musicBrainzMatchApplied.rawValue).fetchCount($0) }
        XCTAssertEqual(matchCount, 0)
    }

    func testRetiredChoicesStayInspectableButCannotBeApprovedAfterReactivation() async throws {
        let fixture = try SessionFixture(fileCount: 2)
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        await fixture.session.startScan()
        fixture.session.approveAllSuggested()
        let retiredID = fixture.fileIDs[0]
        let original = fixture.session.rowModels[retiredID]
        try await fixture.database.writer.write { database in
            try database.execute(sql: "UPDATE files SET library_membership = 'retired', membership_revision = 1 WHERE id = ?", arguments: [retiredID])
        }
        fixture.session.approveAllSuggested()
        XCTAssertFalse(fixture.session.canApprove(fileID: retiredID))
        XCTAssertEqual(fixture.session.rowModels[retiredID]?.candidate, original?.candidate)
        XCTAssertNotNil(fixture.session.processingErrorByFileID[retiredID])
        XCTAssertEqual(fixture.session.confirmedFileIDs, [fixture.fileIDs[1]])
        try await fixture.database.writer.write { database in
            try database.execute(sql: "UPDATE files SET library_membership = 'active', membership_revision = 2 WHERE id = ?", arguments: [retiredID])
        }
        fixture.session.setApproved(true, for: retiredID)
        XCTAssertFalse(fixture.session.canApprove(fileID: retiredID))
        XCTAssertEqual(fixture.session.rowModels[retiredID]?.candidate, original?.candidate)
        XCTAssertTrue(fixture.session.processingErrorByFileID[retiredID]?.contains("superseded") == true)
    }

    func testSuccessfulResyncWithNoRemainingWritesReleasesRecoveryLock() async throws {
        let noWrites = ResyncOutcome(appliedCount: 0, queuedCount: 0)
        let fixture = try SessionFixture(fileCount: 1, apply: { _, batchID in
            throw OperationEngineError.externalSyncIncomplete(batchId: batchID, underlying: "fixture failure")
        }, resync: { _ in noWrites })
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        await fixture.session.startScan()
        fixture.session.approveAllSuggested()
        await fixture.session.applyConfirmed()
        XCTAssertNotNil(fixture.session.pendingResyncBatchId)
        XCTAssertFalse(fixture.session.reset())
        await fixture.session.resyncPartialApply()
        XCTAssertNil(fixture.session.pendingResyncBatchId)
        XCTAssertEqual(fixture.session.lastResult, noWrites.summaryMessage)
        XCTAssertTrue(fixture.session.reset())
        XCTAssertTrue(fixture.session.rowModels.isEmpty)
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        await fixture.session.startScan()
        XCTAssertEqual(fixture.session.rowModels.count, 1)
        XCTAssertTrue(fixture.session.appliedFileIDs.isEmpty)
    }

    func testOnlyDisplayPreferenceIsRestoredIntoANewSession() throws {
        let suiteName = "AutoTagSessionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let fixture = try SessionFixture(fileCount: 1)
        let first = AutoTagSession(database: fixture.database, lookupService: fixture.service,
                                   applyBatch: { _, _, _ in }, resyncBatch: { _ in ResyncOutcome(appliedCount: 0, queuedCount: 0) }, preferences: preferences)
        first.reviewMode = .focus
        first.selectionMode = .search
        first.selectVisibleFileIDs(fixture.fileIDs)
        let recreated = AutoTagSession(database: fixture.database, lookupService: fixture.service,
                                       applyBatch: { _, _, _ in }, resyncBatch: { _ in ResyncOutcome(appliedCount: 0, queuedCount: 0) }, preferences: preferences)
        XCTAssertEqual(recreated.reviewMode, .focus)
        XCTAssertEqual(recreated.selectionMode, .browse)
        XCTAssertTrue(recreated.selectedFileIDs.isEmpty)
        XCTAssertTrue(recreated.rowModels.isEmpty)
    }

    func testMountedNewScanReloadsFirstBrowsePageWithoutAutomaticSelection() async throws {
        let fixture = try SessionFixture(fileCount: 201)
        fixture.session.selectVisibleFileIDs([fixture.fileIDs[0]])
        await fixture.session.startScan()
        await fixture.session.loadBrowsePage(1)
        let mounted = expectation(description: "Review mounted")
        let hosting = NSHostingView(rootView: AutoTaggerView(session: fixture.session)
            .environmentObject(SeratoWatchdog(runningBundleIdentifiersProvider: { [] }))
            .onAppear { mounted.fulfill() })
        hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 760)
        hosting.layoutSubtreeIfNeeded()
        await fulfillment(of: [mounted], timeout: 3)
        let reloaded = expectation(description: "New Scan browses the first page")
        let observer = fixture.session.$browseResults.filter { $0.matches.count == 200 && $0.page == 0 }.prefix(1).sink { _ in reloaded.fulfill() }
        XCTAssertTrue(fixture.session.reset())
        hosting.layoutSubtreeIfNeeded()
        await fulfillment(of: [reloaded], timeout: 3)
        XCTAssertTrue(fixture.session.selectedFileIDs.isEmpty)
        XCTAssertTrue(fixture.session.rowModels.isEmpty)
        withExtendedLifetime(observer) {}
    }

    func testArtistTitleMatchIsExcludedFromBulkApprovalButAppliesWithoutAcoustIDOnceApprovedIndividually() async throws {
        let applied = PayloadRecorder()
        let fixture = try SessionFixture(fileCount: 1, onlyMetadataMatches: true, apply: { mutations, _ in await applied.record(mutations) })
        let fileID = fixture.fileIDs[0]
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        await fixture.session.startScan()
        XCTAssertEqual(fixture.session.rowModels[fileID]?.candidate.evidence.isMetadataSearch, true)
        fixture.session.approveAllSuggested()
        fixture.session.approveAllReady()
        XCTAssertTrue(fixture.session.confirmedFileIDs.isEmpty, "Text matches carry no audio evidence")
        fixture.session.setApproved(true, for: fileID)
        await fixture.session.applyConfirmed()
        let payloads = await applied.payloads
        XCTAssertEqual(payloads.map(\.recordingMBID), ["text-match"])
        XCTAssertEqual(payloads.map(\.acoustID), [nil])
    }

    func testFocusSkipsNoMatchOnFirstEntryAndDoesNotJumpAsPendingRowsResolve() async throws {
        let unmatched = try SessionFixture(fileCount: 2, firstLookupHasNoMatch: true)
        unmatched.session.selectVisibleFileIDs(unmatched.fileIDs)
        await unmatched.session.startScan()
        unmatched.session.reviewMode = .focus
        XCTAssertEqual(unmatched.session.focusedFileID, unmatched.fileIDs[1])
        let started = SessionGate()
        let release = SessionGate()
        let pending = try SessionFixture(fileCount: 2, blockedRecordingID: "recording-1", started: started, release: release)
        pending.session.selectVisibleFileIDs(pending.fileIDs)
        let scan = Task { await pending.session.startScan() }
        await started.wait()
        pending.session.reviewMode = .focus
        XCTAssertEqual(pending.session.focusedFileID, pending.fileIDs[0])
        await release.open()
        await scan.value
        XCTAssertEqual(pending.session.focusedFileID, pending.fileIDs[0])
    }

    func testLowerScoredManualRecordingDoesNotInheritOriginalBulkEligibility() async throws {
        let fixture = try SessionFixture(fileCount: 1, lowScoreAlternative: true)
        let fileID = fixture.fileIDs[0]
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        await fixture.session.startScan()
        fixture.session.approveAllSuggested()
        XCTAssertTrue(fixture.session.confirmedFileIDs.contains(fileID))
        await fixture.session.selectRecording(fileID: fileID, recordingID: "alternative-b")
        fixture.session.approveAllSuggested()
        XCTAssertFalse(fixture.session.confirmedFileIDs.contains(fileID))
        XCTAssertEqual(fixture.session.matchAssessment(for: fileID)?.score, 0.4)
        fixture.session.setApproved(true, for: fileID)
        XCTAssertTrue(fixture.session.confirmedFileIDs.contains(fileID), "Manual approval remains available")
    }

    func testApplySkipsDeletedFileAndKeepsFreshMutationsInScanOrder() async throws {
        let started = SessionGate()
        let release = SessionGate()
        await release.open()
        let recorder = SessionApplyRecorder(started: started, release: release, failExternally: false)
        let fixture = try SessionFixture(fileCount: 3, apply: { mutations, batchID in try await recorder.apply(mutations, batchID: batchID) })
        fixture.session.selectVisibleFileIDs(fixture.fileIDs.reversed())
        await fixture.session.startScan()
        fixture.session.approveAllSuggested()
        let deletedID = fixture.fileIDs[1]
        _ = try await fixture.database.writer.write { database in try FileRecord.deleteOne(database, key: deletedID) }
        await fixture.session.applyConfirmed()
        let applied = await recorder.fileIDsByBatch
        XCTAssertEqual(applied, [[fixture.fileIDs[0], fixture.fileIDs[2]]])
        XCTAssertTrue(fixture.session.confirmedFileIDs.isEmpty)
        XCTAssertEqual(fixture.session.appliedFileIDs, [fixture.fileIDs[0], fixture.fileIDs[2]])
        XCTAssertTrue(fixture.session.lastResult?.contains("Skipped 1") == true)
    }

    func testApplyExcludesOnlyFingerprintCollisionsAndAppliesCleanRows() async throws {
        let started = SessionGate()
        let release = SessionGate()
        await release.open()
        let recorder = SessionApplyRecorder(started: started, release: release, failExternally: false)
        let fixture = try SessionFixture(fileCount: 3, apply: { mutations, batchID in try await recorder.apply(mutations, batchID: batchID) })
        let colliding = fixture.fileIDs[1]
        try await fixture.database.writer.write { database in
            var track = TrackRecord(fingerprintHash: Data(SHA256.hash(data: FingerprintEncoder.serialize([2]))), musicbrainzRecordingId: "already-linked")
            try track.insert(database)
            var dependent = FileRecord(path: "/fixture/dependent.mp3", volumeUuid: "TEST", inode: 99, fileSize: 1000, mtime: 10)
            dependent.trackId = track.id
            try dependent.insert(database)
        }
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        await fixture.session.startScan()
        fixture.session.approveAllSuggested()
        await fixture.session.applyConfirmed()
        let applied = await recorder.fileIDsByBatch
        XCTAssertEqual(applied, [[fixture.fileIDs[0], fixture.fileIDs[2]]])
        XCTAssertEqual(fixture.session.confirmedFileIDs, [colliding])
        XCTAssertTrue(fixture.session.lastResult?.contains("Skipped 1 file(s) whose fingerprint is already linked") == true,
                      fixture.session.lastResult ?? "no result")
    }

    func testActualPresentationCanBeRemovedAndRecreatedDuringScan() async throws {
        let started = SessionGate()
        let release = SessionGate()
        let fixture = try SessionFixture(fileCount: 2, blockedRecordingID: "recording-2", started: started, release: release)
        let watchdog = SeratoWatchdog(runningBundleIdentifiersProvider: { [] })
        let appeared = expectation(description: "Auto-Tag mounted")
        let disappeared = expectation(description: "Auto-Tag removed")
        let hosting = NSHostingView(rootView: AnyView(AutoTaggerView(session: fixture.session)
                .environmentObject(watchdog).onAppear { appeared.fulfill() }.onDisappear { disappeared.fulfill() }))
        hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 760)
        hosting.layoutSubtreeIfNeeded()
        await fulfillment(of: [appeared], timeout: 3)
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        let scan = Task { await fixture.session.startScan() }
        await started.wait()
        let fileID = fixture.fileIDs[0]
        var model = try XCTUnwrap(fixture.session.rowModels[fileID])
        model.includeArtist = false
        fixture.session.updateReviewModel(model, for: fileID)
        fixture.session.setApproved(true, for: fileID)
        hosting.rootView = AnyView(Text("Another destination"))
        hosting.layoutSubtreeIfNeeded()
        await fulfillment(of: [disappeared], timeout: 3)
        await release.open()
        await scan.value
        let remounted = expectation(description: "Auto-Tag recreated")
        hosting.rootView = AnyView(AutoTaggerView(session: fixture.session).environmentObject(watchdog).onAppear { remounted.fulfill() })
        hosting.layoutSubtreeIfNeeded()
        await fulfillment(of: [remounted], timeout: 3)
        XCTAssertEqual(fixture.session.rowModels.count, 2)
        XCTAssertFalse(try XCTUnwrap(fixture.session.rowModels[fileID]).includeArtist)
        XCTAssertTrue(fixture.session.confirmedFileIDs.contains(fileID))
        XCTAssertFalse(fixture.session.isScanning)
    }

    func testResetInvalidatesQueuedBrowseAndSearchReads() async throws {
        let fixture = try SessionFixture(fileCount: 201)
        let writerStarted = expectation(description: "Database queue held")
        let writerRelease = DispatchSemaphore(value: 0)
        let blocker = Task {
            try await fixture.database.writer.write { _ in
                writerStarted.fulfill()
                XCTAssertEqual(writerRelease.wait(timeout: .now() + 5), .success)
            }
        }
        await fulfillment(of: [writerStarted], timeout: 3)
        let browsing = Task { await fixture.session.loadBrowsePage(1) }
        fixture.session.updateSearchQuery("track-201")
        let searching = Task { await fixture.session.performSearch() }
        let queued = expectation(description: "Read requests queued")
        Task { queued.fulfill() }
        await fulfillment(of: [queued], timeout: 3)
        XCTAssertTrue(fixture.session.isBrowsing)
        fixture.session.setBrowseFilter(.missingMetadata)
        XCTAssertTrue(fixture.session.reset())
        writerRelease.signal()
        try await blocker.value
        await browsing.value
        await searching.value
        XCTAssertTrue(fixture.session.browseResults.matches.isEmpty)
        XCTAssertEqual(fixture.session.searchState.query, "")
        XCTAssertTrue(fixture.session.searchState.results.matches.isEmpty)
        XCTAssertFalse(fixture.session.isBrowsing)
    }

    func testEnteringFocusChoosesFirstUnapprovedReadyRowAndKeepsExplicitFocus() async throws {
        let fixture = try SessionFixture(fileCount: 2)
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        await fixture.session.startScan()
        fixture.session.setApproved(true, for: fixture.fileIDs[0])
        fixture.session.reviewMode = .focus
        XCTAssertEqual(fixture.session.focusedFileID, fixture.fileIDs[1])
        fixture.session.focus(fixture.fileIDs[0])
        fixture.session.reviewMode = .list
        fixture.session.reviewMode = .focus
        XCTAssertEqual(fixture.session.focusedFileID, fixture.fileIDs[0])
    }

    func testSelectionReadFailureIsVisibleAndLeavesNoUnfinishedReview() async throws {
        let fixture = try SessionFixture(fileCount: 1)
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        try await fixture.database.writer.write { database in try database.execute(sql: "DROP TABLE files") }
        await fixture.session.startScan()
        XCTAssertNotNil(fixture.session.actionError)
        XCTAssertFalse(fixture.session.isScanning)
        XCTAssertTrue(fixture.session.scannedFileIDs.isEmpty)
    }

    func testSessionBuildsModelsFromPublishedRowsAndOnlyChangedDecisionsClearApproval() async throws {
        let fixture = try SessionFixture(fileCount: 2)
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        await fixture.session.startScan()
        XCTAssertEqual(fixture.session.scannedFileIDs, fixture.fileIDs)
        XCTAssertEqual(fixture.session.rowModels.count, 2)
        let fileID = fixture.fileIDs[0]
        var model = try XCTUnwrap(fixture.session.rowModels[fileID])
        fixture.session.setApproved(true, for: fileID)
        fixture.session.updateReviewModel(model, for: fileID)
        XCTAssertTrue(fixture.session.confirmedFileIDs.contains(fileID))
        model.includeArtist = false
        fixture.session.updateReviewModel(model, for: fileID)
        XCTAssertFalse(fixture.session.confirmedFileIDs.contains(fileID))
        fixture.session.setApproved(true, for: fileID)
        model.selectRelease(model.candidate.availableReleases[1])
        fixture.session.updateReviewModel(model, for: fileID)
        XCTAssertFalse(fixture.session.confirmedFileIDs.contains(fileID))
    }

    func testObserverDetachmentAndCallerCancellationDoNotStopOwnedScanOrLoseEdits() async throws {
        let started = SessionGate()
        let release = SessionGate()
        let fixture = try SessionFixture(fileCount: 2, blockedRecordingID: "recording-2", started: started, release: release)
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        var observer: AnyCancellable? = fixture.session.objectWillChange.sink {}
        let caller = Task { await fixture.session.startScan() }
        await started.wait()
        let firstID = fixture.fileIDs[0]
        var model = try XCTUnwrap(fixture.session.rowModels[firstID])
        model.includeAlbum = false
        fixture.session.updateReviewModel(model, for: firstID)
        fixture.session.setApproved(true, for: firstID)
        fixture.session.focus(firstID)
        observer = nil
        caller.cancel()
        await release.open()
        await caller.value
        observer = fixture.session.objectWillChange.sink {}
        XCTAssertEqual(fixture.session.rowModels.count, 2)
        XCTAssertEqual(fixture.session.rowModels[firstID]?.includeAlbum, false)
        XCTAssertTrue(fixture.session.confirmedFileIDs.contains(firstID))
        XCTAssertEqual(fixture.session.focusedFileID, firstID)
        XCTAssertFalse(fixture.session.isScanning)
        let requestCount = await fixture.loader.lookupCount
        XCTAssertEqual(requestCount, 2)
        withExtendedLifetime(observer) {}
    }

    func testStopPreservesFinishedRowsAndResetRejectsLateResults() async throws {
        for reset in [false, true] {
            let started = SessionGate()
            let release = SessionGate()
            let fixture = try SessionFixture(fileCount: 2, blockedRecordingID: "recording-2", started: started, release: release)
            fixture.session.selectVisibleFileIDs(fixture.fileIDs)
            let caller = Task { await fixture.session.startScan() }
            await started.wait()
            if reset {
                fixture.session.reset()
            } else {
                fixture.session.stopScan()
            }
            await release.open()
            await caller.value
            XCTAssertFalse(fixture.session.isScanning)
            if reset {
                XCTAssertTrue(fixture.session.rowModels.isEmpty)
                XCTAssertTrue(fixture.session.scannedFileIDs.isEmpty)
                XCTAssertTrue(fixture.service.rows.isEmpty)
                XCTAssertTrue(fixture.service.recordingAlternatives.isEmpty)
            } else {
                XCTAssertEqual(fixture.session.rowModels.count, 1)
                guard case .stopped = fixture.session.rows[fixture.fileIDs[1]] else { return XCTFail("Unfinished row must be stopped") }
            }
        }
    }

    func testFocusAdvancesToUnapprovedMatchesAndWrapsWithoutApplying() async throws {
        let fixture = try SessionFixture(fileCount: 3)
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        await fixture.session.startScan()
        fixture.session.reviewMode = .focus
        XCTAssertEqual(fixture.session.focusedFileID, fixture.fileIDs[0])
        fixture.session.approveAndAdvance()
        XCTAssertEqual(fixture.session.focusedFileID, fixture.fileIDs[1])
        fixture.session.focus(fixture.fileIDs[2])
        fixture.session.approveAndAdvance()
        XCTAssertEqual(fixture.session.focusedFileID, fixture.fileIDs[1])
        fixture.session.approveAndAdvance()
        XCTAssertEqual(fixture.session.focusedFileID, fixture.fileIDs[1])
        XCTAssertNotNil(fixture.session.focusNotice)
        XCTAssertTrue(fixture.session.appliedFileIDs.isEmpty)
        fixture.session.reviewMode = .list
        fixture.session.reviewMode = .focus
        XCTAssertEqual(fixture.session.confirmedFileIDs.count, 3)
        fixture.session.previous()
        XCTAssertEqual(fixture.session.focusedFileID, fixture.fileIDs[0])
    }

    func testPendingApplyFreezesDecisionsAndPartialCompletionKeepsRecovery() async throws {
        let started = SessionGate()
        let release = SessionGate()
        let recorder = SessionApplyRecorder(started: started, release: release, failExternally: true)
        let fixture = try SessionFixture(fileCount: 2, apply: { mutations, batchID in
            try await recorder.apply(mutations, batchID: batchID)
        }, resync: { _ in ResyncOutcome(appliedCount: 0, queuedCount: 2) })
        fixture.session.selectVisibleFileIDs(fixture.fileIDs.reversed())
        await fixture.session.startScan()
        for fileID in fixture.fileIDs {
            fixture.session.setApproved(true, for: fileID)
        }
        let original = try XCTUnwrap(fixture.session.rowModels[fixture.fileIDs[0]])
        let applying = Task { await fixture.session.applyConfirmed() }
        await started.wait()
        var changed = original
        changed.includeArtist.toggle()
        fixture.session.updateReviewModel(changed, for: fixture.fileIDs[0])
        fixture.session.setApproved(false, for: fixture.fileIDs[0])
        fixture.session.reset()
        await fixture.session.applyConfirmed()
        XCTAssertEqual(fixture.session.rowModels[fixture.fileIDs[0]]?.includeArtist, original.includeArtist)
        XCTAssertEqual(fixture.session.confirmedFileIDs.count, 2)
        await release.open()
        await applying.value
        XCTAssertFalse(fixture.session.isApplying)
        XCTAssertEqual(fixture.session.appliedFileIDs, Set(fixture.fileIDs))
        XCTAssertTrue(fixture.session.confirmedFileIDs.isEmpty)
        XCTAssertNotNil(fixture.session.pendingResyncBatchId)
        XCTAssertNotNil(fixture.session.actionError)
        let appliedBatches = await recorder.fileIDsByBatch
        XCTAssertEqual(appliedBatches, [fixture.fileIDs], "Payloads retain deterministic scan order and apply only once")
        fixture.session.reset()
        XCTAssertNotNil(fixture.session.pendingResyncBatchId)
        await fixture.session.resyncPartialApply()
        XCTAssertNotNil(fixture.session.pendingResyncBatchId, "Queued recovery must remain accessible")
    }

    func testNewerRecordingChoiceWinsAndSameCanonicalOrFailurePreservesDecisions() async throws {
        let started = SessionGate()
        let release = SessionGate()
        let fixture = try SessionFixture(fileCount: 1, alternatives: true, blockedRecordingID: "alternative-a", started: started, release: release)
        let fileID = fixture.fileIDs[0]
        fixture.session.selectVisibleFileIDs([fileID])
        await fixture.session.startScan()
        var original = try XCTUnwrap(fixture.session.rowModels[fileID])
        original.includeAlbum = false
        fixture.session.updateReviewModel(original, for: fileID)
        fixture.session.setApproved(true, for: fileID)
        await fixture.session.selectRecording(fileID: fileID, recordingID: "same-recording")
        XCTAssertEqual(fixture.session.rowModels[fileID]?.includeAlbum, false)
        XCTAssertTrue(fixture.session.confirmedFileIDs.contains(fileID))
        await fixture.session.selectRecording(fileID: fileID, recordingID: "no-release")
        XCTAssertEqual(fixture.session.rowModels[fileID]?.candidate.recordingMBID, "recording-1")
        XCTAssertTrue(fixture.session.confirmedFileIDs.contains(fileID))
        XCTAssertNotNil(fixture.session.selectionErrorByFileID[fileID])
        let oldChoice = Task { await fixture.session.selectRecording(fileID: fileID, recordingID: "alternative-a") }
        await started.wait()
        XCTAssertTrue(fixture.session.pendingRecordingFileIDs.contains(fileID))
        fixture.session.setApproved(false, for: fileID)
        XCTAssertTrue(fixture.session.confirmedFileIDs.contains(fileID), "Pending switches freeze approval without discarding it")
        await fixture.session.selectRecording(fileID: fileID, recordingID: "alternative-b")
        await release.open()
        await oldChoice.value
        XCTAssertEqual(fixture.session.rowModels[fileID]?.candidate.recordingMBID, "alternative-b")
        XCTAssertTrue(fixture.session.pendingRecordingFileIDs.isEmpty)
        XCTAssertFalse(fixture.session.confirmedFileIDs.contains(fileID))
    }

    func testBrowsePagesAndSearchKeepOnlyExplicitSelections() async throws {
        let fixture = try SessionFixture(fileCount: 201)
        await fixture.session.loadBrowsePage(0)
        XCTAssertEqual(fixture.session.browseResults.matches.count, 200)
        XCTAssertTrue(fixture.session.selectedFileIDs.isEmpty)
        fixture.session.selectVisibleFileIDs(fixture.session.browseResults.matches.map(\.id))
        await fixture.session.loadBrowsePage(1)
        XCTAssertEqual(fixture.session.browseResults.matches.count, 1)
        fixture.session.selectVisibleFileIDs(fixture.session.browseResults.matches.map(\.id))
        fixture.session.updateSearchQuery("track-201")
        await fixture.session.performSearch()
        XCTAssertEqual(fixture.session.searchState.results.matches.map(\.id), [fixture.fileIDs[200]])
        XCTAssertEqual(fixture.session.selectedFileIDs.count, 201)
        fixture.session.setVisibleFileIDs([fixture.fileIDs[200]], selected: false)
        XCTAssertEqual(fixture.session.selectedFileIDs.count, 200)
        fixture.session.selectionMode = .search
        fixture.session.updateSearchQuery("track-")
        await fixture.session.loadSelectionPage(1)
        XCTAssertEqual(fixture.session.searchState.results.matches.count, 1)
        XCTAssertEqual(fixture.session.searchState.results.totalMatchCount, 201)
        XCTAssertEqual(fixture.session.selectedFileIDs.count, 200)
        fixture.session.clearSelection()
        XCTAssertTrue(fixture.session.selectedFileIDs.isEmpty)

        let lookups = await fixture.loader.lookupCount
        XCTAssertEqual(lookups, 0, "Opening and selecting browser pages never starts audio lookup")
    }

    func testReplacedSelectionRequiresExplicitReselectionFromCurrentView() async throws {
        let fixture = try SessionFixture(fileCount: 2)
        fixture.session.updateSearchQuery("track-")
        await fixture.session.performSearch()
        await fixture.session.loadBrowsePage()
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        let changedID = fixture.fileIDs[0]
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET membership_revision = membership_revision + 1 WHERE id = ?", arguments: [changedID])
        }
        await fixture.session.loadBrowsePage()
        XCTAssertEqual(fixture.session.selectedFileIDs, [fixture.fileIDs[1]])
        XCTAssertNotNil(fixture.session.selectionNotice)
        fixture.session.selectVisibleFileIDs([changedID])
        await fixture.session.startScan()
        XCTAssertEqual(fixture.session.scannedFileIDs, fixture.fileIDs)
    }

    func testChoosingCurrentRecordingCancelsAnOlderPendingSwitch() async throws {
        let started = SessionGate()
        let release = SessionGate()
        let fixture = try SessionFixture(fileCount: 1, alternatives: true, blockedRecordingID: "alternative-a", started: started, release: release)
        let fileID = fixture.fileIDs[0]
        fixture.session.selectVisibleFileIDs([fileID])
        await fixture.session.startScan()
        fixture.session.setApproved(true, for: fileID)
        let oldChoice = Task { await fixture.session.selectRecording(fileID: fileID, recordingID: "alternative-a") }
        await started.wait()
        await fixture.session.selectRecording(fileID: fileID, recordingID: "recording-1")
        await release.open()
        await oldChoice.value
        XCTAssertEqual(fixture.session.rowModels[fileID]?.candidate.recordingMBID, "recording-1")
        XCTAssertTrue(fixture.session.confirmedFileIDs.contains(fileID))
        XCTAssertTrue(fixture.session.pendingRecordingFileIDs.isEmpty)
    }

    func testApplyRefusesApprovedPendingChoiceAndFreezesOtherPendingChoices() async throws {
        let selectionStarted = SessionGate()
        let releaseSelection = SessionGate()
        let applyStarted = SessionGate()
        let releaseApply = SessionGate()
        let recorder = SessionApplyRecorder(started: applyStarted, release: releaseApply, failExternally: false)
        let fixture = try SessionFixture(fileCount: 2, alternatives: true, blockedRecordingID: "alternative-a",
                                         started: selectionStarted, release: releaseSelection,
                                         apply: { mutations, batchID in try await recorder.apply(mutations, batchID: batchID) })
        fixture.session.selectVisibleFileIDs(fixture.fileIDs)
        await fixture.session.startScan()
        let firstID = fixture.fileIDs[0]
        fixture.session.setApproved(true, for: firstID)
        let pending = Task { await fixture.session.selectRecording(fileID: firstID, recordingID: "alternative-a") }
        await selectionStarted.wait()
        await fixture.session.applyConfirmed()
        XCTAssertNotNil(fixture.session.actionError)
        let blockedBatches = await recorder.fileIDsByBatch
        XCTAssertTrue(blockedBatches.isEmpty)
        await fixture.session.selectRecording(fileID: firstID, recordingID: "recording-1")
        fixture.session.setApproved(false, for: firstID)
        let secondPending = Task { await fixture.session.selectRecording(fileID: firstID, recordingID: "alternative-a") }
        fixture.session.setApproved(true, for: fixture.fileIDs[1])
        let applying = Task { await fixture.session.applyConfirmed() }
        await applyStarted.wait()
        await releaseSelection.open()
        await pending.value
        await secondPending.value
        XCTAssertEqual(fixture.session.rowModels[firstID]?.candidate.recordingMBID, "recording-1")
        await releaseApply.open()
        await applying.value
        XCTAssertEqual(fixture.session.appliedFileIDs, [fixture.fileIDs[1]])
        XCTAssertNotNil(fixture.session.rowModels[fixture.fileIDs[1]], "Applied entries remain inspectable and read-only")
    }
}

@MainActor
private struct SessionFixture {
    let database: LibraryDatabase
    let fileIDs: [Int64]
    let loader: SessionLookupLoader
    let service: AutoTaggerService
    let session: AutoTagSession

    init(fileCount: Int, alternatives: Bool = false, firstLookupHasNoMatch: Bool = false, lowScoreAlternative: Bool = false, onlyMetadataMatches: Bool = false,
         blockedRecordingID: String? = nil,
         started: SessionGate = SessionGate(), release: SessionGate = SessionGate(),
         fileFreshnessReader: @escaping FileFreshnessReading = { _ in FileFreshnessSnapshot(fileSize: 1000, mtime: 10) },
         apply: @escaping @Sendable ([TrackMutation], String) async throws -> Void = { _, _ in },
         resync: @escaping @Sendable (String) async throws -> ResyncOutcome = { _ in ResyncOutcome(appliedCount: 1, queuedCount: 0) }) throws
    {
        database = try LibraryDatabase.openInMemory()
        var inserted: [Int64] = []
        try database.writer.write { database in
            for index in 1 ... fileCount {
                var file = FileRecord(path: "/fixture/track-\(index).mp3", volumeUuid: "TEST", inode: Int64(index), fileSize: 1000, mtime: 10,
                                      chromaprintFingerprint: FingerprintEncoder.serialize([UInt32(index)]), fingerprintStatus: .done)
                file.libraryMembership = .active
                file.fileAvailability = .available
                try file.insert(database)
                try inserted.append(XCTUnwrap(file.id))
            }
        }
        fileIDs = inserted
        loader = SessionLookupLoader(alternatives: alternatives, firstLookupHasNoMatch: firstLookupHasNoMatch, lowScoreAlternative: lowScoreAlternative,
                                     onlyMetadataMatches: onlyMetadataMatches, blockedRecordingID: blockedRecordingID, started: started, release: release)
        service = AutoTaggerService(database: database,
                                    acoustIDClient: AcoustIDClient(loader: loader, limiter: .noop, cache: .memory()),
                                    musicBrainzClient: MusicBrainzClient(loader: loader, limiter: .noop, cache: .memory()),
                                    keyStore: SessionTestKey(), audioTagsReader: { _ in
                                        AudioTags(bitrateKbps: nil, title: "Current title", artist: "Current artist", album: "Current album", albumArtist: nil,
                                                  genre: nil, year: 1990, trackNumber: nil, totalTracks: nil, bpm: nil, comment: nil, durationSeconds: 200)
                                    }, fileFreshnessReader: fileFreshnessReader)
        session = AutoTagSession(database: database, lookupService: service, applyBatch: { mutations, batchID, _ in try await apply(mutations, batchID) }, resyncBatch: resync, preferences: nil)
    }
}

private actor SessionTokenRecorder {
    private(set) var tokens: [Int64: FileMembershipToken]?
    func record(_ tokens: [Int64: FileMembershipToken]) {
        self.tokens = tokens
    }
}

private final class SessionFreshnessSuspension: @unchecked Sendable {
    private let lock = NSLock()
    private let started: XCTestExpectation
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false

    init(started: XCTestExpectation) {
        self.started = started
    }

    func arm() {
        lock.withLock { armed = true }
    }

    func release() {
        semaphore.signal()
    }

    func read(_: String) -> FileFreshnessSnapshot {
        let shouldWait = lock.withLock {
            let shouldWait = armed
            armed = false
            return shouldWait
        }
        if shouldWait {
            started.fulfill()
            semaphore.wait()
        }
        return FileFreshnessSnapshot(fileSize: 1000, mtime: 10)
    }
}

private struct SessionTestKey: AcoustIDKeyProviding {
    func load() throws -> String? {
        "fixture-key"
    }
}

private actor SessionLookupLoader: URLLoading {
    let alternatives: Bool
    let firstLookupHasNoMatch: Bool
    let lowScoreAlternative: Bool
    let onlyMetadataMatches: Bool
    let blockedRecordingID: String?
    let started: SessionGate
    let release: SessionGate
    private(set) var lookupCount = 0

    init(alternatives: Bool, firstLookupHasNoMatch: Bool, lowScoreAlternative: Bool, onlyMetadataMatches: Bool, blockedRecordingID: String?,
         started: SessionGate, release: SessionGate)
    {
        self.alternatives = alternatives
        self.firstLookupHasNoMatch = firstLookupHasNoMatch
        self.lowScoreAlternative = lowScoreAlternative
        self.onlyMetadataMatches = onlyMetadataMatches
        self.blockedRecordingID = blockedRecordingID
        self.started = started
        self.release = release
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let object: [String: Any]
        if url.lastPathComponent == "lookup" {
            lookupCount += 1
            var recordingIDs = ["recording-\(lookupCount)"]
            if alternatives {
                recordingIDs += ["same-recording", "alternative-a", "alternative-b", "no-release"]
            }
            var results: [[String: Any]] = [["id": "source-\(lookupCount)", "score": 0.99, "recordings": recordingIDs.map { ["id": $0] }]]
            if (firstLookupHasNoMatch && lookupCount == 1) || onlyMetadataMatches {
                results = []
            }
            if lowScoreAlternative {
                results.append(["id": "weak-source", "score": 0.4, "recordings": [["id": "alternative-b"]]])
            }
            object = ["status": "ok", "results": results]
        } else if url.lastPathComponent == "recording" {
            let recordings: [[String: Any]] = onlyMetadataMatches
                ? [["id": "text-match", "title": "Current title", "artist-credit": [["name": "Current artist", "artist": ["id": "artist", "name": "Current artist"]]]]]
                : []
            object = ["recordings": recordings]
        } else {
            let requestedID = url.lastPathComponent
            if requestedID == blockedRecordingID {
                await started.open()
                await release.wait()
            }
            let canonicalID = requestedID == "same-recording" ? "recording-1" : requestedID
            let releases: [[String: Any]] = requestedID == "no-release" ? [] : [
                ["id": "first-release-\(canonicalID)", "title": "Proposed album", "date": "1994", "release-group": ["id": "group", "first-release-date": "1994"]],
                ["id": "second-release-\(canonicalID)", "title": "Second album", "date": "2000"],
            ]
            object = ["id": canonicalID, "title": "Proposed \(canonicalID)", "artist-credit": [["name": "Proposed artist", "artist": ["id": "artist", "name": "Proposed artist"]]], "releases": releases]
        }
        return try (JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor SessionGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        opened = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        if opened {
            return
        }
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard !opened else { return }
            XCTFail("Fixture gate was not reached or released within five seconds")
            open()
        }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
        timeout.cancel()
    }
}

private actor SessionApplyRecorder {
    let started: SessionGate
    let release: SessionGate
    let failExternally: Bool
    private(set) var fileIDsByBatch: [[Int64]] = []
    init(started: SessionGate, release: SessionGate, failExternally: Bool) {
        self.started = started
        self.release = release
        self.failExternally = failExternally
    }

    func apply(_ mutations: [TrackMutation], batchID: String) async throws {
        fileIDsByBatch.append(mutations.compactMap { mutation in
            guard case let .applyMusicBrainzMatch(payload) = mutation else { return nil }
            return payload.fileID
        })
        await started.open()
        await release.wait()
        if failExternally {
            throw OperationEngineError.externalSyncIncomplete(batchId: batchID, underlying: "fixture failure")
        }
    }
}

private actor PayloadRecorder {
    private(set) var payloads: [ApplyMusicBrainzMatchPayload] = []
    func record(_ mutations: [TrackMutation]) {
        payloads += mutations.compactMap { mutation in
            guard case let .applyMusicBrainzMatch(payload) = mutation else { return nil }
            return payload
        }
    }
}
