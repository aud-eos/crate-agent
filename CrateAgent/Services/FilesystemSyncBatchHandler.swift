import Foundation

actor FilesystemSyncBatchHandler {
    private let coordinator: FilesystemSyncCoordinator
    private let session: SeratoLibrarySyncSession

    init(coordinator: FilesystemSyncCoordinator, session: SeratoLibrarySyncSession) {
        self.coordinator = coordinator
        self.session = session
    }

    func handle(_ batch: FilesystemEventBatch) async throws {
        try await coordinator.handleBatch(batch)
        guard await coordinator.takeReconciliationRequest() else { return }
        do { try await session.synchronize() }
        catch {
            await coordinator.restoreReconciliationRequest()
            throw error
        }
    }
}
