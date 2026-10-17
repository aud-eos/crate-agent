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
    /// Selection and eligibility of each visible family's members, including collapsed alternates.
    @Published private(set) var familyStates: [Int64: LibraryFamilyState] = [:]
    /// Changes whenever a family row's selection or disclosure display changes.
    @Published private(set) var familyRevision: UInt64 = 0
    private let selectionStore: LibrarySelectionStore
    private var familyMembers: [Int64: [LibraryFamilyPlacement]] = [:]
    private var familyTask: Task<Void, Never>?
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
                self.error = error.localizedDescription
            }
        }
    }

    private func updateFamilyStates(selected: Set<Int64>) {
        var states: [Int64: LibraryFamilyState] = [:]
        for (familyID, members) in familyMembers {
            states[familyID] = LibraryFamilyState(members: members, selected: selected, isExpanded: query.expandedFamilies.contains(familyID))
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

    /// The explicit selection, for batch actions. Throws when it exceeds `limit`.
    func selectedFileIDs(limit: Int) async throws -> [Int64] {
        try await selectionStore.selectedIDs(limit: limit)
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
        familyMembers = [:]
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
                    error = nil
                } catch {
                    guard active, session == requestedSession, version == queryVersion, !Task.isCancelled else { continue }
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
