import AppKit

/// Song-family row controls, supplied by the Library model.
struct LibraryFamilyControls {
    let state: (Int64) -> LibraryFamilyState?
    let setExpanded: (Bool, Int64) -> Void
    let setAlternatesSelected: (Bool, Int64) -> Void
}

enum LibraryBrowserColumns {
    private static let statusIdentifier = "status"
    private static let previewIdentifier = "preview"
    private static let versionsIdentifier = "versions"
    private static let alternatesIdentifier = "alternates"
    static func make(showsFilenames: Bool, density: AppDensity, readiness: LibrarySyncReadiness? = nil,
                     preview: AudioPreviewPlayer? = nil, families: LibraryFamilyControls? = nil) -> [PagedTableColumn<BrowserRow>]
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
        let familyColumns = families.map { controls in
            [
                PagedTableColumn<BrowserRow>(identifier: versionsIdentifier, title: LibraryFamilyMessages.versionsColumn, width: 230,
                                             makeCell: { LibraryFamilyDisclosureCell() }, updateCell: { view, row in
                                                 guard let cell = view as? LibraryFamilyDisclosureCell else { preconditionFailure("Unexpected versions cell") }
                                                 cell.update(row: row, controls: controls, density: density)
                                             }, sortable: false),
                PagedTableColumn<BrowserRow>(identifier: alternatesIdentifier, title: LibraryFamilyMessages.includeAlternates, width: 150,
                                             makeCell: { LibraryFamilyInclusionCell() }, updateCell: { view, row in
                                                 guard let cell = view as? LibraryFamilyInclusionCell else { preconditionFailure("Unexpected alternates cell") }
                                                 cell.update(row: row, controls: controls, density: density)
                                             }, sortable: false),
            ]
        } ?? []
        return previewColumns + familyColumns + definitions.map { column, title, width in
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
    private var indent: CGFloat = 0

    init() {
        super.init(frame: .zero)
        primary.lineBreakMode = .byTruncatingTail
        primary.maximumNumberOfLines = 1
        addSubview(primary)
        textField = primary
    }

    override func layout() {
        super.layout()
        var content = bounds.insetBy(dx: 4, dy: 1)
        content.origin.x += indent
        content.size.width = max(0, content.width - indent)
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
        indent = column == .title && row?.familyRole == .alternate ? 16 : 0
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

/// Version count, selection count, and a text-labelled Show/Hide control for a family's main row.
private final class LibraryFamilyDisclosureCell: NSTableCellView {
    private let summary = NSTextField(labelWithString: "")
    private let toggle = NSButton(title: "", target: nil, action: nil)
    private var familyID: Int64?
    private var expanded = false
    private var controls: LibraryFamilyControls?

    init() {
        super.init(frame: .zero)
        summary.lineBreakMode = .byTruncatingTail
        toggle.bezelStyle = .inline
        toggle.target = self
        toggle.action = #selector(disclose)
        addSubview(summary)
        addSubview(toggle)
        textField = summary
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Versions cells are created programmatically")
    }

    override func layout() {
        super.layout()
        let content = bounds.insetBy(dx: 4, dy: 1)
        let buttonWidth = toggle.isHidden ? 0 : min(content.width / 2, toggle.intrinsicContentSize.width)
        toggle.frame = NSRect(x: content.maxX - buttonWidth, y: content.midY - 9, width: buttonWidth, height: 18)
        summary.frame = NSRect(x: content.minX, y: content.minY, width: max(0, content.width - buttonWidth - 4), height: content.height)
    }

    func update(row: BrowserRow?, controls: LibraryFamilyControls, density: AppDensity) {
        self.controls = controls
        needsLayout = true
        summary.font = .systemFont(ofSize: density == .compact ? 11 : 13)
        summary.textColor = .secondaryLabelColor
        toggle.isHidden = true
        summary.toolTip = nil
        familyID = nil
        guard let row, let familyID = row.familyId, let role = row.familyRole else {
            summary.stringValue = ""
            return
        }
        switch role {
        case .standalone:
            summary.stringValue = ""
        case .alternate:
            summary.stringValue = LibraryFamilyMessages.alternate
        case .main:
            let state = controls.state(familyID)
            summary.stringValue = LibraryFamilyMessages.versions(row.familyVersions ?? 1, selected: state?.selectedCount ?? 0)
            summary.toolTip = LibraryFamilyMessages.versionsHelp
            summary.textColor = .labelColor
            guard let state, state.alternateCount > 0 || state.isRevealedBySearch else { return }
            self.familyID = familyID
            expanded = state.isExpanded
            toggle.isHidden = false
            toggle.isEnabled = !state.isRevealedBySearch
            toggle.title = state.disclosureLabel
            toggle.toolTip = state.isRevealedBySearch ? LibraryFamilyMessages.searchRevealHelp : LibraryFamilyMessages.versionsHelp
            toggle.setAccessibilityLabel(LibraryFamilyMessages.disclosureAccessibility(state.disclosureLabel, title: row.title ?? row.filenameOnly))
            toggle.setAccessibilityExpanded(state.isShowingAlternates)
        }
    }

    @objc private func disclose() {
        guard let familyID else { return }
        controls?.setExpanded(!expanded, familyID)
    }
}

/// The per-family Include alternates checkbox, mixed when some eligible alternates are selected.
private final class LibraryFamilyInclusionCell: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: LibraryFamilyMessages.includeAlternates, target: nil, action: nil)
    private var familyID: Int64?
    private var coverage = BatchSelection.Coverage.none
    private var controls: LibraryFamilyControls?

    init() {
        super.init(frame: .zero)
        checkbox.allowsMixedState = true
        checkbox.target = self
        checkbox.action = #selector(toggleAlternates)
        checkbox.toolTip = LibraryFamilyMessages.familyIncludeAlternatesHelp
        addSubview(checkbox)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Alternates cells are created programmatically")
    }

    override func layout() {
        super.layout()
        checkbox.frame = bounds.insetBy(dx: 4, dy: 1)
    }

    func update(row: BrowserRow?, controls: LibraryFamilyControls, density: AppDensity) {
        self.controls = controls
        checkbox.font = .systemFont(ofSize: density == .compact ? 11 : 13)
        guard let row, row.familyRole == .main, let familyID = row.familyId, let state = controls.state(familyID), state.alternateCount > 0 else {
            checkbox.isHidden = true
            familyID = nil
            return
        }
        self.familyID = familyID
        coverage = state.alternatesCoverage
        checkbox.isHidden = false
        checkbox.isEnabled = !state.eligibleAlternates.isEmpty
        checkbox.state = switch coverage {
        case .none: .off
        case .partial: .mixed
        case .all: .on
        }
        checkbox.setAccessibilityLabel("\(LibraryFamilyMessages.includeAlternates) for \(row.title ?? row.filenameOnly)")
    }

    @objc private func toggleAlternates() {
        guard let familyID else { return }
        controls?.setAlternatesSelected(coverage != .all, familyID)
    }
}
