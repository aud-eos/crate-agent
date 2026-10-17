import Foundation
import GRDB

/// Library coverage and fingerprint retry for the Workers section. Owned by `AppServices`,
/// so a selection or loaded drill-down survives navigation; the jobs themselves belong to
/// `FingerprintWorker` and `SeratoLibrarySyncSession`.
@MainActor
final class WorkersModel: ObservableObject {
    /// Coverage is an aggregate over every file, so it refreshes on a bounded cadence while
    /// Workers is visible instead of after each of a scan's per-file commits.
    static let refreshInterval: Duration = .seconds(2)

    @Published private(set) var coverage: WorkerCoverage?
    @Published private(set) var category: WorkerFileCategory = .failed
    @Published private(set) var rows: [WorkerFileRow] = []
    @Published var selectedFileIDs: Set<Int64> = []
    @Published private(set) var error: String?
    @Published private(set) var lastRetryResult: String?

    private let database: LibraryDatabase
    private let restartFingerprinting: @MainActor () -> Void

    init(database: LibraryDatabase, restartFingerprinting: @escaping @MainActor () -> Void) {
        self.database = database
        self.restartFingerprinting = restartFingerprinting
    }

    func monitor() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
        }
    }

    func refresh() async {
        let category = category
        do {
            let (coverage, rows) = try await database.writer.read { database in
                try (WorkerCoverageQuery.fetch(in: database), WorkerCoverageQuery.files(in: category, database: database))
            }
            self.coverage = coverage
            guard category == self.category else { return }
            self.rows = rows
            selectedFileIDs.formIntersection(rows.map(\.id))
            error = nil
        } catch {
            self.error = "Could not read worker status: \(error.localizedDescription)"
        }
    }

    func show(_ category: WorkerFileCategory) async {
        guard category != self.category else { return }
        self.category = category
        rows = []
        selectedFileIDs = []
        await refresh()
    }

    func retryAllFailed() async {
        await requeue(fileIDs: nil)
    }

    func retrySelected() async {
        await requeue(fileIDs: Array(selectedFileIDs))
    }

    private func requeue(fileIDs: [Int64]?) async {
        do {
            let requeued = try await database.writer.write { database in
                try FingerprintPersistence.requeueForRetry(fileIDs: fileIDs, in: database)
            }
            lastRetryResult = requeued == 0 ? "No failed or invalid files are eligible to retry." : "Queued \(requeued) file(s) for fingerprinting."
            selectedFileIDs = []
            if requeued > 0 {
                restartFingerprinting()
            }
            await refresh()
        } catch {
            self.error = "Could not queue files for fingerprinting: \(error.localizedDescription)"
        }
    }
}
