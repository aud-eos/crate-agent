import Combine
import Foundation
import GRDB

@MainActor
final class LibraryBrowserModel: ObservableObject {
    let results = PagedResultsController<LibraryPagedSnapshot>()
    let selection: PagedSelectionController<LibrarySelectionStore>
    @Published private(set) var query = LibraryBrowseQuery()
    @Published private(set) var isRefreshing = false
    @Published var error: String?
    /// A group or add refused because its files share a recording, which the
    /// user may retry as different recordings (#205).
    @Published var differentRecordingsOffer: LibraryDifferentRecordingsOffer?
    /// Selection and eligibility of each visible family's members, including collapsed alternates.
    @Published private(set) var familyStates: [Int64: LibraryFamilyState] = [:]
    /// How many files each chip matches in the current scope without the chip; loaded after each snapshot's first page.
    /// Nil until the counts for the current search, status and facets have loaded.
    @Published private(set) var chipCounts: [ChecklistChip: ChecklistChipCount]?
    /// The genres and keys the facets can choose from in the status scope; loaded after each snapshot's first page.
    @Published private(set) var facetOptions: LibraryFacetOptions?
    /// Whether Serato History has ever been read, from its persisted stamp; nil until the first snapshot loads it.
    /// Never played and My plays are unknown until it is true.
    @Published private(set) var playCountsKnown: Bool?
    /// Changes whenever a family row's selection or disclosure display changes.
    @Published private(set) var familyRevision: UInt64 = 0
    private let selectionStore: LibrarySelectionStore
    private var familyMembers: [Int64: [LibraryFamilyPlacement]] = [:]
    private var familyTask: Task<Void, Never>?
    private var chipCountTask: Task<Void, Never>?
    private var loadedFamilies: (snapshot: LibraryPagedSnapshot, familyIDs: Set<Int64>)?
    private let database: LibraryDatabase
    private let pool: DatabasePool
    private var observation: AnyDatabaseCancellable?
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var dirty = false
    private var resetViewport = false
    private var active = false
    private var session: UInt64 = 0
    private var queryVersion: UInt64 = 0
    private var focusedID: Int64?
    private var focusedIndex = 0

    init(database: LibraryDatabase) throws {
        guard let pool = database.writer as? DatabasePool else { throw PagingError.unavailableDatabase }
        self.database = database
        self.pool = pool
        selectionStore = try LibrarySelectionStore(database: database)
        selection = PagedSelectionController(provider: selectionStore)
        results.objectWillChange.merge(with: selection.objectWillChange).sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        results.$updateID.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.loadFamilyMembers()
        }.store(in: &subscriptions)
        selection.$visibleSelectedIDs.receive(on: RunLoop.main).sink { [weak self] selected in
            self?.updateFamilyStates(selected: selected)
        }.store(in: &subscriptions)
    }

    /// Identities of every visible row plus every member of the visible families, so
    /// selection state covers alternates while their family is collapsed.
    private var trackedIdentities: [PagedIdentity<Int64>] {
        guard let snapshot = results.snapshot else { return [] }
        let rows = results.cachedRows.map { row in snapshot.identity(for: row) }
        let members = familyMembers.values.flatMap { placements in placements.map(\.identity) }
        return Array(Set(rows + members))
    }

    private func loadFamilyMembers() {
        guard let snapshot = results.snapshot else { return }
        let familyIDs = Set(results.cachedRows.compactMap { row in row.familyRole == .main ? row.familyId : nil })
        if let loadedFamilies, loadedFamilies.snapshot === snapshot, loadedFamilies.familyIDs == familyIDs {
            return
        }
        loadedFamilies = (snapshot, familyIDs)
        familyTask?.cancel()
        familyTask = Task { [weak self] in
            do {
                let members = try await snapshot.familyMembers(familyIDs)
                guard let self, !Task.isCancelled, results.snapshot === snapshot else { return }
                familyMembers = members
                selection.updateVisibleIdentities(trackedIdentities)
                updateFamilyStates(selected: selection.visibleSelectedIDs)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                loadedFamilies = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func updateFamilyStates(selected: Set<Int64>) {
        var states: [Int64: LibraryFamilyState] = [:]
        for (familyID, members) in familyMembers {
            states[familyID] = LibraryFamilyState(members: members, selected: selected, isExpanded: query.expandedFamilies.contains(familyID),
                                                  isFiltering: query.isFiltering)
        }
        guard states != familyStates else { return }
        familyStates = states
        familyRevision &+= 1
    }

    func setExpanded(_ expanded: Bool, family familyID: Int64) {
        var updated = query
        if expanded {
            updated.expandedFamilies.insert(familyID)
        } else {
            updated.expandedFamilies.remove(familyID)
        }
        apply(updated, reset: false)
        updateFamilyStates(selected: selection.visibleSelectedIDs)
    }

    /// Right and Left Arrow on a row: expands or collapses a main row, and Left on an
    /// alternate collapses its family onto the main row. Returns false when nothing
    /// changes, so the key keeps its usual meaning.
    func disclose(_ expand: Bool, row rowID: Int64) -> Bool {
        guard !query.isFiltering, let row = results.cachedRows.first(where: { row in row.id == rowID }),
              let familyID = row.familyId, let state = familyStates[familyID]
        else { return false }
        switch row.familyRole {
        case .main:
            guard state.alternateCount > 0, state.isExpanded != expand else { return false }
        case .alternate:
            guard !expand, let mainID = state.mainID else { return false }
            focusedID = mainID
        case .standalone, nil:
            return false
        }
        setExpanded(expand, family: familyID)
        return true
    }

    /// Whether Library shows the family columns: only when a family is in view.
    var showsFamilies: Bool {
        results.snapshot?.hasFamilies == true
    }

    /// How many files a family command on `row` acts on.
    func familyTargetCount(for row: BrowserRow) -> Int {
        selection.visibleSelectedIDs.contains(row.id) ? selection.summary?.inScope ?? 1 : 1
    }

    /// The clicked row alone, or the selection when the row is selected. Selected
    /// files the view no longer shows are left out; one that changed since it
    /// was selected refuses the command.
    func familyActionTarget(for row: BrowserRow) async throws -> LibraryFamilyActionTarget {
        guard let snapshot = results.snapshot else { throw PagingError.unavailableDatabase }
        guard selection.visibleSelectedIDs.contains(row.id) else {
            return LibraryFamilyActionTarget(clicked: row, files: [snapshot.identity(for: row)])
        }
        let files = try await selectionStore.selectedIdentities(in: snapshot, limit: LibraryFamilyMessages.selectionLimit)
        return LibraryFamilyActionTarget(clicked: row, files: files)
    }

    func performFamilyAction(_ action: LibraryFamilyAction, on row: BrowserRow, using actions: LibraryFamilyActions,
                             asDifferentRecordings: Bool = false) async
    {
        differentRecordingsOffer = nil
        do {
            try await actions.perform(action, on: familyActionTarget(for: row), asDifferentRecordings: asDifferentRecordings)
        } catch let SongFamilyError.fingerprintCollision(file, otherFile) where !asDifferentRecordings && action.differentRecordingsTitle != nil {
            let message = SongFamilyError.fingerprintCollision(file: file, otherFile: otherFile).localizedDescription
            differentRecordingsOffer = LibraryDifferentRecordingsOffer(action: action, row: row, actions: actions, message: message)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func acceptDifferentRecordingsOffer() async {
        guard let offer = differentRecordingsOffer else { return }
        await performFamilyAction(offer.action, on: offer.row, using: offer.actions, asDifferentRecordings: true)
    }

    /// Shows only the files `chip` matches, or every file for nil.
    func setChip(_ chip: ChecklistChip?) {
        var updated = query
        updated.chip = chip
        apply(updated, reset: true)
    }

    /// Shows only the files `facets` match. The compatible key matches the stored key strings
    /// the loaded options resolve it to; they are resolved again whenever the options reload.
    func setFacets(_ facets: LibraryFacets) {
        var updated = query
        updated.facets = resolved(facets)
        apply(updated, reset: true)
    }

    private func resolved(_ facets: LibraryFacets) -> LibraryFacets {
        var resolved = facets
        resolved.keyValues = facets.compatibleKey.map { key in facetOptions?.keyValues(compatibleWith: key) ?? [] } ?? []
        return resolved
    }

    /// Counts and facet options load in their own task after the page, so they never delay it; a newer snapshot cancels them.
    private func loadChipCounts(for snapshot: LibraryPagedSnapshot) {
        chipCountTask?.cancel()
        chipCountTask = Task { [weak self] in
            do {
                let counts = try await snapshot.chipCounts()
                let options = try await snapshot.facetOptions()
                let playsKnown = try await snapshot.playCountsKnown()
                guard let self, !Task.isCancelled, results.snapshot === snapshot else { return }
                chipCounts = counts
                facetOptions = options
                playCountsKnown = playsKnown
                let facets = resolved(query.facets)
                if facets != query.facets {
                    var updated = query
                    updated.facets = facets
                    apply(updated, reset: false)
                }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func setIncludeAlternates(_ include: Bool) {
        var updated = query
        updated.includeAlternates = include
        apply(updated, reset: false)
    }

    /// Selects or deselects the family's eligible alternates without changing its disclosure or main row.
    func setAlternatesSelected(_ selected: Bool, family familyID: Int64) {
        guard let state = familyStates[familyID] else { return }
        selection.set(state.eligibleAlternates, selected: selected)
    }

    /// Selects or deselects the processable members of the family that the search or filters hide.
    func setHiddenMembersSelected(_ selected: Bool, family familyID: Int64) {
        guard let state = familyStates[familyID] else { return }
        selection.set(state.hiddenEligible, selected: selected)
    }

    func start() async {
        guard !active else { return }
        active = true
        session &+= 1
        await installObservation()
        guard active else { return }
        requestRefresh(reset: true)
        await refreshTask?.value
    }

    private func installObservation() async {
        let startedSession = session
        let database = database
        let observer = await Task.detached { [weak self] in
            LibraryBrowseObservation.start(in: database, onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.observedChange(session: startedSession) }
            }, onError: { [weak self] failure in
                Task { @MainActor [weak self] in self?.observedError(failure, session: startedSession) }
            })
        }.value
        guard active, session == startedSession else { observer.cancel(); return }
        observation = observer
    }

    private func observedChange(session: UInt64) {
        guard active, self.session == session else { return }
        refresh()
    }

    private func observedError(_ failure: Error, session: UInt64) {
        guard active, self.session == session else { return }
        error = failure.localizedDescription
    }

    func setQuery(_ query: LibraryBrowseQuery) {
        apply(query, reset: true)
    }

    private func apply(_ query: LibraryBrowseQuery, reset: Bool) {
        guard self.query != query else { return }
        if query.filter != self.query.filter || query.search != self.query.search || query.facets != self.query.facets {
            chipCounts = nil
        }
        self.query = query
        queryVersion &+= 1
        if reset {
            results.stop()
            focusedID = nil
            focusedIndex = 0
        }
        requestRefresh(reset: reset)
    }

    func focus(id: Int64?, index: Int) {
        focusedID = id
        focusedIndex = index
    }

    func refresh() {
        requestRefresh(reset: false)
    }

    func retry() {
        error = nil
        observation?.cancel()
        observation = nil
        Task { [weak self] in
            guard let self else { return }
            await installObservation()
            refresh()
        }
    }

    func stop() {
        active = false
        session &+= 1
        observation?.cancel()
        observation = nil
        refreshTask?.cancel()
        refreshTask = nil
        familyTask?.cancel()
        familyTask = nil
        chipCountTask?.cancel()
        chipCountTask = nil
        familyMembers = [:]
        loadedFamilies = nil
        dirty = false
        results.stop()
        selection.stop()
    }

    func resolveFile(id: Int64) async throws -> FileRecord {
        guard let file = try await database.writer.read({ connection in try FileRecord.fetchOne(connection, key: id) }) else {
            throw PagingError.missingFile
        }
        return file
    }

    private func requestRefresh(reset: Bool) {
        guard active else { return }
        dirty = true
        resetViewport = resetViewport || reset
        isRefreshing = true
        guard refreshTask == nil else { return }
        let requestedSession = session
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if session == requestedSession {
                    refreshTask = nil
                    isRefreshing = false
                }
            }
            while dirty, active, session == requestedSession, !Task.isCancelled {
                dirty = false
                let reset = resetViewport
                resetViewport = false
                let version = queryVersion
                let currentQuery = query
                let fallback = reset ? 0 : results.viewport.lowerBound
                let anchor = reset ? nil : results.row(at: fallback)?.id
                do {
                    let snapshot = try await LibraryPagedSnapshot.open(pool: pool, query: currentQuery)
                    guard active, session == requestedSession, version == queryVersion, !Task.isCancelled else {
                        resetViewport = resetViewport || reset
                        continue
                    }
                    await results.open(snapshot, anchorID: anchor, fallbackIndex: fallback, focusID: reset ? nil : focusedID, focusFallback: reset ? nil : focusedIndex)
                    guard active, session == requestedSession, version == queryVersion, !Task.isCancelled else { continue }
                    selection.updateScope(snapshot, visibleIdentities: trackedIdentities)
                    selection.reconcile(in: snapshot)
                    loadChipCounts(for: snapshot)
                    error = nil
                } catch {
                    guard active, session == requestedSession, version == queryVersion, !Task.isCancelled else { continue }
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
