import AppKit
import SwiftUI

struct PreviewTableColumn<Row> {
    let identifier: String
    let title: String
    let width: CGFloat
    let text: (Row) -> String
}

struct VirtualizedPreviewTable<Row: Identifiable>: NSViewRepresentable {
    let dataID: String
    let accessibilityLabel: String
    let rowCount: Int
    let row: (Int) -> Row
    let columns: [PreviewTableColumn<Row>]
    let accessibilityName: (Row) -> String
    let isSelected: (Row.ID) -> Bool
    let setSelected: (Row.ID, Bool) -> Void
    let selectAll: () -> Void
    let enabled: Bool
    let density: AppDensity
    var sort: ((String, Bool) -> Void)?
    var isSelectable: (Row) -> Bool = { _ in true }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var sortedColumn: String?
        private var ascending = true
        private var configuration: VirtualizedPreviewTable
        private weak var table: PreviewNSTableView?
        private static var selectionColumnID: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("batchSelection")
        }

        init(_ configuration: VirtualizedPreviewTable) {
            self.configuration = configuration
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = false
            let table = PreviewNSTableView()
            self.table = table
            table.dataSource = self
            table.delegate = self
            table.rowHeight = configuration.density.minimumRowHeight
            table.usesAlternatingRowBackgroundColors = true
            table.allowsMultipleSelection = false
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.setAccessibilityLabel(configuration.accessibilityLabel)
            let selectionColumn = NSTableColumn(identifier: Self.selectionColumnID)
            selectionColumn.title = "Select"
            selectionColumn.width = 48
            selectionColumn.minWidth = 48
            selectionColumn.maxWidth = 48
            table.addTableColumn(selectionColumn)
            for column in configuration.columns {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
                tableColumn.title = column.title
                tableColumn.width = column.width
                tableColumn.minWidth = 80
                table.addTableColumn(tableColumn)
            }
            table.toggleFocusedRow = { [weak self] in
                guard let self, let table = self.table, configuration.enabled,
                      table.selectedRow >= 0, table.selectedRow < self.configuration.rowCount else { return }
                let row = configuration.row(table.selectedRow)
                guard configuration.isSelectable(row) else { return }
                configuration.setSelected(row.id, !configuration.isSelected(row.id))
                refreshVisibleCheckboxes()
            }
            table.selectMatchingRows = { [weak self] in
                guard let self, configuration.enabled else { return }
                configuration.selectAll()
                refreshVisibleCheckboxes()
            }
            scrollView.documentView = table
            return scrollView
        }

        func update(_ configuration: VirtualizedPreviewTable) {
            let replaced = self.configuration.dataID != configuration.dataID
            let densityChanged = self.configuration.density != configuration.density
            self.configuration = configuration
            guard let table else { return }
            if replaced || densityChanged {
                table.rowHeight = configuration.density.minimumRowHeight
                if replaced {
                    table.deselectAll(nil)
                }
                table.reloadData()
                if replaced, configuration.rowCount > 0 {
                    table.scrollRowToVisible(0)
                }
            }
            refreshVisibleCheckboxes()
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard configuration.enabled, let sort = configuration.sort,
                  tableColumn.identifier != Self.selectionColumnID else { return }
            let identifier = tableColumn.identifier.rawValue
            ascending = sortedColumn == identifier ? !ascending : true
            sortedColumn = identifier
            for column in tableView.tableColumns {
                tableView.setIndicatorImage(nil, in: column)
            }
            tableView.setIndicatorImage(NSImage(named: ascending ? NSImage.touchBarGoUpTemplateName : NSImage.touchBarGoDownTemplateName), in: tableColumn)
            sort(identifier, ascending)
        }

        func numberOfRows(in _: NSTableView) -> Int {
            configuration.rowCount
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            guard let tableColumn, index >= 0, index < configuration.rowCount else { return nil }
            let row = configuration.row(index)
            if tableColumn.identifier == Self.selectionColumnID {
                let checkbox = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? PreviewCheckbox ?? PreviewCheckbox()
                checkbox.identifier = tableColumn.identifier
                configure(checkbox, row: row)
                return checkbox
            }
            guard let column = configuration.columns.first(where: { column in column.identifier == tableColumn.identifier.rawValue }) else {
                preconditionFailure("Unknown preview column")
            }
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? PreviewTextCell ?? PreviewTextCell()
            cell.identifier = tableColumn.identifier
            let text = column.text(row)
            cell.label.stringValue = text
            cell.label.font = NSFont.systemFont(ofSize: configuration.density == .compact ? 11 : 13)
            cell.label.setAccessibilityLabel("\(column.title): \(text)")
            cell.toolTip = text
            return cell
        }

        private func configure(_ checkbox: PreviewCheckbox, row: Row) {
            checkbox.title = ""
            checkbox.state = configuration.isSelected(row.id) ? .on : .off
            let selectable = configuration.isSelectable(row)
            checkbox.isHidden = !selectable
            checkbox.setAccessibilityElement(selectable)
            checkbox.isEnabled = configuration.enabled && selectable
            checkbox.controlSize = configuration.density == .compact ? .small : .regular
            checkbox.setAccessibilityLabel("Select \(configuration.accessibilityName(row))")
            let dataID = configuration.dataID
            let identifier = row.id
            checkbox.onPress = { [weak self] in
                guard let self, selectable, configuration.enabled, configuration.dataID == dataID else { return }
                configuration.setSelected(identifier, !configuration.isSelected(identifier))
                refreshVisibleCheckboxes()
            }
        }

        private func refreshVisibleCheckboxes() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            for index in visible.location ..< min(NSMaxRange(visible), configuration.rowCount) {
                if let checkbox = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? PreviewCheckbox {
                    configure(checkbox, row: configuration.row(index))
                }
            }
        }
    }
}

final class PreviewNSTableView: NSTableView {
    var toggleFocusedRow: (() -> Void)?
    var selectMatchingRows: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            toggleFocusedRow?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func selectAll(_: Any?) {
        selectMatchingRows?()
    }
}

final class PreviewCheckbox: NSButton {
    var onPress: (() -> Void)?

    init() {
        super.init(frame: .zero)
        setButtonType(.switch)
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc private func pressed() {
        onPress?()
    }
}

private final class PreviewTextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

struct BatchSelectionToggle: NSViewRepresentable {
    let title: String
    let coverage: BatchSelection.Coverage
    let enabled: Bool
    let setSelected: (Bool) -> Void

    func makeNSView(context _: Context) -> PreviewCheckbox {
        PreviewCheckbox()
    }

    func updateNSView(_ button: PreviewCheckbox, context _: Context) {
        button.title = title
        button.allowsMixedState = true
        button.state = coverage == .all ? .on : coverage == .partial ? .mixed : .off
        button.isEnabled = enabled
        button.onPress = { setSelected(coverage != .all) }
        button.setAccessibilityLabel(title)
    }
}
