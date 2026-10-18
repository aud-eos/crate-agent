import Foundation
import GRDB
import os.log

/// What one rebuild of the play-count cache found.
struct SeratoPlayCountSummary: Equatable, Sendable {
    let sessionCount: Int
    /// Played file entries in History.
    let playCount: Int
    let attributedCount: Int
    /// Plays at a path no library file held at the time, or that two files claimed.
    let unattributedCount: Int
    let unplayedCount: Int
    /// Played entries that are not files, such as streaming tracks.
    let nonFileCount: Int
}

/// Attributes Serato History plays to library files and rebuilds
/// `serato_play_counts`. The table is derived external evidence, like the
/// fingerprint cache: there is no user intent and no inverse, so it is
/// rebuilt wholesale rather than through `applyMutation`, and it never
/// writes `files`, tags or Serato.
///
/// A play counts for the file that was at its path when it started. Each
/// file's past paths come from its path-change events; a path is a label
/// that can be reused, so a play whose path two files claimed at that
/// moment, or none, stays unattributed.
enum SeratoPlayCounts {
    static let table = "serato_play_counts"
    private static let logger = Logger(subsystem: "com.crateagent.app", category: "SeratoPlayCounts")
    private static let pathChangeEvents: [EventType] = [.fileRenamed, .fileLocationObserved, .fileIdentityObserved]

    /// A file's stay at one path, in event-log milliseconds: [start, end).
    private struct Occupancy {
        let fileID: Int64
        let start: Int64
        let end: Int64
    }

    /// Every file's attributed plays. The table holds at most one row per played file.
    static func all(in database: GRDB.Database) throws -> [Int64: Int] {
        var counts: [Int64: Int] = [:]
        let rows = try Row.fetchCursor(database, sql: "SELECT file_id, play_count FROM \(table)")
        while let row = try rows.next() {
            counts[row["file_id"]] = row["play_count"]
        }
        return counts
    }

    static func rebuild(from scan: SeratoHistoryScan, in database: GRDB.Database) throws -> SeratoPlayCountSummary {
        let occupancies = try occupanciesByPath(in: database)
        var counts: [Int64: (plays: Int, lastPlayedAt: UInt64)] = [:]
        var unattributed = 0
        for play in scan.plays {
            let startedAt = Int64(play.startedAt) * 1000
            let claimants = Set((occupancies[SeratoPath.normalized(play.path)] ?? [])
                .filter { occupancy in occupancy.start <= startedAt && startedAt < occupancy.end }
                .map(\.fileID))
            guard claimants.count == 1, let fileID = claimants.first else {
                unattributed += 1
                continue
            }
            let previous = counts[fileID] ?? (0, 0)
            counts[fileID] = (previous.plays + 1, max(previous.lastPlayedAt, play.startedAt))
        }
        try database.execute(sql: "DELETE FROM \(table)")
        let insert = try database.makeStatement(sql: "INSERT INTO \(table) (file_id, play_count, last_played_at) VALUES (?, ?, ?)")
        for (fileID, count) in counts {
            try insert.execute(arguments: [fileID, count.plays, Int64(count.lastPlayedAt)])
        }
        let summary = SeratoPlayCountSummary(sessionCount: Int(scan.sessionCount), playCount: scan.plays.count,
                                             attributedCount: scan.plays.count - unattributed, unattributedCount: unattributed,
                                             unplayedCount: Int(scan.unplayedCount), nonFileCount: Int(scan.nonFileCount))
        logger.info("""
        Serato History: \(summary.sessionCount) sessions, \(summary.playCount) plays, \(summary.attributedCount) attributed, \
        \(summary.unattributedCount) unattributed, \(summary.unplayedCount) unplayed, \(summary.nonFileCount) non-file
        """)
        return summary
    }

    private static func occupanciesByPath(in database: GRDB.Database) throws -> [String: [Occupancy]] {
        var changesByFile: [Int64: [(timestamp: Int64, oldPath: String, newPath: String)]] = [:]
        let events = try EventRecord
            .filter(pathChangeEvents.map(\.rawValue).contains(Column("event_type")) && Column("file_id") != nil)
            .order(Column("timestamp"), Column("event_id"))
            .fetchCursor(database)
        while let event = try events.next() {
            guard let fileID = event.fileId else { continue }
            let (oldPath, newPath) = try paths(changedBy: event)
            if oldPath != newPath {
                changesByFile[fileID, default: []].append((event.timestamp, oldPath, newPath))
            }
        }
        var occupancies: [String: [Occupancy]] = [:]
        let files = try Row.fetchCursor(database, sql: "SELECT id, path FROM files")
        while let file = try files.next() {
            let fileID: Int64 = file["id"]
            var start = Int64.min
            for change in changesByFile[fileID] ?? [] {
                occupancies[SeratoPath.normalized(change.oldPath), default: []].append(Occupancy(fileID: fileID, start: start, end: change.timestamp))
                start = change.timestamp
            }
            occupancies[SeratoPath.normalized(file["path"]), default: []].append(Occupancy(fileID: fileID, start: start, end: Int64.max))
        }
        return occupancies
    }

    private static func paths(changedBy event: EventRecord) throws -> (old: String, new: String) {
        let decoder = JSONDecoder()
        let forward = Data(event.payloadJson.utf8)
        switch event.eventType {
        case .fileRenamed:
            let payload = try decoder.decode(RenameFilePayload.self, from: forward)
            return (payload.previousPath, payload.newPath)
        case .fileLocationObserved:
            let inverse = try decoder.decode(ObserveFileLocationPayload.self, from: Data(event.inversePayloadJson.utf8))
            return try (inverse.path, decoder.decode(ObserveFileLocationPayload.self, from: forward).path)
        case .fileIdentityObserved:
            let payload = try decoder.decode(ObserveFileIdentityPayload.self, from: forward)
            return (payload.previousIdentity.path, payload.identity.path)
        default:
            throw SeratoPlayCountError.unexpectedEvent(event.eventType.rawValue)
        }
    }
}

enum SeratoPlayCountError: LocalizedError, Equatable {
    case unexpectedEvent(String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedEvent(type): "Play-count attribution read an unexpected \(type) event."
        }
    }
}
