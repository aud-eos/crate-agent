import AppKit

/// Song-family row controls, supplied by the Library model.
struct LibraryFamilyControls {
    let state: (Int64) -> LibraryFamilyState?
    let setExpanded: (Bool, Int64) -> Void
    let setAlternatesSelected: (Bool, Int64) -> Void
    let setHiddenSelected: (Bool, Int64) -> Void
}

enum LibraryBrowserColumns {
    private static let statusIdentifier = "status"
    private static let previewIdentifier = "preview"
    private static let versionsIdentifier = "versions"
    private static let alternatesIdentifier = "alternates"
    /// `popularityEnabled` says whether any popularity source is on; while none is, the two popularity columns read "off".
    static func make(showsFilenames: Bool, density: AppDensity, readiness: LibrarySyncReadiness? = nil,
                     player: TrackPlayer? = nil, families: LibraryFamilyControls? = nil,
                     popularityEnabled: @escaping () -> Bool = { false }) -> [PagedTableColumn<BrowserRow>]
    {
        let definitions: [(LibraryBrowseSort.Column?, String, CGFloat)] = [
            (.artist, "Artist", 220), (.title, "Title", 280), (.bpm, "BPM", 70), (.musicalKey, "Key", 50),
            (.stillNeeds, LibraryChecklistMessages.stillNeedsColumn, 240), (.dateAdded, LibraryChecklistMessages.dateAddedColumn, 110),
            (.myPlays, LibraryChecklistMessages.myPlaysColumn, 70), (.popularity, LibraryChecklistMessages.popularityColumn, 80),
            (.hot, LibraryChecklistMessages.hotColumn, 60), (.album, "Album", 200), (nil, "Status", 240), (.path, "Folder", 240),
        ]
        let previewColumns = player.map { player in
            [PagedTableColumn<BrowserRow>(identifier: previewIdentifier, title: "", width: 28, makeCell: { TrackPlayCell() }, updateCell: { view, row in
                guard let cell = view as? TrackPlayCell else { preconditionFailure("Unexpected preview cell") }
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
                PagedTableColumn<BrowserRow>(identifier: alternatesIdentifier, title: LibraryFamilyMessages.includeAlternates, width: 260,
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
                cell.update(row: row?.applyingConflictScope(readiness), column: column, title: title, showsFilenames: showsFilenames, density: density,
                            popularityEnabled: popularityEnabled())
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

    func update(row: BrowserRow?, column: LibraryBrowseSort.Column?, title: String, showsFilenames: Bool, density: AppDensity, popularityEnabled: Bool) {
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
        case .stillNeeds:
            let display = StillNeedsDisplay(row: row)
            primary.attributedStringValue = display.text(font: primary.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            primary.maximumNumberOfLines = 2
            toolTip = display.help
            setAccessibilityLabel("\(title): \(primary.stringValue)")
            return
        case .dateAdded:
            guard row.hasChecklist else { primary.stringValue = ""; break }
            guard let seconds = row.dateAdded else {
                showUnknown()
                break
            }
            primary.stringValue = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .omitted)
            toolTip = row.dateAddedSource.map { source in
                switch source {
                case .serato: LibraryChecklistMessages.dateAddedFromSerato
                case .indexed: LibraryChecklistMessages.dateAddedFirstIndexed
                }
            }
            setAccessibilityLabel("\(title): \(primary.stringValue)")
            return
        case .myPlays:
            guard row.hasChecklist else { primary.stringValue = ""; break }
            guard let plays = row.playCount else {
                showUnknown()
                break
            }
            primary.stringValue = plays.formatted()
            primary.font = .monospacedDigitSystemFont(ofSize: density == .compact ? 11 : 13, weight: .regular)
        case .popularity, .hot:
            guard row.hasChecklist else { primary.stringValue = ""; break }
            guard let score = column == .popularity ? row.popularityAllTime : row.popularityHot else {
                if popularityEnabled {
                    showUnknown()
                } else {
                    showOff()
                }
                setAccessibilityLabel("\(title): \(primary.stringValue)")
                return
            }
            primary.stringValue = Int(score.rounded()).formatted()
            primary.font = .monospacedDigitSystemFont(ofSize: density == .compact ? 11 : 13, weight: .regular)
            toolTip = row.popularityDetail
            setAccessibilityLabel("\(title): \(primary.stringValue)")
            return
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

    private func showUnknown() {
        primary.stringValue = LibraryChecklistMessages.unknown
        primary.textColor = .secondaryLabelColor
    }

    private func showOff() {
        primary.stringValue = PopularityMessages.off
        primary.textColor = .secondaryLabelColor
        toolTip = PopularityMessages.offStatus
    }
}

/// A row's Still needs tags and the tooltip naming each fix. Unknown items read "<tag> unknown" in secondary color;
/// a checklist with unexpected bits shows as unreadable, with the reason in the tooltip.
private struct StillNeedsDisplay {
    private var parts: [(text: String, color: NSColor)] = []
    private(set) var help: String?

    init(row: BrowserRow) {
        let checklist: FileChecklist?
        do {
            checklist = try row.checklist()
        } catch {
            parts = [(LibraryChecklistMessages.unreadable, .systemRed)]
            help = error.localizedDescription
            return
        }
        guard let checklist else { return }
        var sentences: [String] = []
        if checklist.isProtected {
            parts.append((LibraryChecklistMessages.keeperTag, .labelColor))
            sentences.append(LibraryChecklistMessages.keeperHelp)
        } else if checklist.isFinished {
            parts.append((LibraryChecklistMessages.finishedTag, .systemGreen))
            sentences.append(LibraryChecklistMessages.finishedHelp)
        }
        for item in ChecklistItem.allCases {
            if checklist.failing.contains(item) {
                parts.append((LibraryChecklistMessages.tag(item), .labelColor))
                sentences.append(LibraryChecklistMessages.failingHelp(item, missing: checklist.missingMetadata,
                                                                      beatgridMarkerCount: row.beatgridMarkerCount, bitrateKbps: row.bitrateKbps))
            } else if checklist.unknown.contains(item) {
                parts.append((LibraryChecklistMessages.unknownTag(item), .secondaryLabelColor))
                sentences.append(LibraryChecklistMessages.unknownHelp(item))
            }
        }
        if row.familyRole == .main, let needing = row.familyFilesNeedingWork, let total = row.familyFileCount {
            let summary = LibraryChecklistMessages.familyFilesNeedingWork(needing, of: total)
            parts.append((summary, .secondaryLabelColor))
            sentences.append(summary + ".")
        }
        help = sentences.joined(separator: "\n")
    }

    func text(font: NSFont) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: LibraryChecklistMessages.tagSeparator,
                                               attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            text.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: part.color]))
        }
        return text
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
            summary.stringValue = state?.summary(versions: row.familyVersions ?? 1)
                ?? LibraryFamilyMessages.versions(row.familyVersions ?? 1, selected: 0, of: 0, hidden: 0, selectedHidden: 0)
            summary.toolTip = LibraryFamilyMessages.versionsHelp
            summary.textColor = .labelColor
            guard let state, state.alternateCount > 0 || state.isRevealedByFilter else { return }
            self.familyID = familyID
            expanded = state.isExpanded
            toggle.isHidden = false
            toggle.isEnabled = !state.isRevealedByFilter
            toggle.title = state.disclosureLabel
            toggle.toolTip = state.isRevealedByFilter ? LibraryFamilyMessages.searchRevealHelp : LibraryFamilyMessages.versionsHelp
            toggle.setAccessibilityLabel(LibraryFamilyMessages.disclosureAccessibility(state.disclosureLabel, title: row.title ?? row.filenameOnly))
            toggle.setAccessibilityExpanded(state.isShowingAlternates)
        }
    }

    @objc private func disclose() {
        guard let familyID else { return }
        controls?.setExpanded(!expanded, familyID)
    }
}

/// The per-family Include alternates checkbox, mixed when some eligible
/// alternates are selected, and the text button that extends a selection to
/// the members a search or filter hides.
private final class LibraryFamilyInclusionCell: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: LibraryFamilyMessages.includeAlternates, target: nil, action: nil)
    private let hiddenButton = NSButton(title: "", target: nil, action: nil)
    private var familyID: Int64?
    private var coverage = BatchSelection.Coverage.none
    private var selectsHidden = true
    private var controls: LibraryFamilyControls?

    init() {
        super.init(frame: .zero)
        checkbox.allowsMixedState = true
        checkbox.target = self
        checkbox.action = #selector(toggleAlternates)
        checkbox.toolTip = LibraryFamilyMessages.familyIncludeAlternatesHelp
        hiddenButton.bezelStyle = .inline
        hiddenButton.target = self
        hiddenButton.action = #selector(toggleHidden)
        hiddenButton.toolTip = LibraryFamilyMessages.hiddenSelectionHelp
        addSubview(checkbox)
        addSubview(hiddenButton)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Alternates cells are created programmatically")
    }

    override func layout() {
        super.layout()
        let content = bounds.insetBy(dx: 4, dy: 1)
        let buttonWidth = hiddenButton.isHidden ? 0 : min(content.width / 2, hiddenButton.intrinsicContentSize.width)
        hiddenButton.frame = NSRect(x: content.maxX - buttonWidth, y: content.midY - 9, width: buttonWidth, height: 18)
        checkbox.frame = NSRect(x: content.minX, y: content.minY, width: max(0, content.width - buttonWidth - 4), height: content.height)
    }

    func update(row: BrowserRow?, controls: LibraryFamilyControls, density: AppDensity) {
        self.controls = controls
        needsLayout = true
        checkbox.font = .systemFont(ofSize: density == .compact ? 11 : 13)
        hiddenButton.font = checkbox.font
        guard let row, row.familyRole == .main, let familyID = row.familyId, let state = controls.state(familyID),
              state.alternateCount > 0 || state.hiddenSelection != nil
        else {
            checkbox.isHidden = true
            hiddenButton.isHidden = true
            familyID = nil
            return
        }
        self.familyID = familyID
        let title = row.title ?? row.filenameOnly
        if let hidden = state.hiddenSelection {
            hiddenButton.isHidden = false
            hiddenButton.title = hidden.label
            hiddenButton.setAccessibilityLabel(LibraryFamilyMessages.hiddenSelectionAccessibility(hidden.label, title: title))
            selectsHidden = hidden.selects
        } else {
            hiddenButton.isHidden = true
        }
        coverage = state.alternatesCoverage
        checkbox.isHidden = state.alternateCount == 0
        checkbox.isEnabled = !state.eligibleAlternates.isEmpty
        checkbox.state = switch coverage {
        case .none: .off
        case .partial: .mixed
        case .all: .on
        }
        checkbox.setAccessibilityLabel("\(LibraryFamilyMessages.includeAlternates) for \(title)")
    }

    @objc private func toggleAlternates() {
        guard let familyID else { return }
        controls?.setAlternatesSelected(coverage != .all, familyID)
    }

    @objc private func toggleHidden() {
        guard let familyID else { return }
        controls?.setHiddenSelected(selectsHidden, familyID)
    }
}
