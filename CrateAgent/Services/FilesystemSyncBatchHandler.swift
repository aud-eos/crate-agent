import Foundation

actor FilesystemSyncBatchHandler {
    private let coordinator: FilesystemSyncCoordinator
    private let session: SeratoLibrarySyncSession

    init(coordinator: FilesystemSyncCoordinator, session: SeratoLibrarySyncSession) {
        self.coordinator = coordinator
        self.session = session
    }

    func handle(_ batch: FilesystemEventBatch) async throws {
        var retainedConflict: FilesystemConflictDeferral?
        do { try await coordinator.handleBatch(batch) }
        catch let deferred as FilesystemConflictDeferral { retainedConflict = deferred }
        if await coordinator.takeReconciliationRequest() {
            do { try await session.synchronize() }
            catch {
                await coordinator.restoreReconciliationRequest()
                throw error
            }
        }
        if let retainedConflict {
            throw retainedConflict
        }
    }
}
