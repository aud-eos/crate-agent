import Foundation

/// Keeps `serato_play_counts` in step with Serato History. History is read
/// only while Serato is closed, since Serato appends to it while running,
/// and only when its session files or the library's paths changed since the
/// last read; a skipped or failed refresh keeps the previous table.
@MainActor
final class SeratoPlayCountService: ObservableObject {
    enum Status: Equatable {
        case notRefreshed
        case refreshing
        case refreshed(SeratoPlayCountSummary)
        case skippedWhileSeratoRunning
        /// The reason the last read failed; the counts shown are older.
        case failed(String)
    }

    /// What a refresh read: every session file's name, size and modification
    /// time, and the library's path history.
    private struct Inputs: Codable, Equatable {
        let sessions: [SeratoDirectoryStamp]
        let library: SeratoLibraryPathSignature
    }

    typealias HistoryReader = @Sendable (_ historyDirectory: String) async throws -> SeratoHistoryScan

    @Published private(set) var status: Status = .notRefreshed

    private let database: LibraryDatabase
    private let seratoLocator: SeratoLibraryLocator
    private let watchdog: SeratoWatchdog
    private let readHistory: HistoryReader
    private var isRefreshing = false
    private var refreshRequested = false
    /// The inputs of the last completed read and its outcome, restored when
    /// nothing changed since.
    private var lastRead: (inputs: Inputs, outcome: Status)?

    init(database: LibraryDatabase, seratoLocator: SeratoLibraryLocator, watchdog: SeratoWatchdog,
         readHistory: @escaping HistoryReader = { historyDirectory in try readSeratoHistory(historyDirectory: historyDirectory) })
    {
        self.database = database
        self.seratoLocator = seratoLocator
        self.watchdog = watchdog
        self.readHistory = readHistory
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
        let historyDirectory = seratoLocator.historyDirectoryUrl
        let sessionsDirectory = historyDirectory.appendingPathComponent("Sessions", isDirectory: true)
        var inputs: Inputs?
        do {
            let sessions = try await Task.detached { try SeratoDirectoryStamp.all(in: sessionsDirectory, pathExtension: "session") }.value
            let library = try await database.writer.read { connection in try SeratoPlayCounts.librarySignature(in: connection) }
            let current = Inputs(sessions: sessions, library: library)
            inputs = current
            if let lastRead, lastRead.inputs == current {
                status = lastRead.outcome
                return
            }
            status = .refreshing
            let scan = try await readHistory(historyDirectory.path)
            guard watchdog.isClosed(atRevision: revision) else {
                status = .skippedWhileSeratoRunning
                return
            }
            let plan = try await database.writer.read { connection in try SeratoPlayCounts.plan(from: scan, in: connection) }
            let readInputs = Inputs(sessions: sessions, library: plan.library)
            let historyStamp = try String(decoding: JSONEncoder().encode(readInputs), as: UTF8.self)
            guard try await database.writer.write({ connection in
                try SeratoPlayCounts.apply(plan, historyStamp: historyStamp, in: connection)
            }) else {
                refreshRequested = true
                return
            }
            finish(readInputs, outcome: .refreshed(plan.summary))
        } catch {
            let reason = (error as? CoreError)?.message ?? error.localizedDescription
            if let inputs {
                finish(inputs, outcome: .failed(reason))
            } else {
                status = .failed(reason)
            }
        }
    }

    private func finish(_ inputs: Inputs, outcome: Status) {
        lastRead = (inputs, outcome)
        status = outcome
    }
}

/// One file of a Serato directory as it lists it; a changed name, size or
/// modification time means Serato wrote the file since the last read.
struct SeratoDirectoryStamp: Codable, Equatable, Sendable {
    let name: String
    let size: Int
    let modified: Date

    private static let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]

    /// Every file in `directory` with `pathExtension`, by name; a missing directory has none.
    static func all(in directory: URL, pathExtension: String) throws -> [SeratoDirectoryStamp] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        return try entries.filter { entry in entry.pathExtension == pathExtension }.map { entry in
            let values = try entry.resourceValues(forKeys: Set(keys))
            guard let size = values.fileSize, let modified = values.contentModificationDate else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: entry.path])
            }
            return SeratoDirectoryStamp(name: entry.lastPathComponent, size: size, modified: modified)
        }.sorted { first, second in first.name < second.name }
    }
}
