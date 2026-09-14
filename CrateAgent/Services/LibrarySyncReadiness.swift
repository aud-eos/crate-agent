import Foundation
import os

public enum LibrarySyncReadinessError: LocalizedError {
    case synchronizationRequired
    public var errorDescription: String? {
        "Library synchronization must finish before processing. Close Serato and retry sync."
    }
}

public final class LibrarySyncReadiness: Sendable {
    struct Authorization: Sendable {
        let gate: LibrarySyncReadiness
        let epoch: UInt64
        func check() throws {
            try gate.check(epoch: epoch)
        }
    }

    @TaskLocal static var drainAuthorization: Authorization?
    private struct State { var epoch: UInt64 = 0; var ready = false }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func invalidate() {
        state.withLock { state in state.epoch += 1; state.ready = false }
    }

    func capture() throws -> Authorization {
        try state.withLock { state in
            guard state.ready else { throw LibrarySyncReadinessError.synchronizationRequired }
            return Authorization(gate: self, epoch: state.epoch)
        }
    }

    func prepareDrain() -> Authorization {
        state.withLock { Authorization(gate: self, epoch: $0.epoch) }
    }

    func markReady(_ authorization: Authorization) throws {
        try state.withLock { state in
            guard authorization.gate === self, authorization.epoch == state.epoch else {
                throw LibrarySyncReadinessError.synchronizationRequired
            }
            state.ready = true
        }
    }

    private func check(epoch: UInt64) throws {
        try state.withLock { state in
            guard state.ready, state.epoch == epoch else { throw LibrarySyncReadinessError.synchronizationRequired }
        }
    }

    var permitsExternalWrites: Bool {
        permitsExternalWrites(drain: Self.drainAuthorization)
    }

    func permitsExternalWrites(drain: Authorization?) -> Bool {
        state.withLock { state in
            state.ready || (drain?.gate === self && drain?.epoch == state.epoch)
        }
    }
}
