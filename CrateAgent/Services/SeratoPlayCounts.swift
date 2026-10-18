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

/// What the library's path history looked like when plays were attributed:
/// any import, removal or path change moves it. Path changes always journal
/// one of `SeratoPlayCounts.pathChangeEvents`.
struct SeratoLibraryPathSignature: Equatable, Sendable {
    let fileCount: Int
    let highestFileID: Int64?
    let highestPathChangeEventID: Int64?
}

/// The attributed counts for one History read, and the row changes that
/// bring `serato_play_counts` to them.
struct SeratoPlayCountPlan: Sendable {
    let summary: SeratoPlayCountSummary
    let library: SeratoLibraryPathSignature
    /// Files whose count is new or changed.
    let upserts: [Int64: Int]
    /// Files that no longer have attributed plays.
    let deletions: [Int64]

    var changesTable: Bool {
        !upserts.isEmpty || !deletions.isEmpty
    }
}

/// Attributes Serato History plays to library files and keeps
/// `serato_play_counts` equal to the result. The table is derived external
/// evidence, like the fingerprint cache: there is no user intent and no
/// inverse, so it is rewritten directly rather than through `applyMutation`,
/// and it never writes `files`, tags or Serato.
///
/// A play counts for the file that was at its path when it started. Each
/// file's past paths come from its path-change events; a path is a label
/// that can be reused, so a play whose path two files claimed at that
/// moment, or none, stays unattributed.
enum SeratoPlayCounts {
    static let table = "serato_play_counts"
    private static let logger = Logger(subsystem: "com.crateagent.app", category: "SeratoPlayCounts")
    static let pathChangeEvents: [EventType] = [.fileRenamed, .fileLocationObserved, .fileIdentityObserved]

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

    static func librarySignature(in database: GRDB.Database) throws -> SeratoLibraryPathSignature {
        let types = pathChangeEvents.map(\.rawValue)
        let placeholders = types.map { _ in "?" }.joined(separator: ", ")
        let row = try Row.fetchOne(database, sql: """
        SELECT (SELECT COUNT(*) FROM files) AS file_count, (SELECT MAX(id) FROM files) AS highest_file_id,
               (SELECT MAX(event_id) FROM events WHERE event_type IN (\(placeholders)) AND file_id IS NOT NULL) AS highest_event_id
        """, arguments: StatementArguments(types))
        guard let row else { throw SeratoPlayCountError.missingSignature }
        return SeratoLibraryPathSignature(fileCount: row["file_count"], highestFileID: row["highest_file_id"],
                                          highestPathChangeEventID: row["highest_event_id"])
    }

    /// Reads only; run it in a read transaction so attribution never holds the writer.
    static func plan(from scan: SeratoHistoryScan, in database: GRDB.Database) throws -> SeratoPlayCountPlan {
        let library = try librarySignature(in: database)
        let occupancies = try occupanciesByPath(in: database)
        var counts: [Int64: Int] = [:]
        var unattributed = 0
        var normalizedPaths: [String: String] = [:]
        for play in scan.plays {
            let startedAt = Int64(play.startedAt) * 1000
            let normalized = normalizedPaths[play.path] ?? SeratoPath.normalized(play.path)
            normalizedPaths[play.path] = normalized
            let claimants = Set((occupancies[normalized] ?? [])
                .filter { occupancy in occupancy.start <= startedAt && startedAt < occupancy.end }
                .map(\.fileID))
            guard claimants.count == 1, let fileID = claimants.first else {
                unattributed += 1
                continue
            }
            counts[fileID, default: 0] += 1
        }
        let stored = try all(in: database)
        let summary = SeratoPlayCountSummary(sessionCount: Int(scan.sessionCount), playCount: scan.plays.count,
                                             attributedCount: scan.plays.count - unattributed, unattributedCount: unattributed,
                                             unplayedCount: Int(scan.unplayedCount), nonFileCount: Int(scan.nonFileCount))
        return SeratoPlayCountPlan(summary: summary, library: library,
                                   upserts: counts.filter { fileID, count in stored[fileID] != count },
                                   deletions: stored.keys.filter { fileID in counts[fileID] == nil }.sorted())
    }

    /// Writes only the plan's row changes. Returns false, writing nothing,
    /// when the library's paths changed since the plan was attributed.
    static func apply(_ plan: SeratoPlayCountPlan, in database: GRDB.Database) throws -> Bool {
        guard try librarySignature(in: database) == plan.library else { return false }
        let delete = try database.makeStatement(sql: "DELETE FROM \(table) WHERE file_id = ?")
        for fileID in plan.deletions {
            try delete.execute(arguments: [fileID])
        }
        let upsert = try database.makeStatement(sql: """
        INSERT INTO \(table) (file_id, play_count) VALUES (?, ?) ON CONFLICT(file_id) DO UPDATE SET play_count = excluded.play_count
        """)
        for (fileID, count) in plan.upserts {
            try upsert.execute(arguments: [fileID, count])
        }
        let summary = plan.summary
        logger.info("""
        Serato History: \(summary.sessionCount) sessions, \(summary.playCount) plays, \(summary.attributedCount) attributed, \
        \(summary.unattributedCount) unattributed, \(summary.unplayedCount) unplayed, \(summary.nonFileCount) non-file; \
        \(plan.upserts.count) counts written, \(plan.deletions.count) removed
        """)
        return true
    }

    private static func occupanciesByPath(in database: GRDB.Database) throws -> [String: [Occupancy]] {
        var changesByFile: [Int64: [(timestamp: Int64, oldPath: String, newPath: String)]] = [:]
        // Journal order, not timestamps: a file's changes chain old path to
        // new path in the order they were applied, even if the clock moved.
        let types = pathChangeEvents.map(\.rawValue)
        let events = try Row.fetchCursor(database, sql: """
        SELECT file_id, timestamp, event_type, payload_json,
               CASE WHEN event_type = ? THEN inverse_payload_json END AS inverse_payload_json
        FROM events WHERE event_type IN (\(types.map { _ in "?" }.joined(separator: ", "))) AND file_id IS NOT NULL ORDER BY event_id
        """, arguments: StatementArguments([EventType.fileLocationObserved.rawValue] + types))
        let decoder = JSONDecoder()
        while let event = try events.next() {
            let fileID: Int64 = event["file_id"]
            let (oldPath, newPath) = try paths(changedBy: event, decoder: decoder)
            if oldPath != newPath {
                changesByFile[fileID, default: []].append((event["timestamp"], oldPath, newPath))
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

    /// Only the paths of each payload are decoded: a large library journals
    /// tens of thousands of identity observations, one per owned tag write.
    private struct PathOnly: Decodable {
        let path: String
    }

    private struct RenamePaths: Decodable {
        let previousPath: String
        let newPath: String
    }

    private struct IdentityPaths: Decodable {
        let previousIdentity: PathOnly
        let identity: PathOnly
    }

    private static func paths(changedBy event: Row, decoder: JSONDecoder) throws -> (old: String, new: String) {
        let type: String = event["event_type"]
        let forward = Data((event["payload_json"] as String).utf8)
        switch EventType(rawValue: type) {
        case .fileRenamed:
            let payload = try decoder.decode(RenamePaths.self, from: forward)
            return (payload.previousPath, payload.newPath)
        case .fileLocationObserved:
            let inverse = try decoder.decode(PathOnly.self, from: Data((event["inverse_payload_json"] as String).utf8))
            return try (inverse.path, decoder.decode(PathOnly.self, from: forward).path)
        case .fileIdentityObserved:
            let payload = try decoder.decode(IdentityPaths.self, from: forward)
            return (payload.previousIdentity.path, payload.identity.path)
        default:
            throw SeratoPlayCountError.unexpectedEvent(type)
        }
    }
}

enum SeratoPlayCountError: LocalizedError, Equatable {
    case unexpectedEvent(String)
    case missingSignature

    var errorDescription: String? {
        switch self {
        case let .unexpectedEvent(type): "Play-count attribution read an unexpected \(type) event."
        case .missingSignature: "Play-count attribution could not read the library's path history."
        }
    }
}
