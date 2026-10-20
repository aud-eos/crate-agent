import AppKit
@testable import CrateAgent
import XCTest

@MainActor
final class PagedTableTests: XCTestCase {
    func testPlaceholderNavigationGenerationChangeAndStableContextTarget() async throws {
        let source = PagedQueryFixture(rowCount: 30000, signature: "old")
        await source.holdPages()
        let controller = PagedResultsController<PagedQueryFixture>()
        await controller.open(source)
        var selected: Set<Int> = []
        var allCalls = 0
        var contextID: Int?
        var selectedRange: Range<Int>?
        var selectionVersion: UInt64 = 0
        var focusedID: Int?
        let configuration = PagedTable(controller: controller, columns: [
            PagedTableColumn<FixtureRow>(identifier: "name", title: "Name", width: 200,
                                         makeCell: { NSTextField(labelWithString: "") },
                                         updateCell: { view, row in (view as? NSTextField)?.stringValue = row?.name ?? PagingLabels.loading }),
        ], accessibilityLabel: "Fixture results", rowHeight: 24,
        isSelected: { selected.contains($0) }, onSelect: { rows, enabled in
            if enabled {
                selected.formUnion(rows.map(\.id))
            } else {
                selected.subtract(rows.map(\.id))
            }
        }, onSelectRange: { range, _ in selectedRange = range }, onSelectAll: { allCalls += 1 },
        onClear: { selected.removeAll() }, onSort: { _, _ in }, contextMenu: { identifier in
            contextID = identifier
            return NSMenu()
        }, selectionVersion: { selectionVersion }, onFocus: { identifier, _ in focusedID = identifier })
        let coordinator = configuration.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        defer { coordinator.stop(); controller.stop(); window.close() }
        scroll.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(scroll.documentView as? PagedNSTableView)
        XCTAssertEqual(table.numberOfRows, 30000)
        table.scrollRowToVisible(29999)
        table.selectAll(nil)
        XCTAssertEqual(allCalls, 1)
        XCTAssertTrue(selected.isEmpty)
        table.focusRow(29999, modifiers: [], selecting: true)
        XCTAssertTrue(selected.isEmpty)
        let replacement = PagedQueryFixture(rowCount: 5, signature: "new")
        await controller.open(replacement)
        await source.releaseAll()
        await pagingEventually { controller.row(at: 4) != nil && table.numberOfRows == 5 }
        XCTAssertTrue(selected.isEmpty)
        let held = PagedQueryFixture(rowCount: 5, signature: "held")
        await held.holdPages()
        // A refresh keeps the shown rows until its pages load; only a reset query shows placeholders.
        controller.stop()
        await controller.open(held)
        await pagingEventually { controller.row(at: 0) == nil }
        await Task.yield()
        table.focusRow(3, modifiers: [], selecting: true)
        XCTAssertNil(focusedID)
        selected.removeAll()
        selectionVersion += 1
        await held.releaseAll()
        await pagingEventually { controller.row(at: 3) != nil }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(selected.isEmpty, "An external Clear must cancel a pending placeholder click")
        XCTAssertEqual(focusedID, 4, "Loaded placeholder focus must acquire its stable identity")
        let focusOnly = PagedQueryFixture(rowCount: 5, signature: "focus-only")
        await focusOnly.holdPages()
        await controller.open(focusOnly, focusID: focusedID, focusFallback: 3)
        await pagingEventually { table.selectedRow == 3 }
        await focusOnly.releaseAll()
        await pagingEventually { controller.row(at: 3) != nil }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(focusedID, 4, "Restored focus must retain its identity without selecting")
        table.focusRow(2, modifiers: [], selecting: true)
        XCTAssertEqual(selected, [3])
        table.focusRow(4, modifiers: [.shift], selecting: true)
        XCTAssertEqual(selectedRange, 2 ..< 5)
        let location = table.convert(NSPoint(x: 50, y: table.rect(ofRow: 4).midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertNotNil(table.menu(for: event))
        XCTAssertEqual(contextID, 5)
        table.focusRow(1, modifiers: [], selecting: false)
        await controller.open(PagedQueryFixture(rowCount: 5, signature: "refreshed"), anchorID: 1, focusID: 5, focusFallback: 4)
        await pagingEventually { table.selectedRow == 4 }
        XCTAssertEqual(selected, [3])
        await controller.open(PagedQueryFixture(rowCount: 2, signature: "deleted"), anchorID: 5, fallbackIndex: 4)
        await pagingEventually { table.numberOfRows == 2 }
        XCTAssertEqual(selected, [3])
        XCTAssertLessThan(table.subviews.count, 200)
    }
}
