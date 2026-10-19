import Foundation
import GRDB
import os.log

/// Which files the checklist counts as duplicates: members of a group whose
/// copies are proven identical, in either mode, unless the owner kept every
/// copy because their labels disagree. A group that needs listening proves
/// nothing, so it never marks a file.
enum ChecklistDuplicates {
    static let table = "checklist_duplicate_members"
    static let maximumOperationsPerTransaction = 1000

    /// File id → the id of the confirmed group it belongs to; a file in a
    /// confirmed group in both modes keeps its byte-level group.
    static func confirmedMembers(in database: GRDB.Database) throws -> [Int64: String] {
        var members: [Int64: String] = [:]
        for mode in [DuplicateFinder.Mode.byteLevel, .perceptual] {
            for group in try DuplicateFinder.findDuplicates(in: database, mode: mode)
                where group.check == .confirmed && group.labelReview?.keptBoth != true
            {
                for fileID in group.files.compactMap(\.id) where members[fileID] == nil {
                    members[fileID] = group.id
                }
            }
        }
        return members
    }

    static func stored(in database: GRDB.Database) throws -> [Int64: String] {
        var members: [Int64: String] = [:]
        let rows = try Row.fetchCursor(database, sql: "SELECT file_id, group_key FROM \(table)")
        while let row = try rows.next() {
            members[row["file_id"]] = row["group_key"]
        }
        return members
    }

    /// Writes only the rows that differ, at most
    /// `maximumOperationsPerTransaction` per transaction. A member whose file
    /// was deleted meanwhile is skipped.
    static func replace(with members: [Int64: String], in writer: any DatabaseWriter) async throws {
        let current = try await writer.read { connection in try stored(in: connection) }
        let deletions = current.keys.filter { fileID in members[fileID] == nil }.map { fileID in Operation.delete(fileID) }
        let upserts = members.filter { fileID, groupKey in current[fileID] != groupKey }
            .map { fileID, groupKey in Operation.upsert(fileID, groupKey) }
        let operations = deletions + upserts
        for start in stride(from: 0, to: operations.count, by: maximumOperationsPerTransaction) {
            let chunk = operations[start ..< min(start + maximumOperationsPerTransaction, operations.count)]
            try await writer.write { connection in
                for operation in chunk {
                    switch operation {
                    case let .delete(fileID):
                        try connection.execute(sql: "DELETE FROM \(table) WHERE file_id = ?", arguments: [fileID])
                    case let .upsert(fileID, groupKey):
                        try connection.execute(sql: "INSERT OR REPLACE INTO \(table) (file_id, group_key) SELECT id, ? FROM files WHERE id = ?",
                                               arguments: [groupKey, fileID])
                    }
                }
            }
        }
    }

    private enum Operation: Sendable {
        case delete(Int64)
        case upsert(Int64, String)
    }
}

/// Keeps `checklist_duplicate_members` in step with the duplicate groups. A
/// scan of a fully fingerprinted 30,000-file library costs up to a second,
/// so refreshes start at least `minimumRefreshInterval` apart: one at start,
/// then one for the changes since, so the final state is always written.
@MainActor
final class ChecklistDuplicateRefresher: ObservableObject {
    enum Status: Equatable {
        case notRefreshed
        case refreshing
        case refreshed(memberCount: Int)
        /// The reason the last refresh failed; the members shown are older.
        case failed(String)
    }

    static let minimumRefreshInterval: Duration = .seconds(30)
    private static let logger = Logger(subsystem: "com.crateagent.app", category: "ChecklistDuplicateRefresher")

    @Published private(set) var status: Status = .notRefreshed

    private let database: LibraryDatabase
    private let clock = ContinuousClock()
    private var observation: AnyDatabaseCancellable?
    private var scheduled: Task<Void, Never>?
    private var lastRefreshStart: ContinuousClock.Instant?
    private var isRefreshing = false
    private var changedDuringRefresh = false

    init(database: LibraryDatabase) {
        self.database = database
    }

    func start() {
        guard observation == nil else { return }
        observation = DuplicateScanObservation.start(in: database, onChange: { [weak self] in
            Task { @MainActor in self?.requestRefresh() }
        }, onError: { [weak self] error in
            Task { @MainActor in self?.record(error) }
        })
        requestRefresh()
    }

    func stop() {
        observation?.cancel()
        observation = nil
        scheduled?.cancel()
        scheduled = nil
    }

    /// Schedules a refresh `minimumRefreshInterval` after the last one
    /// started, or now; requests until it starts share it, and a request
    /// during a refresh schedules the next one.
    func requestRefresh() {
        guard observation != nil else { return }
        if isRefreshing {
            changedDuringRefresh = true
            return
        }
        guard scheduled == nil else { return }
        let delay = lastRefreshStart.map { start in max(.zero, Self.minimumRefreshInterval - start.duration(to: clock.now)) } ?? .zero
        scheduled = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            scheduled = nil
            await refresh()
        }
    }

    private func refresh() async {
        isRefreshing = true
        changedDuringRefresh = false
        lastRefreshStart = clock.now
        status = .refreshing
        do {
            let members = try await database.writer.read { connection in try ChecklistDuplicates.confirmedMembers(in: connection) }
            try await ChecklistDuplicates.replace(with: members, in: database.writer)
            status = .refreshed(memberCount: members.count)
        } catch {
            record(error)
        }
        isRefreshing = false
        if changedDuringRefresh {
            requestRefresh()
        }
    }

    private func record(_ error: Error) {
        let message = UserFacingErrorMessage.message(for: error)
        status = .failed(message)
        Self.logger.error("Duplicate checklist refresh failed: \(message, privacy: .public)")
    }
}
