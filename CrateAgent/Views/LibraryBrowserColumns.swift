import AppKit

enum LibraryBrowserColumns {
    private static let statusIdentifier = "status"
    static func make(showsFilenames: Bool, density: AppDensity) -> [PagedTableColumn<BrowserRow>] {
        let definitions: [(LibraryBrowseSort.Column?, String, CGFloat)] = [
            (.artist, "Artist", 220), (.title, "Title", 280), (.bpm, "BPM", 70),
            (.musicalKey, "Key", 50), (.album, "Album", 200), (nil, "Status", 240), (.path, "Folder", 240),
        ]
        return definitions.map { column, title, width in
            let identifier = column?.rawValue ?? statusIdentifier
            return PagedTableColumn(identifier: identifier, title: title, width: width, makeCell: { LibraryBrowserCell() }, updateCell: { view, row in
                guard let cell = view as? LibraryBrowserCell else { preconditionFailure("Unexpected Library cell") }
                cell.update(row: row, column: column, title: title, showsFilenames: showsFilenames, density: density)
            }, sortable: column != nil)
        }
    }
}

private final class LibraryBrowserCell: NSTableCellView {
    private let primary = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        for label in [primary, secondary] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        textField = primary
    }

    override func layout() {
        super.layout()
        let content = bounds.insetBy(dx: 4, dy: 1)
        if secondary.isHidden {
            primary.frame = content
        } else {
            let detailHeight: CGFloat = 13
            secondary.frame = NSRect(x: content.minX, y: content.minY, width: content.width, height: detailHeight)
            primary.frame = NSRect(x: content.minX, y: content.minY + detailHeight, width: content.width, height: max(0, content.height - detailHeight))
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func update(row: BrowserRow?, column: LibraryBrowseSort.Column?, title: String, showsFilenames: Bool, density: AppDensity) {
        needsLayout = true
        primary.font = .systemFont(ofSize: density == .compact ? 11 : 13)
        secondary.font = .systemFont(ofSize: density == .compact ? 10 : 11)
        primary.textColor = .labelColor
        secondary.textColor = .secondaryLabelColor
        secondary.isHidden = true
        primary.maximumNumberOfLines = column == nil ? 2 : 1
        guard let row else {
            primary.stringValue = column == .title ? PagingLabels.loading : ""
            primary.textColor = .tertiaryLabelColor
            toolTip = nil
            setAccessibilityLabel(PagingLabels.loading)
            return
        }
        switch column {
        case .artist:
            primary.stringValue = row.artist ?? "—"
            primary.textColor = row.artist == nil ? .tertiaryLabelColor : .labelColor
        case .title:
            primary.stringValue = row.title ?? row.filenameOnly
            primary.textColor = row.title == nil ? .secondaryLabelColor : .labelColor
            secondary.stringValue = row.filenameOnly
            secondary.isHidden = !showsFilenames || row.title == nil || row.title == row.filenameOnly
        case .bpm:
            primary.stringValue = row.bpm ?? ""
            primary.font = .monospacedDigitSystemFont(ofSize: density == .compact ? 11 : 13, weight: .regular)
            primary.textColor = .secondaryLabelColor
        case .musicalKey: primary.stringValue = row.musicalKey ?? ""
        case .album: primary.stringValue = row.album ?? ""
        case .none:
            primary.stringValue = row.statusText
            primary.textColor = row.canProcess ? .secondaryLabelColor : .systemOrange
        case .path:
            primary.stringValue = row.folderPath
            primary.textColor = .secondaryLabelColor
        }
        toolTip = column == nil ? row.statusText : row.path
        setAccessibilityLabel("\(title): \(primary.stringValue)")
    }
}
