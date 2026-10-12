import Foundation

struct PagedIdentity<Identifier: Hashable & Sendable>: Hashable, Sendable {
    let id: Identifier
    let revision: Int64
}

protocol PagedQuerySnapshot: Sendable {
    associatedtype Row: Identifiable & Sendable where Row.ID: Sendable
    associatedtype Signature: Hashable & Sendable
    var signature: Signature { get }
    func count() async throws -> Int
    func rows(in range: Range<Int>) async throws -> [Row]
    func index(of id: Row.ID) async throws -> Int?
    func identities(after id: Row.ID?, limit: Int) async throws -> [PagedIdentity<Row.ID>]
    func identity(for row: Row) -> PagedIdentity<Row.ID>
}

struct PagedSelectionSummary: Equatable, Sendable {
    let total: Int
    let inScope: Int
    let scopeCount: Int
    let removed: Int
    var hidden: Int {
        total - inScope
    }
}

protocol PagedSelectionProvider: Sendable {
    associatedtype Snapshot: PagedQuerySnapshot
    func set(_ identities: [PagedIdentity<Snapshot.Row.ID>], selected: Bool) async throws
    func setScope(_ snapshot: Snapshot, selected: Bool) async throws
    func setRange(_ range: Range<Int>, in snapshot: Snapshot, selected: Bool) async throws
    func selectedIDs(in identities: [PagedIdentity<Snapshot.Row.ID>]) async throws -> Set<Snapshot.Row.ID>
    func summary(in snapshot: Snapshot) async throws -> PagedSelectionSummary
    func reconcile() async throws -> Int
    func clear() async throws
    func close() async
}

enum PagingError: LocalizedError {
    case invalidRange, incompletePage, unavailableDatabase, missingFile
    var errorDescription: String? {
        switch self {
        case .invalidRange: "The requested library range is invalid."
        case .incompletePage: "The library returned an incomplete page. Retry to reload it."
        case .unavailableDatabase: "Library paging requires a WAL database pool."
        case .missingFile: "This file is no longer in the library."
        }
    }
}

enum PagingLabels {
    static let loading = "Loading…"
    static let retry = "Retry"
    static let selectionBusy = "Updating selection…"
}
