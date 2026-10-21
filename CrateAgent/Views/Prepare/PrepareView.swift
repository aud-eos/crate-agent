import SwiftUI

/// Prepare works through the unfinished tracks one at a time, most promising first
/// (`PrepareRanking`). It runs the Library query with the Needs work chip and the same
/// search, chips and facet filters, so every fix is offered from the same facts the
/// Library shows. Every action goes through the services the Library uses.
struct PrepareView: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @EnvironmentObject private var services: AppServices
    @State private var model: LibraryBrowserModel?
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var debouncedSearch = ""

    var body: some View {
        VStack(spacing: 0) {
            PageHeading(PrepareMessages.sectionTitle, subtitle: PrepareMessages.subtitle).padding(density.pagePadding)
            SeratoRunningBanner(message: PrepareMessages.trashWhileSeratoRunning)
            if let loadError {
                ActionErrorMessage(message: loadError).padding(density.pagePadding)
            }
            ListSearchField(text: $searchText).padding(.horizontal, density.pagePadding).padding(.vertical, density.spacing)
            if let model {
                LibraryFacetBar(facets: Binding(get: { model.query.facets }, set: { facets in model.setFacets(facets) }), options: model.facetOptions)
                    .padding(.horizontal, density.pagePadding).padding(.bottom, density.spacing)
                Divider()
                PrepareCardPager(model: model)
            } else if loadError == nil {
                ProgressView("Loading library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Button(PagingLabels.retry) { Task { await initializeModel() } }
                Spacer()
            }
        }
        .frame(minWidth: 920, minHeight: 600)
        .appPresentation()
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, debouncedSearch != searchText else { return }
            debouncedSearch = searchText
        }
        .task { await initializeModel() }
        .onChange(of: debouncedSearch) { _, _ in updateQuery() }
        .onDisappear { model?.stop(); model = nil }
    }

    private func initializeModel() async {
        guard model == nil else { return }
        do {
            let browser = try LibraryBrowserModel(database: services.database)
            model = browser
            loadError = nil
            var query = browser.query
            query.filter = .active
            query.chip = .needsWork
            query.sort = .init(column: .prepareRank, ascending: false)
            browser.setQuery(query)
            await browser.start()
        } catch { loadError = error.localizedDescription }
    }

    private func updateQuery() {
        guard let model else { return }
        var query = model.query
        query.search = debouncedSearch
        model.setQuery(query)
    }
}

/// One card at a time over the model's results, with Previous and Next.
private struct PrepareCardPager: View {
    @ObservedObject var model: LibraryBrowserModel
    @EnvironmentObject private var services: AppServices
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    @State private var index = 0
    @State private var notice: String?
    @State private var actionError: String?
    @State private var trashCandidate: FileRecord?
    @State private var isActing = false

    private var total: Int {
        model.results.totalCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            if let message = model.error ?? model.results.error {
                HStack { ActionErrorMessage(message: message); Button(PagingLabels.retry) { model.retry(); model.results.retry() } }
            }
            if let actionError {
                ActionErrorMessage(message: actionError)
            } else if let notice {
                ActionNoticeMessage(message: notice)
            }
            if total == 0 {
                if model.isRefreshing || model.results.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AppEmptyState(title: PrepareMessages.emptyTitle, detail: PrepareMessages.emptyDetail, systemImage: "checkmark.circle")
                }
            } else {
                HStack(spacing: density.spacing) {
                    Text(PrepareMessages.position(index, of: total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button(PrepareMessages.previous) { move(by: -1) }.disabled(index == 0)
                    Button(PrepareMessages.next) { move(by: 1) }.disabled(index >= total - 1)
                }
                if let row = model.results.row(at: index) {
                    PrepareCard(row: row.applyingConflictScope(services.readiness), isActing: isActing, perform: { action in Task { await perform(action, row: row) } })
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(density.pagePadding)
        .onAppear { load() }
        .onChange(of: index) { _, _ in load() }
        .onChange(of: model.query) { _, _ in
            index = 0
            load()
        }
        .onChange(of: total) { _, _ in load() }
        .onChange(of: model.results.updateID) { _, _ in
            if let anchor = model.results.viewportAnchor, anchor != index, model.results.row(at: index) == nil {
                index = anchor
            }
            load()
        }
        .alert(PrepareMessages.confirmTrashTitle(trashCandidate?.filenameOnly ?? ""), isPresented: Binding(get: { trashCandidate != nil }, set: {
            shown in if !shown {
                trashCandidate = nil
            }
        }),
        presenting: trashCandidate) { candidate in
            Button(PrepareMessages.moveToTrash, role: .destructive) { Task { await moveToTrash(candidate) } }
            Button(PrepareMessages.cancel, role: .cancel) {}
        } message: { candidate in
            Text(PrepareMessages.confirmTrashMessage(frees: candidate.fileSize))
        }
    }

    private func move(by offset: Int) {
        index = max(0, min(total - 1, index + offset))
    }

    /// Clamps the index when the list shrinks and asks for the card's row.
    private func load() {
        if total > 0, index >= total {
            index = total - 1
        }
        guard total > 0 else { return }
        model.results.setViewport(index ..< index + 1)
    }

    private func perform(_ action: PrepareCardAction, row: BrowserRow) async {
        actionError = nil
        notice = nil
        isActing = true
        defer { isActing = false }
        do {
            switch action {
            case .fixTags:
                let session = services.autoTagSession
                guard !session.isScanning, !session.isApplying, session.scannedFileIDs.isEmpty else { throw PrepareActionError.autoTagBusy }
                session.selectVisibleFileIDs([row.id])
                guard session.selectedFileIDs.contains(row.id) else {
                    throw PrepareActionError.notSelectable(session.actionError ?? row.processingBlockReason ?? PrepareMessages.notSelectable)
                }
                services.open(.autoTag)
            case let .openInSerato(application):
                _ = try await model.resolveFile(id: row.id)
                await services.fileOpener.open(fileID: row.id, with: .application(application))
            case let .keeper(isKeeper):
                _ = try await services.operationEngine.setKeeper(isKeeper, for: FileMembershipToken(fileId: row.id, revision: row.membershipRevision))
            case let .addToCrate(crateFileName):
                _ = try await services.operationEngine.apply(.setCrateMembership(.init(fileId: row.id, crateFileName: crateFileName, present: true)),
                                                             expectedMembershipToken: FileMembershipToken(fileId: row.id, revision: row.membershipRevision),
                                                             batchId: "prepare:\(UUID().uuidString)")
                notice = PrepareMessages.addedToCrate(PrepareMessages.crateDisplayName(crateFileName))
            case .showVersions:
                let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                services.showInLibrary(search: title.isEmpty ? row.path : title)
            case .moveToTrash:
                let record = try await model.resolveFile(id: row.id)
                try FileProcessingEligibility.requireProcessable(record)
                try services.readiness.requireUnconflicted(.file(record))
                trashCandidate = record
            }
        } catch { actionError = error.localizedDescription }
    }

    private func moveToTrash(_ record: FileRecord) async {
        isActing = true
        defer { isActing = false }
        do {
            let result = try await services.operationEngine.removeFile(target: record, batchID: "prepare:\(UUID().uuidString)")
            switch result {
            case .completed: notice = PrepareMessages.movedToTrash(record.filenameOnly)
            case .pending: notice = PrepareMessages.removalQueued(record.filenameOnly)
            case let .failed(message), let .superseded(message): actionError = message
            }
        } catch { actionError = error.localizedDescription }
    }
}

enum PrepareCardAction {
    case fixTags
    case addToCrate(String)
    case openInSerato(OpenApplication)
    case keeper(Bool)
    case showVersions
    case moveToTrash
}

private enum PrepareActionError: LocalizedError {
    case autoTagBusy
    case notSelectable(String)

    var errorDescription: String? {
        switch self {
        case .autoTagBusy: PrepareMessages.autoTagBusy
        case let .notSelectable(reason): PrepareMessages.couldNotSelect(reason)
        }
    }
}

/// What one track still needs, its signals, and the fixes on offer.
private struct PrepareCard: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let row: BrowserRow
    let isActing: Bool
    let perform: (PrepareCardAction) -> Void
    @State private var crateFileNames: [String] = []

    private var display: StillNeedsDisplay {
        StillNeedsDisplay(row: row)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            HStack(alignment: .firstTextBaseline, spacing: density.spacing) {
                TrackPlayButton(player: services.trackPlayer, track: PlayerTrack(row), isAvailable: row.fileAvailability == .available)
                VStack(alignment: .leading, spacing: density.detailSpacing) {
                    Text(row.title ?? row.filenameOnly).font(.title2.weight(.semibold))
                    Text(row.artist ?? "").font(.body).foregroundStyle(.secondary)
                    Text(details).font(.callout).foregroundStyle(.secondary)
                    Text(row.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
            Text(PrepareMessages.stillNeedsHeading).font(.headline)
            stillNeeds
            Text(PrepareMessages.signalsHeading).font(.headline)
            Text(signals).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            actions
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(density.pagePadding)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PlayerTrack(row).displayTitle)
    }

    @ViewBuilder private var stillNeeds: some View {
        let parts = display.parts
        ForEach(parts.indices, id: \.self) { position in
            Text(parts[position].text).foregroundStyle(Color(nsColor: parts[position].color))
        }
        if let help = display.help, !help.isEmpty {
            Text(help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var details: String {
        [row.album, row.bpm.map { bpm in "\(bpm) BPM" }, row.musicalKey, row.bitrateKbps.map { kbps in "\(kbps) kbps" }]
            .compactMap { part in part?.isEmpty == false ? part : nil }.joined(separator: LibraryChecklistMessages.tagSeparator)
    }

    private var signals: String {
        let sourcesOn = services.popularityService.enabledSources.isEmpty == false
        func score(_ value: Double?) -> String {
            if let value {
                return Int(value.rounded()).formatted()
            }
            return sourcesOn ? LibraryChecklistMessages.unknown : PopularityMessages.off
        }
        return [
            PrepareMessages.signal(PopularityMessages.title, score(row.popularityAllTime)),
            PrepareMessages.signal(PopularityMessages.hotTitle, score(row.popularityHot)),
            PrepareMessages.signal(LibraryChecklistMessages.myPlaysColumn, row.playCount.map { plays in plays.formatted() } ?? LibraryChecklistMessages.unknown),
        ].joined(separator: LibraryChecklistMessages.tagSeparator)
    }

    private var seratoApplication: OpenApplication? {
        let opener = services.fileOpener
        return ([opener.defaultApplication(for: row.path)].compactMap { application in application } + opener.otherApplications(for: row.path))
            .first { application in application.name.hasPrefix(PrepareMessages.seratoApplicationPrefix) }
    }

    private var actions: some View {
        HStack(spacing: density.spacing) {
            Button(PrepareMessages.fixTags) { perform(.fixTags) }
                .disabled(!row.canProcess || isActing).help(row.processingBlockReason ?? PrepareMessages.fixTagsHelp)
            Button(PrepareMessages.openInSerato) {
                if let seratoApplication {
                    perform(.openInSerato(seratoApplication))
                }
            }
            .disabled(seratoApplication == nil || isActing).help(seratoApplication == nil ? PrepareMessages.seratoNotInstalled : PrepareMessages.openInSeratoHelp)
            Menu(PrepareMessages.addToCrate) {
                ForEach(crateFileNames, id: \.self) { crateFileName in
                    Button(PrepareMessages.crateDisplayName(crateFileName)) { perform(.addToCrate(crateFileName)) }
                }
            }
            .fixedSize()
            .disabled(!row.canProcess || isActing || crateFileNames.isEmpty)
            .seratoWriteGated(help: crateFileNames.isEmpty ? PrepareMessages.noCrates : row.processingBlockReason ?? PrepareMessages.addToCrateHelp,
                              runningHelp: PrepareMessages.crateWhileSeratoRunning)
            .onAppear { crateFileNames = (try? services.seratoLocator.enumerateCrateFiles().map(\.lastPathComponent).sorted()) ?? [] }
            if row.hasChecklist, let isProtected = row.isProtected {
                Button(isProtected ? LibraryChecklistMessages.clearKeeper : LibraryChecklistMessages.markKeeper) { perform(.keeper(!isProtected)) }
                    .disabled(isActing).help(LibraryChecklistMessages.keeperMenuHelp)
            }
            if row.familyId != nil {
                Button(PrepareMessages.showVersions) { perform(.showVersions) }.help(PrepareMessages.showVersionsHelp)
            }
            Spacer()
            Button(PrepareMessages.moveToTrash, role: .destructive) { perform(.moveToTrash) }
                .disabled(!row.canProcess || isActing)
                .seratoWriteGated(help: row.processingBlockReason ?? PrepareMessages.moveToTrashHelp, runningHelp: PrepareMessages.trashWhileSeratoRunning)
        }
    }
}
