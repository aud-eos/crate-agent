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
    var enabled = true
    var onFocus: (Snapshot.Row.ID?, Int) -> Void = { _, _ in }

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
        private var boundsObserver: NSObjectProtocol?
        private var displayedGeneration: UInt64 = 0
        private var rangeAnchor: Int?
        private var pendingSelection: (generation: UInt64, index: Int, modifiers: NSEvent.ModifierFlags)?
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
            subscription = configuration.controller.$updateID.receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }
            displayedGeneration = configuration.controller.generation
            table.reloadData()
            return scroll
        }

        func update(_ configuration: PagedTable) {
            let geometryChanged = self.configuration.rowHeight != configuration.rowHeight
            self.configuration = configuration
            if geometryChanged {
                table?.rowHeight = configuration.rowHeight
                table?.reloadData()
            }
            refreshVisibleRows(reloadCells: true)
            reportViewport()
        }

        func stop() {
            subscription?.cancel()
            subscription = nil
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
                  let column = configuration.columns.first(where: { $0.identifier == tableColumn.identifier.rawValue }) else { return nil }
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) ?? column.makeCell()
            cell.identifier = tableColumn.identifier
            column.updateCell(cell, configuration.controller.row(at: index))
            return cell
        }

        func tableView(_: NSTableView, rowViewForRow index: Int) -> NSTableRowView? {
            let view = PagedTableRowView()
            let row = configuration.controller.row(at: index)
            view.logicallySelected = row.map { configuration.isSelected($0.id) } ?? false
            view.setAccessibilityLabel(row == nil ? PagingLabels.loading : nil)
            return view
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            let identifier = tableColumn.identifier.rawValue
            guard configuration.columns.contains(where: { $0.identifier == identifier && $0.sortable }) else { return }
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
                pendingSelection = (configuration.controller.generation, index, modifiers)
                configuration.controller.setViewport(index ..< (index + 1))
            }
        }

        private func reload() {
            guard let table else { return }
            if displayedGeneration != configuration.controller.generation || table.numberOfRows != configuration.controller.totalCount {
                displayedGeneration = configuration.controller.generation
                pendingSelection = nil
                rangeAnchor = nil
                table.deselectAll(nil)
                table.reloadData()
                if let anchor = configuration.controller.viewportAnchor, table.numberOfRows > 0 {
                    table.focusRow(anchor, modifiers: [], selecting: false)
                }
            } else {
                refreshVisibleRows(reloadCells: true)
            }
            if let pendingSelection, pendingSelection.generation == displayedGeneration,
               configuration.controller.row(at: pendingSelection.index) != nil
            {
                select(index: pendingSelection.index, modifiers: pendingSelection.modifiers)
            }
            reportViewport()
        }

        private func refreshVisibleRows(reloadCells: Bool) {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            let range = visible.location ..< min(NSMaxRange(visible), configuration.controller.totalCount)
            if reloadCells {
                table.reloadData(forRowIndexes: IndexSet(integersIn: range), columnIndexes: IndexSet(integersIn: 0 ..< configuration.columns.count))
            }
            for index in range {
                if let view = table.rowView(atRow: index, makeIfNecessary: false) as? PagedTableRowView {
                    view.logicallySelected = configuration.controller.row(at: index).map { configuration.isSelected($0.id) } ?? false
                }
            }
        }

        private func reportViewport() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            configuration.controller.setViewport(visible.location ..< NSMaxRange(visible))
        }
    }
}
