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

        func check(target: SeratoConflictTarget) throws {
            try gate.check(epoch: epoch, target: target)
        }
    }

    @TaskLocal static var drainAuthorization: Authorization?
    struct ScopeAuthorization: Sendable {
        let gate: LibrarySyncReadiness
        let revision: UInt64
        func check() throws {
            try gate.state.withLock { state in
                guard state.scopeRevision == revision else { throw LibrarySyncReadinessError.synchronizationRequired }
            }
        }
    }

    private struct State {
        var epoch: UInt64 = 0
        var ready = false
        var scopeRevision: UInt64 = 0
        var scope = SeratoConflictScope()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func invalidate() {
        state.withLock { state in state.epoch += 1; state.scopeRevision += 1; state.ready = false }
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

    private func check(epoch: UInt64, target: SeratoConflictTarget? = nil) throws {
        try state.withLock { state in
            guard state.ready, state.epoch == epoch else { throw LibrarySyncReadinessError.synchronizationRequired }
            if let target, let path = state.scope.conflictingPath(for: target) {
                throw SeratoPathConflictError(path: path)
            }
        }
    }

    func install(_ scope: SeratoConflictScope, for authorization: Authorization) throws {
        try state.withLock { state in
            guard authorization.gate === self, authorization.epoch == state.epoch, !state.ready else {
                throw LibrarySyncReadinessError.synchronizationRequired
            }
            state.scope = scope
            state.scopeRevision += 1
        }
    }

    func captureScope() -> ScopeAuthorization {
        state.withLock { state in ScopeAuthorization(gate: self, revision: state.scopeRevision) }
    }

    var scopeRevision: UInt64 {
        state.withLock { state in state.scopeRevision }
    }

    var hasConflicts: Bool {
        state.withLock { state in !state.scope.isEmpty }
    }

    func installDirectObservation(_ scope: SeratoConflictScope, authorization: ScopeAuthorization) throws {
        try state.withLock { state in
            guard authorization.gate === self, authorization.revision == state.scopeRevision else {
                throw LibrarySyncReadinessError.synchronizationRequired
            }
            guard !scope.isEmpty || !state.scope.isEmpty else { return }
            state.epoch += 1
            state.scopeRevision += 1
            state.ready = false
            state.scope = scope
        }
    }

    func conflictPath(for target: SeratoConflictTarget) -> String? {
        state.withLock { state in state.scope.conflictingPath(for: target) }
    }

    func requireUnconflicted(_ target: SeratoConflictTarget) throws {
        if let path = conflictPath(for: target) {
            throw SeratoPathConflictError(path: path)
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
