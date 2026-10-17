import AppKit

enum LibraryBrowserColumns {
    private static let statusIdentifier = "status"
    private static let previewIdentifier = "preview"
    static func make(showsFilenames: Bool, density: AppDensity, readiness: LibrarySyncReadiness? = nil,
                     preview: AudioPreviewPlayer? = nil) -> [PagedTableColumn<BrowserRow>]
    {
        let definitions: [(LibraryBrowseSort.Column?, String, CGFloat)] = [
            (.artist, "Artist", 220), (.title, "Title", 280), (.bpm, "BPM", 70),
            (.musicalKey, "Key", 50), (.album, "Album", 200), (nil, "Status", 240), (.path, "Folder", 240),
        ]
        let previewColumns = preview.map { player in
            [PagedTableColumn<BrowserRow>(identifier: previewIdentifier, title: "", width: 28, makeCell: { AudioPreviewCell() }, updateCell: { view, row in
                guard let cell = view as? AudioPreviewCell else { preconditionFailure("Unexpected preview cell") }
                cell.update(row: row, player: player)
            }, sortable: false)]
        } ?? []
        return previewColumns + definitions.map { column, title, width in
            let identifier = column?.rawValue ?? statusIdentifier
            return PagedTableColumn(identifier: identifier, title: title, width: width, makeCell: { LibraryBrowserCell() }, updateCell: { view, row in
                guard let cell = view as? LibraryBrowserCell else { preconditionFailure("Unexpected Library cell") }
                cell.update(row: row?.applyingConflictScope(readiness), column: column, title: title, showsFilenames: showsFilenames, density: density)
            }, sortable: column != nil)
        }
    }
}

private final class LibraryBrowserCell: NSTableCellView {
    private let primary = NSTextField(labelWithString: "")
    private var secondary: NSTextField?

    init() {
        super.init(frame: .zero)
        primary.lineBreakMode = .byTruncatingTail
        primary.maximumNumberOfLines = 1
        addSubview(primary)
        textField = primary
    }

    override func layout() {
        super.layout()
        let content = bounds.insetBy(dx: 4, dy: 1)
        if let secondary, !secondary.isHidden {
            let detailHeight: CGFloat = 13
            secondary.frame = NSRect(x: content.minX, y: content.minY, width: content.width, height: detailHeight)
            primary.frame = NSRect(x: content.minX, y: content.minY + detailHeight, width: content.width, height: max(0, content.height - detailHeight))
        } else {
            primary.frame = content
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func update(row: BrowserRow?, column: LibraryBrowseSort.Column?, title: String, showsFilenames: Bool, density: AppDensity) {
        needsLayout = true
        primary.font = .systemFont(ofSize: density == .compact ? 11 : 13)
        primary.textColor = .labelColor
        secondary?.isHidden = true
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
            if showsFilenames, row.title != nil, row.title != row.filenameOnly {
                let detail: NSTextField
                if let secondary {
                    detail = secondary
                } else {
                    detail = NSTextField(labelWithString: "")
                    detail.lineBreakMode = .byTruncatingTail
                    detail.maximumNumberOfLines = 1
                    detail.textColor = .secondaryLabelColor
                    secondary = detail
                    addSubview(detail)
                }
                detail.font = .systemFont(ofSize: density == .compact ? 10 : 11)
                detail.stringValue = row.filenameOnly
                detail.isHidden = false
            }
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
