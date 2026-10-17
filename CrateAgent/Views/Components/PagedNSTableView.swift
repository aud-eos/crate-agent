import AppKit

final class PagedNSTableView: NSTableView {
    var contentVisibleRect: NSRect {
        var visible = visibleRect
        if let headerView {
            let header = convert(headerView.bounds, from: headerView)
            if visible.intersects(header) {
                let lower = min(visible.maxY, header.maxY)
                visible.size.height = visible.maxY - lower
                visible.origin.y = lower
            }
        }
        return visible
    }

    var selectionIntent: ((Int, NSEvent.ModifierFlags) -> Void)?
    var selectMatchingRows: (() -> Void)?
    var menuAtRow: ((Int) -> NSMenu?)?
    var focusChanged: ((Int) -> Void)?
    /// Handles Space for the focused row instead of toggling its selection.
    var spaceAction: ((Int) -> Bool)?
    /// Handles Command-O for the focused row.
    var openAction: ((Int) -> Bool)?

    func focusRow(_ index: Int, modifiers: NSEvent.ModifierFlags, selecting: Bool) {
        guard index >= 0, index < numberOfRows else { return }
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        scrollRowToVisible(index)
        focusChanged?(index)
        if selecting {
            selectionIntent?(index, modifiers)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        focusRow(index, modifiers: event.modifierFlags, selecting: true)
    }

    override func keyDown(with event: NSEvent) {
        let step = max(1, Int(visibleRect.height / rowHeight))
        let next: Int
        switch event.keyCode {
        case 125: next = min(numberOfRows - 1, selectedRow + 1)
        case 126: next = max(0, selectedRow - 1)
        case 119: next = numberOfRows - 1
        case 115: next = 0
        case 121: next = min(numberOfRows - 1, selectedRow + step)
        case 116: next = max(0, selectedRow - step)
        case 49:
            if spaceAction?(selectedRow) != true {
                selectionIntent?(selectedRow, [.command])
            }
            return
        default:
            super.keyDown(with: event)
            return
        }
        focusRow(next, modifiers: event.modifierFlags, selecting: true)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isOpen = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.charactersIgnoringModifiers == "o"
        if isOpen, window?.firstResponder === self, selectedRow >= 0, openAction?(selectedRow) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func selectAll(_: Any?) {
        selectMatchingRows?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        return index >= 0 ? menuAtRow?(index) : nil
    }
}

final class PagedTableRowView: NSTableRowView {
    var logicallySelected = false {
        didSet {
            setAccessibilitySelected(logicallySelected)
            needsDisplay = true
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if logicallySelected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in _: NSRect) {
        NSColor.keyboardFocusIndicatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)).stroke()
    }
}
