import Foundation

/// Keeps `serato_play_counts` in step with Serato History. History is read
/// only while Serato is closed, since Serato appends to it while running;
/// a skipped or failed refresh keeps the previous table.
@MainActor
final class SeratoPlayCountService: ObservableObject {
    enum Status: Equatable {
        case notRefreshed
        case refreshing
        case refreshed(SeratoPlayCountSummary)
        case skippedWhileSeratoRunning
        case failed(String)
    }

    @Published private(set) var status: Status = .notRefreshed

    private let database: LibraryDatabase
    private let seratoLocator: SeratoLibraryLocator
    private let watchdog: SeratoWatchdog
    private var isRefreshing = false
    private var refreshRequested = false

    init(database: LibraryDatabase, seratoLocator: SeratoLibraryLocator, watchdog: SeratoWatchdog) {
        self.database = database
        self.seratoLocator = seratoLocator
        self.watchdog = watchdog
    }

    /// A request made while a refresh runs is coalesced into one more pass.
    func refresh() async {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequested = false
            await refreshOnce()
        } while refreshRequested
    }

    private func refreshOnce() async {
        guard !watchdog.isSeratoRunning else {
            status = .skippedWhileSeratoRunning
            return
        }
        let revision = watchdog.stateRevision
        let historyDirectory = seratoLocator.historyDirectoryUrl.path
        status = .refreshing
        do {
            let scan = try await Task.detached { try readSeratoHistory(historyDirectory: historyDirectory) }.value
            guard watchdog.isClosed(atRevision: revision) else {
                status = .skippedWhileSeratoRunning
                return
            }
            let summary = try await database.writer.write { connection in try SeratoPlayCounts.rebuild(from: scan, in: connection) }
            status = .refreshed(summary)
        } catch {
            status = .failed(SeratoPlayCountMessages.failed((error as? CoreError)?.message ?? error.localizedDescription))
        }
    }
}
