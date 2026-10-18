import Combine
import Foundation

@MainActor
final class PagedSelectionController<Provider: PagedSelectionProvider>: ObservableObject {
    typealias Snapshot = Provider.Snapshot
    typealias Identity = PagedIdentity<Snapshot.Row.ID>
    @Published private(set) var summary: PagedSelectionSummary?
    @Published private(set) var visibleSelectedIDs: Set<Snapshot.Row.ID> = []
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var interactionVersion: UInt64 = 0
    private let provider: Provider
    private var snapshot: Snapshot?
    private var visibleIdentities: [Identity] = []
    private var operation: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var membershipTask: Task<Void, Never>?
    private var membershipVersion: UInt64 = 0
    private var intent: UInt64 = 0
    private var readVersion: UInt64 = 0
    private var pendingOperations = 0
    private var removed = 0
    private var failedCommand: (() async throws -> Void)?

    init(provider: Provider) {
        self.provider = provider
    }

    func set(_ identities: [Identity], selected: Bool) {
        interactionVersion &+= 1
        enqueue { [provider] in try await provider.set(identities, selected: selected) }
    }

    func setScope(_ snapshot: Snapshot, selected: Bool) {
        interactionVersion &+= 1
        enqueue { [provider] in try await provider.setScope(snapshot, selected: selected) }
    }

    func setRange(_ range: Range<Int>, in snapshot: Snapshot, selected: Bool) {
        interactionVersion &+= 1
        enqueue { [provider] in try await provider.setRange(range, in: snapshot, selected: selected) }
    }

    func updateScope(_ snapshot: Snapshot, visibleIdentities: [Identity]) {
        self.snapshot = snapshot
        self.visibleIdentities = visibleIdentities
        refresh()
    }

    func updateVisibleIdentities(_ identities: [Identity]) {
        guard Set(identities) != Set(visibleIdentities) else { return }
        visibleIdentities = identities
        refreshVisible()
    }

    private func refreshVisible() {
        membershipVersion &+= 1
        let version = membershipVersion
        let identities = visibleIdentities
        membershipTask?.cancel()
        membershipTask = Task { [weak self, provider] in
            do {
                let selected = try await provider.selectedIDs(in: identities)
                guard let self, version == membershipVersion, !Task.isCancelled else { return }
                visibleSelectedIDs = selected
            } catch {
                guard let self, version == membershipVersion, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func reconcile(in snapshot: Snapshot) {
        self.snapshot = snapshot
        enqueue { [weak self, provider] in
            let count = try await provider.reconcile()
            self?.removed = count
        }
    }

    func clear() {
        interactionVersion &+= 1
        membershipVersion &+= 1
        membershipTask?.cancel()
        visibleSelectedIDs.removeAll()
        intent &+= 1
        operation?.cancel()
        failedCommand = nil
        removed = 0
        enqueue { [provider] in try await provider.clear() }
    }

    func retry() {
        if let failedCommand {
            interactionVersion &+= 1
            enqueue(failedCommand)
        } else {
            refresh()
        }
    }

    func stop() {
        interactionVersion &+= 1
        intent &+= 1
        readVersion &+= 1
        membershipVersion &+= 1
        membershipTask?.cancel()
        readTask?.cancel()
        operation?.cancel()
        let previous = operation
        let provider = provider
        operation = Task {
            await previous?.value
            await provider.close()
        }
        snapshot = nil
        failedCommand = nil
        visibleIdentities.removeAll()
        visibleSelectedIDs.removeAll()
        summary = nil
        isBusy = false
    }

    private func enqueue(_ command: @escaping () async throws -> Void) {
        let previous = operation
        let commandIntent = intent
        pendingOperations += 1
        readTask?.cancel()
        readVersion &+= 1
        isBusy = true
        error = nil
        operation = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                pendingOperations -= 1
                if pendingOperations == 0, commandIntent == intent {
                    refresh()
                }
            }
            guard commandIntent == intent, !Task.isCancelled else { return }
            do {
                try await command()
                guard commandIntent == intent, !Task.isCancelled else { return }
                failedCommand = nil
            } catch {
                guard commandIntent == intent, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                failedCommand = command
            }
        }
    }

    private func refresh() {
        guard let snapshot, pendingOperations == 0 else { return }
        readVersion &+= 1
        let version = readVersion
        readTask?.cancel()
        isBusy = true
        readTask = Task { [weak self, provider] in
            do {
                let counts = try await provider.summary(in: snapshot)
                guard let self, version == readVersion, !Task.isCancelled else { return }
                summary = .init(total: counts.total, inScope: counts.inScope, scopeCount: counts.scopeCount, removed: removed, scopeSelected: counts.scopeSelected)
                refreshVisible()
                isBusy = false
                if failedCommand == nil {
                    error = nil
                }
            } catch {
                guard let self, version == readVersion, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                isBusy = false
            }
        }
    }
}
