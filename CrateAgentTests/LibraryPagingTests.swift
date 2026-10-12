import AppKit
@testable import CrateAgent
import GRDB
import SwiftUI
import XCTest

final class LibraryPagingTests: XCTestCase {
    private static var fixtureResult: Result<PagedLibraryFixture, Error>!
    var fixture: PagedLibraryFixture {
        get throws { try Self.fixtureResult.get() }
    }

    override class func setUp() {
        super.setUp()
        fixtureResult = Result { try PagedLibraryFixture() }
    }

    override class func tearDown() {
        do { try fixtureResult.get().close() } catch { XCTFail("Fixture cleanup: \(error)") }
        fixtureResult = nil
        super.tearDown()
    }

    override func tearDownWithError() throws {
        try fixture.reset()
    }

    func testSnapshotCountPagesAndFullQuerySearchRemainConsistentAcrossWrites() async throws {
        let fixture = try fixture
        let snapshot = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: fixture.query)
        let count = await snapshot.count()
        XCTAssertEqual(count, 30000)
        try await fixture.pool.write { connection in
            var added = PagedLibraryFixture.file(30001)
            try added.insert(connection)
            try connection.execute(sql: "UPDATE files SET title = 'Changed' WHERE id = 30000")
        }
        let oldLast = try await snapshot.rows(in: 29800 ..< 30000)
        XCTAssertEqual(oldLast.last?.title, "Final Needle")
        XCTAssertEqual(oldLast.last?.id, 30000)
        let oldCount = await snapshot.count()
        XCTAssertEqual(oldCount, 30000)
        let current = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: fixture.query)
        let newCount = await current.count()
        XCTAssertEqual(newCount, 30001)
        let search = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: .init(search: "Changed"))
        let found = try await search.rows(in: 0 ..< 1)
        XCTAssertEqual(found.map(\.id), [30000])
        try await fixture.pool.write { connection in try connection.execute(sql: "DELETE FROM files WHERE id = 1") }
        let stillFirst = try await snapshot.rows(in: 0 ..< 1)
        XCTAssertEqual(stillFirst.first?.id, 1)
        let latest = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: fixture.query)
        let latestFirst = try await latest.rows(in: 0 ..< 1)
        XCTAssertEqual(latestFirst.first?.id, 2)
    }

    func testDatabaseSortUsesStableTieBreaksAcrossPageBoundaries() async throws {
        let fixture = try fixture
        for ascending in [true, false] {
            let query = LibraryBrowseQuery(sort: .init(column: .artist, ascending: ascending))
            let snapshot = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: query)
            let first = try await snapshot.rows(in: 0 ..< 200)
            let second = try await snapshot.rows(in: 200 ..< 400)
            XCTAssertEqual(first.first?.id, ascending ? 1 : 15001)
            XCTAssertEqual(second.first?.id, ascending ? 201 : 15201)
            XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
            let index = try await snapshot.index(of: ascending ? 201 : 15201)
            XCTAssertEqual(index, 200)
        }
    }

    func testCapturedSelectionExcludesNewMatchesAndReconcilesChangedIdentities() async throws {
        let fixture = try fixture
        let store = try LibrarySelectionStore(database: fixture.database)
        let scope = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: .init(search: "Artist A"))
        try await store.setScope(scope, selected: true)
        try await store.set([.init(id: 1, revision: 0)], selected: false)
        let outside = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: .init(search: "Artist B"))
        let hidden = try await store.summary(in: outside)
        XCTAssertEqual(hidden.total, 14999)
        XCTAssertEqual(hidden.hidden, 14999)
        try await fixture.pool.write { connection in
            var added = PagedLibraryFixture.file(30001)
            added.artist = "Artist A"
            try added.insert(connection)
            try connection.execute(sql: "UPDATE files SET artist = 'Artist A' WHERE id = 15001")
            try connection.execute(sql: "UPDATE files SET membership_revision = 1 WHERE id = 2")
            try connection.execute(sql: "DELETE FROM files WHERE id = 3")
        }
        let removed = try await store.reconcile()
        XCTAssertEqual(removed, 2)
        let current = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: .init(search: "Artist A"))
        let summary = try await store.summary(in: current)
        XCTAssertEqual(summary.total, 14997)
        XCTAssertEqual(summary.inScope, 14997)
        let newIDs = try await store.selectedIDs(in: [.init(id: 15001, revision: 0), .init(id: 30001, revision: 0)])
        XCTAssertTrue(newIDs.isEmpty)
        try await store.setRange(0 ..< 3, in: outside, selected: true)
        try await store.setScope(current, selected: false)
        let remaining = try await store.summary(in: outside)
        XCTAssertEqual(remaining.total, 2)
        try await store.clear()
        let cleared = try await store.summary(in: current)
        XCTAssertEqual(cleared.total, 0)
        await store.close()
    }

    func testPartialCaptureFailureRollsBackWithoutChangingCommittedSelection() async throws {
        let fixture = try fixture
        let store = try LibrarySelectionStore(database: fixture.database, readIdentities: { snapshot, after, limit in
            if after != nil {
                throw PagingFixtureError.unavailable
            }
            return try await snapshot.identities(after: after, limit: limit)
        })
        try await store.set([.init(id: 1, revision: 0)], selected: true)
        let snapshot = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: fixture.query)
        do {
            try await store.setScope(snapshot, selected: true)
            XCTFail("Capture must surface the read failure")
        } catch PagingFixtureError.unavailable {}
        let summary = try await store.summary(in: snapshot)
        XCTAssertEqual(summary.total, 1)
        try await store.clear()
        await store.close()
    }

    @MainActor
    func testNativeLibraryPerformanceAndSelectionWithThirtyThousandFiles() async throws {
        let fixture = try fixture
        let model = try LibraryBrowserModel(database: fixture.database)
        let windowStart = CFAbsoluteTimeGetCurrent()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.orderFront(nil)
        window.displayIfNeeded()
        let windowMilliseconds = (CFAbsoluteTimeGetCurrent() - windowStart) * 1000
        defer { window.close() }
        var maximumDelay = 0.0
        let heartbeat = Task { @MainActor in
            var previous = CFAbsoluteTimeGetCurrent()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let now = CFAbsoluteTimeGetCurrent()
                maximumDelay = max(maximumDelay, (now - previous) * 1000 - 5)
                previous = now
            }
        }
        defer { heartbeat.cancel(); model.stop() }
        let loadingStart = CFAbsoluteTimeGetCurrent()
        await model.start()
        await pagingEventually { model.results.totalCount == 30000 }
        let configuration = PagedTable(controller: model.results, columns: LibraryBrowserColumns.make(showsFilenames: false, density: .comfortable),
                                       accessibilityLabel: "Library", rowHeight: 28,
                                       isSelected: { identifier in model.selection.visibleSelectedIDs.contains(identifier) },
                                       onSelect: { _, _ in }, onSelectRange: { _, _ in }, onSelectAll: {}, onClear: {}, onSort: { _, _ in }, contextMenu: { _ in nil })
        let renderStart = CFAbsoluteTimeGetCurrent()
        let coordinator = configuration.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let renderMilliseconds = (CFAbsoluteTimeGetCurrent() - renderStart) * 1000
        defer { coordinator.stop() }
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        XCTAssertEqual(table.numberOfRows, 30000)
        await pagingEventually { model.results.row(at: 0) != nil }
        let initialDecoded = model.results.decodedRowCount
        XCTAssertLessThanOrEqual(initialDecoded, 1000)
        let initialLatency = (CFAbsoluteTimeGetCurrent() - loadingStart) * 1000
        try await Task.sleep(for: .milliseconds(20))
        let jumpStart = CFAbsoluteTimeGetCurrent()
        table.scrollRowToVisible(29999)
        scroll.layoutSubtreeIfNeeded()
        let jumpMilliseconds = (CFAbsoluteTimeGetCurrent() - jumpStart) * 1000
        await pagingEventually { model.results.row(at: 29999) != nil }
        let pageLatency = (CFAbsoluteTimeGetCurrent() - jumpStart) * 1000
        try await Task.sleep(for: .milliseconds(20))
        table.scrollRowToVisible(0)
        await pagingEventually { model.results.row(at: 0) != nil }
        let snapshot = try XCTUnwrap(model.results.snapshot)
        model.selection.setScope(snapshot, selected: true)
        await pagingEventually { model.selection.summary?.total == 30000 && !model.selection.isBusy }
        XCTAssertLessThanOrEqual(model.results.peakCachedRowCount, 1000)
        model.setQuery(.init(search: "Final Needle"))
        await pagingEventually { model.results.totalCount == 1 && model.selection.summary?.hidden == 29999 }
        let file = try await model.resolveFile(id: 30000)
        XCTAssertEqual(file.title, "Final Needle")
        let metrics = "window_setup_ms=\(windowMilliseconds) render_ms=\(renderMilliseconds) jump_ms=\(jumpMilliseconds) initial_async_ms=\(initialLatency) distant_async_ms=\(pageLatency) main_delay_ms=\(maximumDelay) initial_decoded=\(initialDecoded) total_decoded=\(model.results.decodedRowCount) cache_peak=\(model.results.peakCachedRowCount)"
        print("PAGED_LIBRARY_METRICS \(metrics)")
        let attachment = XCTAttachment(string: metrics)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testMetadataRefreshKeepsMountedTableAndDistantScrollAnchor() async throws {
        let fixture = try fixture
        let model = try LibraryBrowserModel(database: fixture.database)
        await model.start()
        let host = NSHostingView(rootView: LibraryPagedContent(model: model, density: .comfortable, showsFilenames: false, onAction: { _, _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { model.stop(); window.close() }
        func findTable(_ view: NSView) -> PagedNSTableView? {
            if let table = view as? PagedNSTableView {
                return table
            }
            for child in view.subviews {
                if let table = findTable(child) {
                    return table
                }
            }
            return nil
        }
        await pagingEventually { findTable(host) != nil }
        let table = try XCTUnwrap(findTable(host))
        table.scrollRowToVisible(29999)
        await pagingEventually { model.results.row(at: 29999) != nil && !model.selection.isBusy }
        let firstVisible = table.rows(in: table.contentVisibleRect).location
        let anchor = try XCTUnwrap(model.results.row(at: firstVisible)?.id)
        let generation = model.results.generation
        try await fixture.pool.write { connection in try connection.execute(sql: "UPDATE files SET title = 'Updated' WHERE id = 30000") }
        await pagingEventually { model.results.generation > generation && !model.isRefreshing && model.results.row(at: 29999)?.title == "Updated" }
        let refreshed = try XCTUnwrap(findTable(host))
        XCTAssertTrue(refreshed === table, "Refresh must keep the native table mounted")
        let newFirstVisible = refreshed.rows(in: refreshed.contentVisibleRect).location
        XCTAssertEqual(model.results.row(at: newFirstVisible)?.id, anchor)
    }

    func testObservationIncludesOffscreenMetadataAndAvailabilityButNotFingerprintWrites() async throws {
        let fixture = try fixture
        let changes = expectation(description: "metadata and availability changes")
        changes.expectedFulfillmentCount = 2
        changes.assertForOverFulfill = true
        let observation = LibraryBrowseObservation.start(in: fixture.database, onChange: { changes.fulfill() }, onError: { error in XCTFail(error.localizedDescription) })
        defer { observation.cancel() }
        try await fixture.pool.write { connection in
            try connection.execute(sql: "UPDATE files SET title = 'Changed' WHERE id = 30000")
        }
        try await fixture.pool.write { connection in
            try connection.execute(sql: "UPDATE files SET chromaprint_fingerprint = X'010203' WHERE id = 30000")
        }
        try await fixture.pool.write { connection in
            try connection.execute(sql: "UPDATE files SET file_availability = 'offline' WHERE id = 30000")
        }
        await fulfillment(of: [changes], timeout: 3)
    }
}
