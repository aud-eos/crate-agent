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

/// Keeps `checklist_duplicate_members` in step with the duplicate groups:
/// once at start, then a second after the first of any burst of changes
/// that can alter a group.
@MainActor
final class ChecklistDuplicateRefresher: ObservableObject {
    private static let coalescingDelay: Duration = .seconds(1)
    private static let logger = Logger(subsystem: "com.crateagent.app", category: "ChecklistDuplicateRefresher")

    /// The reason the last refresh failed; the members shown are older.
    @Published private(set) var failure: String?

    private let database: LibraryDatabase
    private var observation: AnyDatabaseCancellable?
    private var scheduled: Task<Void, Never>?
    private var isRefreshing = false
    private var refreshRequested = false

    init(database: LibraryDatabase) {
        self.database = database
    }

    func start() {
        guard observation == nil else { return }
        observation = DuplicateScanObservation.start(in: database, onChange: { [weak self] in
            Task { @MainActor in self?.schedule() }
        }, onError: { [weak self] error in
            Task { @MainActor in self?.record(error) }
        })
        Task { await refreshReportingFailure() }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        scheduled?.cancel()
        scheduled = nil
    }

    /// A request made while a refresh runs is coalesced into one more pass.
    func refresh() async throws {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequested = false
            let members = try await database.writer.read { connection in try ChecklistDuplicates.confirmedMembers(in: connection) }
            try await ChecklistDuplicates.replace(with: members, in: database.writer)
        } while refreshRequested
        failure = nil
    }

    private func schedule() {
        guard scheduled == nil, observation != nil else { return }
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: Self.coalescingDelay)
            guard let self, !Task.isCancelled else { return }
            scheduled = nil
            await refreshReportingFailure()
        }
    }

    private func refreshReportingFailure() async {
        do { try await refresh() } catch { record(error) }
    }

    private func record(_ error: Error) {
        let message = UserFacingErrorMessage.message(for: error)
        failure = message
        Self.logger.error("Duplicate checklist refresh failed: \(message, privacy: .public)")
    }
}
