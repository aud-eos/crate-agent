import AppKit
@testable import CrateAgent
import SwiftUI
import XCTest

@MainActor
final class LibraryStartupPerformanceTests: XCTestCase {
    func testThirtyThousandFileCheckpointRestart() async throws {
        let fixture = try await LibraryStartupPerformanceFixture()
        defer {
            do { try fixture.cleanup() }
            catch { XCTFail("Cannot clean startup fixture: \(error)") }
        }
        let session = fixture.makeSession(checkpointed: true)
        let start = ContinuousClock.now
        try await session.synchronize()
        let elapsed = start.duration(to: .now)
        guard case .ready = session.state else { return XCTFail("Full baseline did not become ready") }
        let metrics = "STARTUP_FULL files=30000 real_audio=true full_sync=\(elapsed)"
        print(metrics)
        let attachment = XCTAttachment(string: metrics)
        attachment.lifetime = .keepAlways
        add(attachment)
        let reopened = try LibraryDatabase.openWAL(at: fixture.directory.appendingPathComponent("library.sqlite"))
        let gate = LibrarySyncReadiness()
        let reader = SeratoMembershipSnapshotReader(locator: fixture.locator, watchdog: fixture.watchdog)
        let engine = OperationEngine(database: reopened, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator, readiness: gate)
        let scanner = LibraryScanner(operationEngine: engine, database: reopened, seratoLocator: fixture.locator)
        let restarted = SeratoLibrarySyncSession(reader: reader,
                                                 reconciler: SeratoMembershipReconciler(database: reopened, operationEngine: engine, reader: reader),
                                                 scanner: scanner, operationEngine: engine, watchdog: fixture.watchdog, readiness: gate,
                                                 checkpointStore: SyncCheckpointStore(database: reopened), watchRoots: [fixture.directory.path])
        let counters = LibrarySyncMetrics()
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { _ in }, checkpoint: { _ in })
        let coordinator = LibraryStartupCoordinator(session: restarted, processor: processor, captureBoundary: {
            try await processor.enqueue(.init(observations: [], highestEventID: 0, deliverySequence: 1, replayBoundary: true, historyComplete: true))
            return 1
        })
        let restartStart = ContinuousClock.now
        await LibrarySyncMetrics.$current.withValue(counters) {
            coordinator.start()
            await coordinator.waitUntilIdle()
        }
        let timeToReady = restartStart.duration(to: .now)
        guard case .ready = restarted.state else { return XCTFail("Restart failed: \(restarted.state)") }
        XCTAssertEqual(counters.snapshot().snapshotParses, 0)
        XCTAssertEqual(counters.snapshot().audioTagReads, 0)
        XCTAssertEqual(counters.snapshot().bitrateReads, 0)
        XCTAssertEqual(counters.snapshot().lightweightHashReads, 0)
        XCTAssertEqual(counters.snapshot().stats, 30000)
        XCTAssertLessThan(timeToReady, .seconds(2))
        let result = "STARTUP_RESTART files=30000 real_audio=true reopened_wal=true native_stat=true replay=controlled_empty warm_filesystem=true time_to_ready=\(timeToReady) stats=\(counters.snapshot().stats) parser=\(counters.snapshot().snapshotParses) tags=\(counters.snapshot().audioTagReads) bitrate=\(counters.snapshot().bitrateReads) hash=\(counters.snapshot().lightweightHashReads) phases=\(counters.phaseDurations())"
        print(result)
        let resultAttachment = XCTAttachment(string: result)
        resultAttachment.lifetime = .keepAlways
        add(resultAttachment)
        try await verifyNavigationDuringSync(fixture)
    }

    private func verifyNavigationDuringSync(_ fixture: LibraryStartupPerformanceFixture) async throws {
        let barrier = SessionBarrier()
        let reader = SeratoMembershipSnapshotReader(locator: fixture.locator, watchdog: fixture.watchdog, afterParsing: { await barrier.pauseFirst() })
        let session = SeratoLibrarySyncSession(reader: reader,
                                               reconciler: SeratoMembershipReconciler(database: fixture.database, operationEngine: fixture.engine, reader: reader),
                                               scanner: fixture.scanner, operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: fixture.readiness,
                                               checkpointStore: SyncCheckpointStore(database: fixture.database), watchRoots: [fixture.directory.path])
        let files = try await fixture.scanner.identityProjectionsForConflictAnalysis()
        let file = try XCTUnwrap(files.first)
        _ = try updateDatabaseRecord(databasePath: fixture.locator.databaseV2Url.path, trackPath: file.path,
                                     update: SeratoMetadataUpdate(artist: nil, title: "Changed during navigation", album: nil, genre: nil,
                                                                  bpm: nil, key: nil, comment: nil, length: nil, label: nil))
        let model = try LibraryBrowserModel(database: fixture.database)
        await model.start()
        let selection = LibraryNavigationSelection()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.orderFront(nil)
        defer { model.stop(); window.close() }
        let counters = LibrarySyncMetrics()
        let syncing = Task { try await LibrarySyncMetrics.$current.withValue(counters) { try await session.synchronize() } }
        await barrier.waitForEntry()
        XCTAssertEqual(session.phase, .parsing)
        let renderStart = ContinuousClock.now
        let host = NSHostingView(rootView: LibraryNavigationFixture(selection: selection, model: model, readiness: fixture.readiness))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func findSidebar(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, !(table is PagedNSTableView), table.numberOfRows == 5 {
                return table
            }
            for child in view.subviews {
                if let table = findSidebar(child) {
                    return table
                }
            }
            return nil
        }
        await pagingEventually { findSidebar(host) != nil && model.results.row(at: 0) != nil }
        let sidebar = try XCTUnwrap(findSidebar(host))
        let renderLatency = renderStart.duration(to: .now)
        XCTAssertLessThan(renderLatency, .milliseconds(500))
        let start = ContinuousClock.now
        sidebar.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        await pagingEventually { selection.section == .history }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let navigationLatency = start.duration(to: .now)
        XCTAssertEqual(session.state, .reconciling)
        XCTAssertLessThan(navigationLatency, .milliseconds(500))
        await barrier.release()
        try await syncing.value
        XCTAssertEqual(counters.snapshot().snapshotParses, 1)
        XCTAssertEqual(counters.snapshot().audioTagReads, 0)
        XCTAssertEqual(counters.snapshot().lightweightHashReads, 0)
        XCTAssertEqual(counters.snapshot().rowWrites, 1)
        let result = "STARTUP_NAVIGATION files=30000 mounted_production_sidebar=true mounted_production_library=true active_sync=held_after_parse content_render=\(renderLatency) navigation=\(navigationLatency) changed_rows=\(counters.snapshot().rowWrites)"
        print(result)
        let attachment = XCTAttachment(string: result)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
