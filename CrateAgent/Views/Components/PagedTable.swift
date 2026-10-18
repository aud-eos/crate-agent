import AppKit
import Combine
import SwiftUI

struct PagedTableColumn<Row> {
    let identifier: String
    let title: String
    let width: CGFloat
    let makeCell: () -> NSView
    let updateCell: (NSView, Row?) -> Void
    var sortable = true
}

struct PagedTable<Snapshot: PagedQuerySnapshot>: NSViewRepresentable {
    let controller: PagedResultsController<Snapshot>
    let columns: [PagedTableColumn<Snapshot.Row>]
    let accessibilityLabel: String
    let rowHeight: CGFloat
    let isSelected: (Snapshot.Row.ID) -> Bool
    let onSelect: ([Snapshot.Row], Bool) -> Void
    let onSelectRange: (Range<Int>, Bool) -> Void
    let onSelectAll: () -> Void
    let onClear: () -> Void
    let onSort: (String, Bool) -> Void
    let contextMenu: (Snapshot.Row.ID) -> NSMenu?
    var selectionVersion: () -> UInt64 = { 0 }
    var enabled = true
    var contentRevision: UInt64 = 0
    var onFocus: (Snapshot.Row.ID?, Int) -> Void = { _, _ in }
    /// Right Arrow expands and Left Arrow collapses the focused row, when it has a disclosure.
    var onDisclose: (Snapshot.Row.ID, Bool) -> Bool = { _, _ in false }
    var onSpace: ((Snapshot.Row) -> Void)?
    var onOpen: ((Snapshot.Row) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var configuration: PagedTable
        private weak var table: PagedNSTableView?
        private var subscription: AnyCancellable?
        private var pageSubscription: AnyCancellable?
        private var viewportTask: Task<Void, Never>?
        private var boundsObserver: NSObjectProtocol?
        private var displayedGeneration: UInt64 = 0
        private var rangeAnchor: Int?
        private var pendingSelection: (generation: UInt64, selectionVersion: UInt64, index: Int, modifiers: NSEvent.ModifierFlags)?
        private var sortedColumn: String?
        private var ascending = true

        init(_ configuration: PagedTable) {
            self.configuration = configuration
        }

        func makeScrollView() -> NSScrollView {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = false
            let table = PagedNSTableView()
            self.table = table
            table.delegate = self
            table.dataSource = self
            table.rowHeight = configuration.rowHeight
            table.usesAlternatingRowBackgroundColors = true
            table.allowsMultipleSelection = false
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.setAccessibilityLabel(configuration.accessibilityLabel)
            for column in configuration.columns {
                let native = NSTableColumn(identifier: .init(column.identifier))
                native.title = column.title
                native.width = column.width
                native.minWidth = min(column.width, 60)
                table.addTableColumn(native)
            }
            table.selectionIntent = { [weak self] index, modifiers in self?.select(index: index, modifiers: modifiers) }
            table.selectMatchingRows = { [weak self] in
                guard let self, configuration.enabled else { return }
                pendingSelection = nil
                configuration.onSelectAll()
            }
            table.menuAtRow = { [weak self] index in
                guard let self, let row = configuration.controller.row(at: index) else { return nil }
                pendingSelection = nil
                return configuration.contextMenu(row.id)
            }
            table.disclosureIntent = { [weak self] index, expanded in
                guard let self, let row = configuration.controller.row(at: index) else { return false }
                return configuration.onDisclose(row.id, expanded)
            }
            table.spaceAction = { [weak self] index in
                guard let self, let onSpace = configuration.onSpace else { return false }
                if let row = configuration.controller.row(at: index) {
                    onSpace(row)
                }
                return true
            }
            table.openAction = { [weak self] index in
                guard let self, let onOpen = configuration.onOpen, let row = configuration.controller.row(at: index) else { return false }
                onOpen(row)
                return true
            }
            table.focusChanged = { [weak self] index in
                guard let self else { return }
                configuration.onFocus(configuration.controller.row(at: index)?.id, index)
                reportViewport()
            }
            scroll.documentView = table
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportViewport() }
            }
            subscription = configuration.controller.$updateID.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }
            pageSubscription = configuration.controller.pageUpdates.receive(on: RunLoop.main).sink { [weak self] rows in
                self?.refreshVisibleRows(reloadCells: true, changedRows: rows)
            }
            displayedGeneration = configuration.controller.generation
            table.reloadData()
            return scroll
        }

        func update(_ configuration: PagedTable) {
            let geometryChanged = self.configuration.rowHeight != configuration.rowHeight
            let contentChanged = self.configuration.contentRevision != configuration.contentRevision
            self.configuration = configuration
            if geometryChanged {
                table?.rowHeight = configuration.rowHeight
                table?.reloadData()
            }
            refreshVisibleRows(reloadCells: contentChanged)
            reportViewport()
        }

        func stop() {
            subscription?.cancel()
            subscription = nil
            pageSubscription?.cancel()
            pageSubscription = nil
            viewportTask?.cancel()
            viewportTask = nil
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            boundsObserver = nil
            pendingSelection = nil
        }

        func numberOfRows(in _: NSTableView) -> Int {
            configuration.controller.totalCount
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            guard let tableColumn,
                  let column = configuration.columns.first(where: { column in column.identifier == tableColumn.identifier.rawValue }) else { return nil }
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) ?? column.makeCell()
            cell.identifier = tableColumn.identifier
            column.updateCell(cell, configuration.controller.row(at: index))
            return cell
        }

        func tableView(_: NSTableView, rowViewForRow index: Int) -> NSTableRowView? {
            let view = PagedTableRowView()
            let row = configuration.controller.row(at: index)
            view.logicallySelected = row.map { row in configuration.isSelected(row.id) } ?? false
            view.setAccessibilityLabel(row == nil ? PagingLabels.loading : nil)
            return view
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            let identifier = tableColumn.identifier.rawValue
            guard configuration.columns.contains(where: { column in column.identifier == identifier && column.sortable }) else { return }
            ascending = sortedColumn == identifier ? !ascending : true
            sortedColumn = identifier
            pendingSelection = nil
            for column in tableView.tableColumns {
                tableView.setIndicatorImage(nil, in: column)
            }
            tableView.setIndicatorImage(NSImage(named: ascending ? NSImage.touchBarGoUpTemplateName : NSImage.touchBarGoDownTemplateName), in: tableColumn)
            configuration.onSort(identifier, ascending)
        }

        private func select(index: Int, modifiers: NSEvent.ModifierFlags) {
            pendingSelection = nil
            guard configuration.enabled, index >= 0, index < configuration.controller.totalCount else { return }
            if modifiers.contains(.shift), let rangeAnchor {
                configuration.onSelectRange(min(rangeAnchor, index) ..< (max(rangeAnchor, index) + 1), true)
            } else if let row = configuration.controller.row(at: index) {
                if !modifiers.contains(.command) {
                    configuration.onClear()
                }
                configuration.onSelect([row], !modifiers.contains(.command) || !configuration.isSelected(row.id))
                rangeAnchor = index
            } else {
                pendingSelection = (configuration.controller.generation, configuration.selectionVersion(), index, modifiers)
                configuration.controller.setViewport(index ..< (index + 1))
            }
        }

        private func reload() {
            guard let table, !configuration.controller.isLoading else { return }
            if displayedGeneration != configuration.controller.generation || table.numberOfRows != configuration.controller.totalCount {
                displayedGeneration = configuration.controller.generation
                pendingSelection = nil
                rangeAnchor = nil
                table.deselectAll(nil)
                table.reloadData()
                if let anchor = configuration.controller.viewportAnchor, table.numberOfRows > 0 {
                    if let focus = configuration.controller.focusAnchor {
                        table.selectRowIndexes(IndexSet(integer: focus), byExtendingSelection: false)
                    }
                    if let clipView = table.enclosingScrollView?.contentView {
                        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: table.rect(ofRow: anchor).minY - (table.headerView?.frame.height ?? 0)))
                        table.enclosingScrollView?.reflectScrolledClipView(clipView)
                    }
                }
            } else {
                refreshVisibleRows(reloadCells: false)
            }
            if pendingSelection?.selectionVersion != configuration.selectionVersion() {
                pendingSelection = nil
            }
            if let focusedRow = configuration.controller.row(at: table.selectedRow) {
                configuration.onFocus(focusedRow.id, table.selectedRow)
            }
            if let pendingSelection, pendingSelection.generation == displayedGeneration,
               configuration.controller.row(at: pendingSelection.index) != nil
            {
                select(index: pendingSelection.index, modifiers: pendingSelection.modifiers)
            }
            reportViewport()
        }

        private func refreshVisibleRows(reloadCells: Bool, changedRows: IndexSet? = nil) {
            guard let table else { return }
            let visible = table.rows(in: table.contentVisibleRect)
            guard visible.location != NSNotFound, visible.location < configuration.controller.totalCount else { return }
            let range = visible.location ..< min(NSMaxRange(visible), configuration.controller.totalCount)
            if reloadCells {
                table.reloadData(forRowIndexes: (changedRows ?? IndexSet(integersIn: range)).intersection(IndexSet(integersIn: range)), columnIndexes: IndexSet(integersIn: 0 ..< configuration.columns.count))
            }
            for index in range {
                if let view = table.rowView(atRow: index, makeIfNecessary: false) as? PagedTableRowView {
                    view.logicallySelected = configuration.controller.row(at: index).map { row in configuration.isSelected(row.id) } ?? false
                }
            }
        }

        private func reportViewport() {
            guard viewportTask == nil else { return }
            viewportTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                viewportTask = nil
                guard let table else { return }
                let visible = table.rows(in: table.contentVisibleRect)
                guard visible.location != NSNotFound else { return }
                configuration.controller.setViewport(visible.location ..< NSMaxRange(visible))
            }
        }
    }
}
