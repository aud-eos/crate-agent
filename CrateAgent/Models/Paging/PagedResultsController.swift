import Combine
import Foundation

@MainActor
final class PagedResultsController<Snapshot: PagedQuerySnapshot>: ObservableObject {
    let pageUpdates = PassthroughSubject<IndexSet, Never>()
    @Published private(set) var totalCount = 0
    @Published private(set) var generation: UInt64 = 0
    @Published private(set) var updateID: UInt64 = 0
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private(set) var snapshot: Snapshot?
    private(set) var effectivePageSize = 200
    private(set) var peakCachedRowCount = 0
    private(set) var decodedRowCount = 0
    private(set) var changedRows = IndexSet()
    private(set) var viewportAnchor: Int?
    private(set) var focusAnchor: Int?
    private(set) var viewport = 0 ..< 0
    var cacheLimit: Int {
        effectivePageSize * 5
    }

    var cachedRowCount: Int {
        pages.values.reduce(0) { count, rows in count + rows.count }
    }

    var cachedRows: [Snapshot.Row] {
        pages.values.flatMap { rows in rows }
    }

    private var pages: [Int: [Snapshot.Row]] = [:]
    /// The previous snapshot's pages, shown by a non-reset refresh until the new snapshot's viewport
    /// pages load, so a background refresh doesn't flash placeholders.
    private var retainedPages: [Int: [Snapshot.Row]] = [:]
    private var retainedPageSize = 0
    private var desiredPages: [Int] = []
    private var failures: [Int: String] = [:]
    private var countFailed = false
    private struct Request {
        let page: Int
        let generation: UInt64
        let size: Int
        let task: Task<Void, Never>
    }

    private var requests: [UUID: Request] = [:]

    func open(_ snapshot: Snapshot, anchorID: Snapshot.Row.ID? = nil, fallbackIndex: Int = 0, focusID: Snapshot.Row.ID? = nil, focusFallback: Int? = nil) async {
        invalidate(resetCount: false)
        self.snapshot = snapshot
        let requestedGeneration = generation
        isLoading = true
        error = nil
        countFailed = false
        do {
            let count = try await snapshot.count()
            guard count >= 0 else { throw PagingError.invalidRange }
            let anchor = try await anchorID.asyncFlatMap { identifier in try await snapshot.index(of: identifier) }
            let focused = try await focusID.asyncFlatMap { identifier in try await snapshot.index(of: identifier) }
            guard generation == requestedGeneration, !Task.isCancelled else { return }
            focusAnchor = min(max(0, focused ?? focusFallback ?? anchor ?? fallbackIndex), max(0, count - 1))
            totalCount = count
            if count == 0 {
                dropRetainedPages()
            }
            viewportAnchor = min(max(0, anchor ?? fallbackIndex), max(0, count - 1))
            isLoading = false
            updateID &+= 1
            if let viewportAnchor, count > 0 {
                setViewport(viewportAnchor ..< min(count, viewportAnchor + 1))
            }
        } catch {
            guard generation == requestedGeneration, !Task.isCancelled else { return }
            totalCount = 0
            countFailed = true
            dropRetainedPages()
            isLoading = false
            self.error = error.localizedDescription
        }
    }

    func setViewport(_ range: Range<Int>) {
        guard !isLoading, !countFailed, totalCount > 0 else { return }
        let lower = min(max(0, range.lowerBound), totalCount - 1)
        let upper = min(max(lower + 1, range.upperBound), totalCount)
        guard viewport != lower ..< upper || desiredPages.isEmpty else { return }
        viewport = lower ..< upper
        let size = max(200, (viewport.count + 3) / 4)
        if size != effectivePageSize {
            effectivePageSize = size
            pages.removeAll()
            failures.removeAll()
            for request in requests.values {
                request.task.cancel()
            }
        }
        let first = lower / size
        let last = (upper - 1) / size
        var desired = Array(first ... last)
        let lastPage = (totalCount - 1) / size
        var distance = 1
        while desired.count < 5, first - distance >= 0 || last + distance <= lastPage {
            if last + distance <= lastPage {
                desired.append(last + distance)
            }
            if desired.count < 5, first - distance >= 0 {
                desired.append(first - distance)
            }
            distance += 1
        }
        desiredPages = desired
        pages = pages.filter { entry in desired.contains(entry.key) }
        failures = failures.filter { entry in desired.contains(entry.key) }
        error = failures.values.first
        for request in requests.values where !desired.contains(request.page) || request.size != size {
            request.task.cancel()
        }
        pump()
    }

    func row(at index: Int) -> Snapshot.Row? {
        guard index >= 0, index < totalCount else { return nil }
        if let page = pages[index / effectivePageSize] {
            return Self.row(at: index, in: page, pageSize: effectivePageSize)
        }
        guard retainedPageSize > 0, let page = retainedPages[index / retainedPageSize] else { return nil }
        return Self.row(at: index, in: page, pageSize: retainedPageSize)
    }

    private static func row(at index: Int, in page: [Snapshot.Row], pageSize: Int) -> Snapshot.Row? {
        let offset = index % pageSize
        return offset < page.count ? page[offset] : nil
    }

    /// Whether every page the viewport covers has loaded from the current snapshot.
    var isViewportLoaded: Bool {
        guard snapshot != nil, !isLoading, !countFailed else { return false }
        guard totalCount > 0, !viewport.isEmpty else { return totalCount == 0 }
        return (viewport.lowerBound / effectivePageSize ... (viewport.upperBound - 1) / effectivePageSize).allSatisfy { page in pages[page] != nil }
    }

    func retry() {
        guard let snapshot else { return }
        if countFailed {
            Task { await open(snapshot) }
        } else {
            failures.removeAll()
            error = nil
            pump()
        }
    }

    func stop() {
        invalidate()
        snapshot = nil
        isLoading = false
        error = nil
        updateID &+= 1
    }

    private func invalidate(resetCount: Bool = true) {
        generation &+= 1
        if resetCount {
            dropRetainedPages()
        } else if !pages.isEmpty {
            retainedPages = pages
            retainedPageSize = effectivePageSize
        }
        for request in requests.values {
            request.task.cancel()
        }
        snapshot = nil
        pages.removeAll()
        failures.removeAll()
        desiredPages.removeAll()
        changedRows.removeAll()
        if resetCount {
            totalCount = 0
        }
        viewportAnchor = nil
        focusAnchor = nil
        viewport = 0 ..< 0
    }

    private func dropRetainedPages() {
        retainedPages.removeAll()
        retainedPageSize = 0
    }

    private func pump() {
        guard let snapshot, !isLoading, !countFailed else { return }
        while requests.count < 2 {
            guard let page = desiredPages.first(where: { page in
                pages[page] == nil && failures[page] == nil && !requests.values.contains { request in
                    request.page == page && request.generation == generation && request.size == effectivePageSize
                }
            }) else { return }
            let token = UUID()
            let requestedGeneration = generation
            let size = effectivePageSize
            let range = page * size ..< min(totalCount, (page + 1) * size)
            let task = Task { [weak self] in
                let result: Result<[Snapshot.Row], Error>
                do {
                    let rows = try await snapshot.rows(in: range)
                    guard rows.count == range.count else { throw PagingError.incompletePage }
                    result = .success(rows)
                } catch { result = .failure(error) }
                self?.finish(token: token, result: result, range: range)
            }
            requests[token] = Request(page: page, generation: requestedGeneration, size: size, task: task)
        }
    }

    private func finish(token: UUID, result: Result<[Snapshot.Row], Error>, range: Range<Int>) {
        guard let request = requests.removeValue(forKey: token) else { return }
        defer { pump() }
        if case let .success(rows) = result {
            decodedRowCount += rows.count
        }
        guard request.generation == generation, request.size == effectivePageSize,
              !request.task.isCancelled, desiredPages.contains(request.page) else { return }
        switch result {
        case let .success(rows):
            pages[request.page] = rows
            failures[request.page] = nil
            peakCachedRowCount = max(peakCachedRowCount, cachedRowCount)
            if isViewportLoaded {
                dropRetainedPages()
            }
        case let .failure(failure):
            failures[request.page] = failure.localizedDescription
            dropRetainedPages()
        }
        error = failures.values.first
        changedRows = IndexSet(integersIn: range)
        pageUpdates.send(changedRows)
        updateID &+= 1
    }
}

private extension Optional {
    func asyncFlatMap<Value>(_ transform: (Wrapped) async throws -> Value?) async rethrows -> Value? {
        switch self {
        case let .some(value): try await transform(value)
        case .none: nil
        }
    }
}
