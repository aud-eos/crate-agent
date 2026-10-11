import Foundation

/// Indexes belong to one immutable result snapshot, never to viewport positions.
struct BatchSelection: Sendable, Equatable {
    enum Coverage { case none, partial, all }

    private(set) var indexes = IndexSet()

    var count: Int {
        indexes.count
    }

    func count(in scope: IndexSet) -> Int {
        indexes.intersection(scope).count
    }

    func coverage(in scope: IndexSet) -> Coverage {
        let selectedCount = count(in: scope)
        if selectedCount == 0 {
            return .none
        }
        return selectedCount == scope.count ? .all : .partial
    }

    mutating func set(_ selected: Bool, at index: Int) {
        if selected {
            indexes.insert(index)
        } else {
            indexes.remove(index)
        }
    }

    mutating func set(_ selected: Bool, in scope: IndexSet) {
        if selected {
            indexes.formUnion(scope)
        } else {
            indexes.subtract(scope)
        }
    }

    mutating func clear() {
        indexes = IndexSet()
    }
}
