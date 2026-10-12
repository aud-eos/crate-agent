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
        })
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
