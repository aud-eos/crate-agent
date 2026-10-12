import os

final class SyncRevisionAccounting: Sendable {
    @TaskLocal static var current: SyncRevisionAccounting?
    private struct State {
        var base: Int64?
        var changes: Int64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func begin(at revision: Int64?) {
        state.withLock { state in state.base = revision; state.changes = 0 }
    }

    func validate(_ revision: Int64) throws {
        try state.withLock { state in
            if let base = state.base, revision != base + state.changes {
                throw SyncCheckpointError.changed
            }
        }
    }

    func record(_ changes: Int64) {
        state.withLock { state in state.changes += changes }
    }

    var changes: Int64 {
        state.withLock { state in state.changes }
    }
}
