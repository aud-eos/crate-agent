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
        selection = try PagedSelectionController(provider: LibrarySelectionStore(database: database))
        results.objectWillChange.merge(with: selection.objectWillChange).sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        results.$updateID.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, let snapshot = results.snapshot else { return }
            self.selection.updateVisibleIdentities(self.results.cachedRows.map { row in snapshot.identity(for: row) })
        }.store(in: &subscriptions)
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
        guard self.query != query else { return }
        self.query = query
        queryVersion &+= 1
        results.stop()
        focusedID = nil
        focusedIndex = 0
        requestRefresh(reset: true)
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
            while self.dirty, self.active, self.session == requestedSession, !Task.isCancelled {
                self.dirty = false
                let reset = self.resetViewport
                self.resetViewport = false
                let version = self.queryVersion
                let currentQuery = self.query
                let fallback = reset ? 0 : self.results.viewport.lowerBound
                let anchor = reset ? nil : self.results.row(at: fallback)?.id
                do {
                    let snapshot = try await LibraryPagedSnapshot.open(pool: self.pool, query: currentQuery)
                    guard self.active, self.session == requestedSession, version == self.queryVersion, !Task.isCancelled else {
                        self.resetViewport = self.resetViewport || reset
                        continue
                    }
                    await self.results.open(snapshot, anchorID: anchor, fallbackIndex: fallback, focusID: reset ? nil : self.focusedID, focusFallback: reset ? nil : self.focusedIndex)
                    guard self.active, self.session == requestedSession, version == self.queryVersion, !Task.isCancelled else { continue }
                    self.selection.updateScope(snapshot, visibleIdentities: self.results.cachedRows.map { row in snapshot.identity(for: row) })
                    self.selection.reconcile(in: snapshot)
                    self.error = nil
                } catch {
                    guard self.active, self.session == requestedSession, version == self.queryVersion, !Task.isCancelled else { continue }
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
