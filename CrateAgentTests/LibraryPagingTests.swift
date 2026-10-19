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

    /// Invariant 8 evidence: 30,000 files, then 6,000 of them grouped into 2,000 three-version families.
    func testSongFamilyProjectionStaysWithinPagingBudgetsAtThirtyThousandFiles() async throws {
        let fixture = try fixture
        func measure(_ label: String) async throws -> String {
            let start = ContinuousClock.now
            let snapshot = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: .init(sort: .init(column: .artist)))
            let opened = ContinuousClock.now
            _ = try await snapshot.rows(in: 0 ..< 200)
            let firstPage = ContinuousClock.now
            let total = await snapshot.count()
            _ = try await snapshot.rows(in: (total - 200) ..< total)
            let distantPage = ContinuousClock.now
            _ = try await snapshot.selectAllIdentities(after: nil, limit: 200)
            let placements = ContinuousClock.now
            for duration in [opened - start, firstPage - opened, distantPage - firstPage, placements - distantPage] {
                XCTAssertLessThan(duration, .milliseconds(500))
            }
            return "\(label)_rows=\(total) \(label)_count_ms=\((opened - start).milliseconds) \(label)_first_page_ms=\((firstPage - opened).milliseconds) "
                + "\(label)_distant_page_ms=\((distantPage - firstPage).milliseconds) \(label)_placements_ms=\((placements - distantPage).milliseconds)"
        }
        let ungrouped = try await measure("ungrouped")
        try await fixture.pool.write { connection in try PagedLibraryFixture.groupFamilies(connection) }
        let grouped = try await measure("grouped")
        let snapshot = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: fixture.query)
        let visible = await snapshot.count()
        XCTAssertEqual(visible, 26000)

        // One interaction is what the screen waits for: the new snapshot, its first page,
        // the members of the families on it, and the selection summary over every placement.
        let store = try LibrarySelectionStore(database: fixture.database)
        try await store.setScope(snapshot, selected: true)
        func interaction(_ label: String, _ query: LibraryBrowseQuery) async throws -> String {
            let start = ContinuousClock.now
            let opened = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: query)
            let page = try await opened.rows(in: 0 ..< 200)
            _ = try await opened.familyMembers(Set(page.compactMap { row in row.familyRole == .main ? row.familyId : nil }))
            _ = try await store.summary(in: opened)
            let elapsed = ContinuousClock.now - start
            XCTAssertLessThan(elapsed, .milliseconds(500), label)
            return "\(label)_ms=\(elapsed.milliseconds)"
        }
        let firstPage = try await snapshot.rows(in: 0 ..< 200)
        let firstFamily = try XCTUnwrap(firstPage.first { row in row.familyRole == .main }?.familyId)
        let expanded = try await interaction("expand", LibraryBrowseQuery(sort: fixture.query.sort, expandedFamilies: [firstFamily]))
        let collapsed = try await interaction("collapse", fixture.query)
        let included = try await interaction("include_alternates", LibraryBrowseQuery(sort: fixture.query.sort, includeAlternates: true))
        let searched = try await interaction("search", LibraryBrowseQuery(search: "Artist A", sort: fixture.query.sort))
        await store.close()
        let metrics = "\(ungrouped) \(grouped) \(expanded) \(collapsed) \(included) \(searched)"
        print("SONG_FAMILY_PAGING_METRICS \(metrics)")
        let attachment = XCTAttachment(string: metrics)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Invariant 8 evidence for the checklist: every new sort, every chip, a chip with a search, and a search,
    /// chip, genre, BPM range and compatible key together, each opened with its first page and, separately,
    /// its chip counts, over checklist facts for 30,000 files; plus the facet options load.
    func testChecklistSortFilterAndCountsStayWithinBudgetsAtThirtyThousandFiles() async throws {
        let fixture = try fixture
        try fixture.seedChecklist()
        var metrics: [String] = []
        func measure(_ label: String, _ query: LibraryBrowseQuery) async throws {
            let start = ContinuousClock.now
            let snapshot = try await LibraryPagedSnapshot.open(pool: fixture.pool, query: query)
            let total = await snapshot.count()
            _ = try await snapshot.rows(in: 0 ..< min(200, total))
            let paged = ContinuousClock.now - start
            let countsStart = ContinuousClock.now
            _ = try await snapshot.chipCounts()
            let counted = ContinuousClock.now - countsStart
            XCTAssertLessThan(paged, .milliseconds(500), label)
            XCTAssertLessThan(counted, .milliseconds(500), "\(label) counts")
            metrics.append("\(label)_rows=\(total) \(label)_page_ms=\(paged.milliseconds) \(label)_counts_ms=\(counted.milliseconds)")
        }
        for column in [LibraryBrowseSort.Column.stillNeeds, .dateAdded, .myPlays] {
            try await measure("sort_\(column.rawValue)", .init(sort: .init(column: column)))
        }
        for chip in ChecklistChip.allCases {
            try await measure("chip_\(chip.rawValue)", .init(chip: chip))
        }
        try await measure("search_needs_work", .init(search: "Artist A", chip: .needsWork))
        let optionsStart = ContinuousClock.now
        let options = try await fixture.pool.read { connection in try LibraryFacetOptions.load(in: connection, filter: .active) }
        let optionsElapsed = ContinuousClock.now - optionsStart
        XCTAssertLessThan(optionsElapsed, .milliseconds(500), "facet options")
        metrics.append("facet_options_ms=\(optionsElapsed.milliseconds)")
        var facets = LibraryFacets(genres: ["House"], bpmRange: 122 ... 128, compatibleKey: CamelotKey(parsing: "8A"))
        facets.keyValues = try options.keyValues(compatibleWith: XCTUnwrap(facets.compatibleKey))
        try await measure("all_facets", .init(search: "Artist A", chip: .needsWork, facets: facets, sort: .init(column: .stillNeeds)))
        let line = "CHECKLIST_PAGING_METRICS " + metrics.joined(separator: " ")
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Invariant 8 evidence for Find Versions: 6,000 of the 30,000 files form 2,000 three-version
    /// suggestions; the other 23,999 matching files await fingerprints. The scan reads the
    /// whole library off the main actor; one apply groups the most families a batch may hold.
    @MainActor
    func testFindVersionsScanAndApplyStayWithinBudgetsAtThirtyThousandFiles() async throws {
        let fixture = try fixture
        let labels = ["Clean", "Dirty", "Instrumental"]
        try await fixture.pool.write { connection in
            for family in 0 ..< 2000 {
                for (member, label) in labels.enumerated() {
                    let fileID = family * 10 + member + 1
                    try connection.execute(sql: "UPDATE files SET title = ?, chromaprint_fingerprint = ?, fingerprint_status = 'done' WHERE id = ?",
                                           arguments: ["Song \(family) (\(label))", Data("fingerprint-\(fileID)".utf8), fileID])
                }
            }
        }
        defer {
            do {
                try fixture.pool.write { connection in
                    for family in 0 ..< 2000 {
                        for member in 0 ..< labels.count {
                            var file = PagedLibraryFixture.file(family * 10 + member + 1)
                            try file.save(connection)
                        }
                    }
                }
            } catch { XCTFail("Fixture restore: \(error)") }
        }
        let engine = OperationEngine(database: fixture.database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }),
                                     seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")),
                                     fileTagWriter: { _, _ in XCTFail("Grouping wrote audio tags") }, fileTagReader: { _ in AudioTags.none })
        let suggester = SongFamilySuggester(database: fixture.database, families: SongFamilyService(engine: engine, database: fixture.database))
        var maximumDelay = Duration.zero
        let heartbeat = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                maximumDelay = max(maximumDelay, ContinuousClock.now - previous - .milliseconds(5))
                previous = .now
            }
        }
        let scanStart = ContinuousClock.now
        let found = try await suggester.suggestions()
        let scan = ContinuousClock.now - scanStart
        heartbeat.cancel()
        XCTAssertEqual(found.suggestions.count, 2000)
        XCTAssertTrue(found.suggestions.allSatisfy { suggestion in suggestion.confidence == .high })
        XCTAssertEqual(found.awaitingFingerprint, 23999)
        XCTAssertLessThan(scan, .seconds(2))
        XCTAssertLessThan(maximumDelay, .milliseconds(100))

        let probe = WriterHoldProbe()
        probe.start(fixture.database) { nil }
        let applyStart = ContinuousClock.now
        let choices = found.suggestions.prefix(SongFamilySuggester.maximumFamiliesPerApply).map { suggestion in
            SongFamilySuggestionChoice(suggestion: suggestion, recordingIds: Set(suggestion.recordings.map(\.id)))
        }
        _ = try await suggester.apply(choices)
        let apply = ContinuousClock.now - applyStart
        let waits = await probe.stop()
        let grouped = try await fixture.pool.read { connection in try SongFamilyRecord.fetchCount(connection) }
        XCTAssertEqual(grouped, SongFamilySuggester.maximumFamiliesPerApply)
        let longestWait = try XCTUnwrap(waits.first).duration
        XCTAssertLessThan(longestWait, .milliseconds(500))
        let metrics = "FIND_VERSIONS_METRICS files=30000 suggestions=\(found.suggestions.count) scan_ms=\(scan.milliseconds) "
            + "scan_main_delay_ms=\(maximumDelay.milliseconds) applied=\(choices.count) apply_ms=\(apply.milliseconds) apply_longest_writer_wait_ms=\(longestWait.milliseconds)"
        print(metrics)
        let attachment = XCTAttachment(string: metrics)
        attachment.lifetime = .keepAlways
        add(attachment)
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
        let store = try LibrarySelectionStore(database: fixture.database, readIdentities: { snapshot, _, after, limit in
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

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
