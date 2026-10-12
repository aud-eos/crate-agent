@testable import CrateAgent
import Foundation

struct FixtureRow: Identifiable, Sendable {
    let id: Int
    let name: String
}

enum PagingFixtureError: Error { case unavailable }

actor PagedQueryFixture: PagedQuerySnapshot {
    nonisolated let signature: String
    let rowCount: Int
    var held = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    var ranges: [Range<Int>] = []
    var failPage = false
    var failCount = false

    init(rowCount: Int, signature: String) {
        self.rowCount = rowCount
        self.signature = signature
    }

    func count() throws -> Int {
        if failCount {
            throw PagingFixtureError.unavailable
        }
        return rowCount
    }

    func holdPages() {
        held = true
    }

    func setCountFailure(_ fails: Bool) {
        failCount = fails
    }

    func failNextPage() {
        failPage = true
    }

    func requestedRanges() -> [Range<Int>] {
        ranges
    }

    func releaseAll() {
        held = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func rows(in range: Range<Int>) async throws -> [FixtureRow] {
        ranges.append(range)
        if held {
            await withCheckedContinuation { waiters.append($0) }
        }
        if failPage {
            failPage = false
            throw PagingFixtureError.unavailable
        }
        return range.map { index in FixtureRow(id: index + 1, name: "\(signature)-\(index)") }
    }

    func index(of id: Int) -> Int? {
        (1 ... rowCount).contains(id) ? id - 1 : nil
    }

    func identities(after id: Int?, limit: Int) -> [PagedIdentity<Int>] {
        let lower = id ?? 0
        guard lower < rowCount else { return [] }
        return (lower ..< min(rowCount, lower + limit)).map { index in .init(id: index + 1, revision: 0) }
    }

    nonisolated func identity(for row: FixtureRow) -> PagedIdentity<Int> {
        .init(id: row.id, revision: 0)
    }
}

actor FixtureSelectionProvider: PagedSelectionProvider {
    typealias Snapshot = PagedQueryFixture
    var selected: Set<PagedIdentity<Int>> = []
    var failure = false
    var gate: CheckedContinuation<Void, Never>?
    var held = false
    var capturing = false
    func holdCapture() {
        held = true
    }

    func isCapturing() -> Bool {
        capturing
    }

    func failCapture(_ fails: Bool) {
        failure = fails
    }

    func releaseCapture() {
        held = false; gate?.resume(); gate = nil
    }

    func set(_ identities: [PagedIdentity<Int>], selected shouldSelect: Bool) {
        if shouldSelect {
            selected.formUnion(identities)
        } else {
            selected.subtract(identities)
        }
    }

    func setScope(_ snapshot: PagedQueryFixture, selected: Bool) async throws {
        try await setRange(0 ..< snapshot.rowCount, in: snapshot, selected: selected)
    }

    func setRange(_ range: Range<Int>, in _: PagedQueryFixture, selected: Bool) async throws {
        capturing = true
        defer { capturing = false }
        if held {
            await withCheckedContinuation { gate = $0 }
        }
        if failure {
            throw PagingFixtureError.unavailable
        }
        try Task.checkCancellation()
        set(range.map { index in .init(id: index + 1, revision: 0) }, selected: selected)
    }

    func selectedIDs(in identities: [PagedIdentity<Int>]) -> Set<Int> {
        Set(identities.filter { selected.contains($0) }.map(\.id))
    }

    func summary(in snapshot: PagedQueryFixture) -> PagedSelectionSummary {
        let inScope = selected.filter { $0.id <= snapshot.rowCount }.count
        return .init(total: selected.count, inScope: inScope, scopeCount: snapshot.rowCount, removed: 0)
    }

    func reconcile() -> Int {
        0
    }

    func clear() {
        selected.removeAll()
    }

    func close() {
        selected.removeAll()
    }
}
