import Foundation
import GRDB
import os
import SQLite3

/// Runs the library's WAL checkpoints on a connection of its own instead of
/// inside the writer's commits. While a reader holds an old snapshot, as an
/// open Library page does, SQLite cannot copy the WAL back into the database,
/// so the next commit after that reader closes copies the whole backlog and
/// syncs both files before the writer can serve anyone else: 0.79 s on CI for
/// 25,000 pages (#259). A passive checkpoint never takes the write lock, so
/// here it runs beside the writer.
final class WALCheckpointer: @unchecked Sendable {
    /// SQLite's own automatic checkpoint threshold.
    static let pageThreshold: Int32 = 1000

    private static let logger = Logger(subsystem: "com.crateagent.app", category: "WALCheckpointer")
    private let queue = DispatchQueue(label: "com.crateagent.wal-checkpoint", qos: .utility)
    private let lock = NSLock()
    private var connection: DatabaseQueue?
    private var scheduled = false

    /// Replaces the writer's automatic checkpoint with one scheduled here.
    /// The callback keeps no strong reference: the pool's configuration,
    /// which captures this checkpointer, outlives the writer connection.
    func install(on database: Database) {
        guard let sqliteConnection = database.sqliteConnection else { return }
        sqlite3_wal_hook(sqliteConnection, { context, _, _, pages in
            guard let context else { return SQLITE_OK }
            Unmanaged<WALCheckpointer>.fromOpaque(context).takeUnretainedValue().walDidGrow(to: pages)
            return SQLITE_OK
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Opens the checkpointing connection once the pool has put the file in WAL mode.
    func attach(path: String) throws {
        let opened = try DatabaseQueue(path: path)
        lock.withLock { connection = opened }
    }

    private func walDidGrow(to pages: Int32) {
        guard pages >= Self.pageThreshold else { return }
        let start = lock.withLock {
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if start {
            queue.async { [self] in checkpoint() }
        }
    }

    private func checkpoint() {
        let current = lock.withLock {
            scheduled = false
            return connection
        }
        guard let current else { return }
        do {
            try current.writeWithoutTransaction { database in try database.checkpoint(.passive) }
        } catch {
            Self.logger.fault("WAL checkpoint failed; the write-ahead log keeps growing until one succeeds: \(error.localizedDescription, privacy: .public)")
        }
    }
}
