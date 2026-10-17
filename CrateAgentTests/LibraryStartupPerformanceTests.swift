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
        try await verifyUpgradeBackfill(fixture)
        try await verifyNavigationDuringSync(fixture)
    }

    /// The first sync after migration 018 records 30,000 legacy rows' subsecond times from
    /// stat evidence (#118): no audio reads, writer waits inside #189's budget, slim events
    /// even for fingerprinted rows, and the next restart back on the fast path.
    private func verifyUpgradeBackfill(_ fixture: LibraryStartupPerformanceFixture) async throws {
        try await fixture.database.writer.write { database in
            try database.execute(sql: "UPDATE files SET mtime_nanoseconds = NULL, chromaprint_fingerprint = ?, fingerprint_status = 'done'",
                                 arguments: [Data(repeating: 7, count: 4096)])
        }
        let eventBytesBefore = try await eventBytes(fixture.database)
        let counters = LibrarySyncMetrics()
        let probe = WriterWaitProbe(database: fixture.database)
        let start = ContinuousClock.now
        try await LibrarySyncMetrics.$current.withValue(counters) { try await fixture.makeSession(checkpointed: true).synchronize() }
        let upgrade = start.duration(to: .now)
        let longestWriterWait = await probe.stop()
        let eventBytesAdded = try await eventBytes(fixture.database) - eventBytesBefore
        let awaiting = try await fixture.database.writer.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM files WHERE mtime_nanoseconds IS NULL")
        }
        let restartStart = ContinuousClock.now
        try await fixture.makeSession(checkpointed: true).synchronize()
        let restart = restartStart.duration(to: .now)
        XCTAssertEqual(awaiting, 0)
        XCTAssertEqual(counters.snapshot().lightweightHashReads, 0)
        XCTAssertEqual(counters.snapshot().audioTagReads, 0)
        XCTAssertLessThan(longestWriterWait, .milliseconds(500))
        XCTAssertLessThan(eventBytesAdded / 30000, 512)
        XCTAssertLessThan(upgrade, .seconds(60))
        XCTAssertLessThan(restart, .seconds(2))
        let result = "STARTUP_UPGRADE files=30000 fingerprinted=true upgrade=\(upgrade) writer_wait_max=\(longestWriterWait) event_bytes=\(eventBytesAdded) restart=\(restart) hash=\(counters.snapshot().lightweightHashReads) phases=\(counters.phaseDurations())"
        print(result)
        let attachment = XCTAttachment(string: result)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func eventBytes(_ database: LibraryDatabase) async throws -> Int {
        try await database.writer.read { database in
            try Int.fetchOne(database, sql: "SELECT COALESCE(SUM(LENGTH(payload_json) + LENGTH(inverse_payload_json)), 0) FROM events") ?? 0
        }
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
            if let table = view as? NSTableView, !(table is PagedNSTableView), table.numberOfRows == MainWindowView.Section.allCases.count - 1 {
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

/// Issues an empty write every 5 ms, as #189 measured drains, and reports the longest
/// time one waited for the writer.
private struct WriterWaitProbe {
    private let task: Task<Duration, Never>

    init(database: LibraryDatabase) {
        task = Task.detached {
            var longest = Duration.zero
            while !Task.isCancelled {
                let start = ContinuousClock.now
                do { try await database.writer.write { _ in } } catch { break }
                longest = max(longest, start.duration(to: .now))
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
            }
            return longest
        }
    }

    func stop() async -> Duration {
        task.cancel()
        return await task.value
    }
}
