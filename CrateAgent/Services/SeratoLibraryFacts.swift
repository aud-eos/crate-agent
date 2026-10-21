import Foundation
import GRDB

/// A source the checklist caches, keyed in `checklist_source_stamps`. `SeratoLibraryFactsService`
/// owns `databaseV2` and `subcrates`; `SeratoPlayCountService` owns `history`, whose stamp says
/// Serato History has been read at least once, so play counts are known; `PopularityService` owns
/// `popularity`, whose stamp says a lookup pass has completed since a source was switched on.
enum ChecklistSource: String, CaseIterable, Sendable {
    case databaseV2 = "database_v2"
    case subcrates
    case history
    case popularity
}

/// Where a file's date added came from: Serato's V2 record, or, when V2 has
/// none, the first time crate-agent journaled the file.
enum DateAddedSource: String, Codable, Sendable, DatabaseValueConvertible {
    case serato
    case indexed
}

/// One file's cached V2 facts. `beatgridLocked` is nil when V2 says nothing.
struct SeratoFileFacts: Equatable, Sendable {
    let beatgridLocked: Bool?
    /// Unix seconds.
    let addedAt: Int64?
    let addedSource: DateAddedSource
}

struct SeratoLibraryFactsSummary: Equatable, Sendable {
    /// V2 records matched to a library file.
    let trackFactCount: Int
    let crateCount: Int
    let membershipCount: Int
    /// V2 and crate paths no library file held or two files claimed, and V2
    /// records repeating a file another record already matched.
    let unmatchedPathCount: Int
}

/// What one source's last full read yielded. It is stored with the source's
/// stamp, so a restart that reads nothing still reports it.
struct SeratoLibraryFactsOutcome: Codable, Equatable, Sendable {
    var matchedRecordCount = 0
    var crateCount = 0
    var membershipCount = 0
    var unmatchedPathCount = 0
    /// V2 records Serato's reader dropped as malformed.
    var malformedRecordCount = 0

    static func + (first: Self, second: Self) -> Self {
        Self(matchedRecordCount: first.matchedRecordCount + second.matchedRecordCount, crateCount: first.crateCount + second.crateCount,
             membershipCount: first.membershipCount + second.membershipCount,
             unmatchedPathCount: first.unmatchedPathCount + second.unmatchedPathCount,
             malformedRecordCount: first.malformedRecordCount + second.malformedRecordCount)
    }

    var summary: SeratoLibraryFactsSummary {
        SeratoLibraryFactsSummary(trackFactCount: matchedRecordCount, crateCount: crateCount, membershipCount: membershipCount,
                                  unmatchedPathCount: unmatchedPathCount)
    }
}

struct ChecklistSourceStamp: Codable, Equatable, Sendable {
    /// JSON of the source's file identities, the library's path signature and
    /// its last membership change when it was read; the source is read again
    /// only when this changes.
    let inputs: String
    let outcome: SeratoLibraryFactsOutcome

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case inputs, outcome
    }

    init(inputs: String, outcome: SeratoLibraryFactsOutcome) {
        self.inputs = inputs
        self.outcome = outcome
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyStampKey.self)
        let expected = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = container.allKeys.first(where: { key in !expected.contains(key.stringValue) }) {
            throw DecodingError.dataCorruptedError(forKey: unknown, in: container, debugDescription: "Unknown checklist stamp field \(unknown.stringValue)")
        }
        let known = try decoder.container(keyedBy: CodingKeys.self)
        inputs = try known.decode(String.self, forKey: .inputs)
        outcome = try known.decode(SeratoLibraryFactsOutcome.self, forKey: .outcome)
    }

    private struct AnyStampKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }
}

struct SeratoCrateMembership: Hashable, Sendable {
    let fileID: Int64
    let crateName: String
}

/// The row changes that bring the fact tables to one read of the sources.
struct SeratoLibraryFactsPlan: Sendable {
    let library: SeratoLibraryPathSignature
    let factUpserts: [Int64: SeratoFileFacts]
    let factDeletions: [Int64]
    let membershipInserts: [SeratoCrateMembership]
    let membershipDeletions: [SeratoCrateMembership]
    /// The stamps of the sources this plan read, written last.
    let stamps: [ChecklistSource: ChecklistSourceStamp]
    /// Both sources' outcomes: this read's, or the stored one for a source not read.
    let outcome: SeratoLibraryFactsOutcome
}

enum SeratoLibraryFactsError: LocalizedError, Equatable {
    case missingStamp(ChecklistSource)
    case unreadableStamp(ChecklistSource)
    case unexpectedSource(String)
    case unexpectedDateAddedSource(String)

    var errorDescription: String? {
        switch self {
        case let .missingStamp(source): "Serato facts have no stored read of \(source.rawValue)."
        case let .unreadableStamp(source): "Serato facts couldn't check for a stored read of \(source.rawValue)."
        case let .unexpectedSource(source): "Serato facts found an unknown source \(source)."
        case let .unexpectedDateAddedSource(source): "Serato facts found an unknown date-added source \(source)."
        }
    }
}

/// Caches Serato's per-file V2 facts (beatgrid lock, date added) and
/// Subcrates membership by `file_id`. Like play counts, these are derived
/// external evidence with no user intent or inverse, so they are rewritten
/// directly rather than through `applyMutation`; Serato's files are only read.
///
/// Paths map to files by `SeratoPath.normalized` over non-retired files. A
/// path two files claim, or none, is unmatched. SmartCrates are not
/// membership: they are rules whose cached track list Serato maintains.
enum SeratoLibraryFacts {
    static let factsTable = "serato_track_facts"
    static let membershipTable = "serato_crate_memberships"
    static let stampTable = "checklist_source_stamps"
    static let rowsPerTransaction = 1000
    /// The sources this service reads and stamps.
    static let sources: [ChecklistSource] = [.databaseV2, .subcrates]

    static func writeStamp(_ source: ChecklistSource, _ stamp: String, in database: GRDB.Database) throws {
        try database.execute(sql: """
        INSERT INTO \(stampTable) (source, stamp) VALUES (?, ?)
        ON CONFLICT(source) DO UPDATE SET stamp = excluded.stamp WHERE stamp IS NOT excluded.stamp
        """, arguments: [source.rawValue, stamp])
    }

    static func hasStamp(_ source: ChecklistSource, in database: GRDB.Database) throws -> Bool {
        guard let exists = try Bool.fetchOne(database, sql: "SELECT EXISTS (SELECT 1 FROM \(stampTable) WHERE source = ?)", arguments: [source.rawValue])
        else { throw SeratoLibraryFactsError.unreadableStamp(source) }
        return exists
    }

    static func facts(in database: GRDB.Database) throws -> [Int64: SeratoFileFacts] {
        var facts: [Int64: SeratoFileFacts] = [:]
        let rows = try Row.fetchCursor(database, sql: "SELECT file_id, beatgrid_locked, added_at, added_source FROM \(factsTable)")
        while let row = try rows.next() {
            let source: String = row["added_source"]
            guard let addedSource = DateAddedSource(rawValue: source) else {
                throw SeratoLibraryFactsError.unexpectedDateAddedSource(source)
            }
            facts[row["file_id"]] = SeratoFileFacts(beatgridLocked: row["beatgrid_locked"], addedAt: row["added_at"], addedSource: addedSource)
        }
        return facts
    }

    static func memberships(in database: GRDB.Database) throws -> [Int64: Set<String>] {
        var memberships: [Int64: Set<String>] = [:]
        let rows = try Row.fetchCursor(database, sql: "SELECT file_id, crate_name FROM \(membershipTable)")
        while let row = try rows.next() {
            memberships[row["file_id"], default: []].insert(row["crate_name"])
        }
        return memberships
    }

    /// Events that change a file's `library_membership`. The shared path
    /// signature leaves them out because plays still count for retired files,
    /// but they decide which files the facts cover.
    static let membershipChangeEvents: [EventType] = [.fileLibraryStateChanged, .fileImportRequested, .fileRestoredFromTrash]

    static func lastMembershipChange(in database: GRDB.Database) throws -> Int64? {
        let types = membershipChangeEvents.map(\.rawValue)
        return try Int64.fetchOne(database, sql: """
        SELECT MAX(event_id) FROM events WHERE event_type IN (\(types.map { _ in "?" }.joined(separator: ", ")))
        """, arguments: StatementArguments(types))
    }

    /// The stamps of this service's own `sources`; another owner's source is skipped, and an unknown one throws.
    static func storedStamps(in database: GRDB.Database) throws -> [ChecklistSource: ChecklistSourceStamp] {
        var stamps: [ChecklistSource: ChecklistSourceStamp] = [:]
        let decoder = JSONDecoder()
        let rows = try Row.fetchCursor(database, sql: "SELECT source, stamp FROM \(stampTable)")
        while let row = try rows.next() {
            let name: String = row["source"]
            guard let source = ChecklistSource(rawValue: name) else { throw SeratoLibraryFactsError.unexpectedSource(name) }
            switch source {
            case .databaseV2, .subcrates:
                stamps[source] = try decoder.decode(ChecklistSourceStamp.self, from: Data((row["stamp"] as String).utf8))
            case .history, .popularity:
                continue
            }
        }
        return stamps
    }

    /// Reads only; run it in a read transaction. A nil source was not read
    /// and keeps its rows; `stamps` holds every source's current inputs.
    static func plan(facts scan: SeratoTrackFactsScan?, crates: [String: [String]]?, stamps: [ChecklistSource: String],
                     in database: GRDB.Database) throws -> SeratoLibraryFactsPlan
    {
        let library = try SeratoPlayCounts.librarySignature(in: database)
        let stored = try storedStamps(in: database)
        let resolver = try PathResolver(in: database)
        var readStamps: [ChecklistSource: ChecklistSourceStamp] = [:]
        var outcome = SeratoLibraryFactsOutcome()
        func record(_ source: ChecklistSource, _ sourceOutcome: SeratoLibraryFactsOutcome?) throws {
            if let sourceOutcome {
                guard let inputs = stamps[source] else { throw SeratoLibraryFactsError.missingStamp(source) }
                readStamps[source] = ChecklistSourceStamp(inputs: inputs, outcome: sourceOutcome)
                outcome = outcome + sourceOutcome
            } else {
                guard let previous = stored[source] else { throw SeratoLibraryFactsError.missingStamp(source) }
                outcome = outcome + previous.outcome
            }
        }

        var factUpserts: [Int64: SeratoFileFacts] = [:]
        var factDeletions: [Int64] = []
        var factsOutcome: SeratoLibraryFactsOutcome?
        if let scan {
            var sourceOutcome = SeratoLibraryFactsOutcome(malformedRecordCount: Int(scan.malformedRecordCount))
            let firstIndexed = try firstEventSeconds(in: database)
            var desired: [Int64: SeratoFileFacts] = [:]
            for track in scan.tracks {
                guard let fileID = resolver.fileID(for: track.path), desired[fileID] == nil else {
                    sourceOutcome.unmatchedPathCount += 1
                    continue
                }
                let addedAt = track.addedAt.map(Int64.init)
                desired[fileID] = SeratoFileFacts(beatgridLocked: track.beatgridLocked, addedAt: addedAt ?? firstIndexed[fileID],
                                                  addedSource: addedAt == nil ? .indexed : .serato)
            }
            sourceOutcome.matchedRecordCount = desired.count
            // With records dropped as malformed, a file without one may be
            // among them, so its facts become unknown rather than invented.
            if scan.malformedRecordCount == 0 {
                for fileID in resolver.fileIDs where desired[fileID] == nil {
                    desired[fileID] = SeratoFileFacts(beatgridLocked: nil, addedAt: firstIndexed[fileID], addedSource: .indexed)
                }
            }
            let current = try facts(in: database)
            factUpserts = desired.filter { fileID, facts in current[fileID] != facts }
            factDeletions = current.keys.filter { fileID in desired[fileID] == nil }.sorted()
            factsOutcome = sourceOutcome
        }
        try record(.databaseV2, factsOutcome)

        var membershipInserts: [SeratoCrateMembership] = []
        var membershipDeletions: [SeratoCrateMembership] = []
        var cratesOutcome: SeratoLibraryFactsOutcome?
        if let crates {
            var sourceOutcome = SeratoLibraryFactsOutcome(crateCount: crates.count)
            var desired = Set<SeratoCrateMembership>()
            for (crateName, paths) in crates {
                for path in paths {
                    guard let fileID = resolver.fileID(for: path) else {
                        sourceOutcome.unmatchedPathCount += 1
                        continue
                    }
                    desired.insert(SeratoCrateMembership(fileID: fileID, crateName: crateName))
                }
            }
            sourceOutcome.membershipCount = desired.count
            let current = try Set(memberships(in: database).flatMap { fileID, crateNames in
                crateNames.map { crateName in SeratoCrateMembership(fileID: fileID, crateName: crateName) }
            })
            membershipInserts = Array(desired.subtracting(current))
            membershipDeletions = Array(current.subtracting(desired))
            cratesOutcome = sourceOutcome
        }
        try record(.subcrates, cratesOutcome)

        return SeratoLibraryFactsPlan(library: library, factUpserts: factUpserts, factDeletions: factDeletions,
                                      membershipInserts: membershipInserts, membershipDeletions: membershipDeletions,
                                      stamps: readStamps, outcome: outcome)
    }

    /// Writes the plan in transactions of at most `rowsPerTransaction` rows,
    /// with the stamps in the last, so an interrupted refresh reads again.
    /// Returns false, leaving the stamps unwritten, when the library's paths
    /// changed since the plan was made.
    static func apply(_ plan: SeratoLibraryFactsPlan, to writer: any DatabaseWriter) async throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var operations: [Operation] = plan.factDeletions.map(Operation.deleteFact)
        operations += plan.factUpserts.sorted { first, second in first.key < second.key }.map(Operation.upsertFact)
        operations += plan.membershipDeletions.map(Operation.deleteMembership)
        operations += plan.membershipInserts.map(Operation.insertMembership)
        operations += try plan.stamps.map { source, stamp in
            try Operation.stamp(source, String(decoding: encoder.encode(stamp), as: UTF8.self))
        }
        for start in stride(from: 0, to: operations.count, by: rowsPerTransaction) {
            let chunk = Array(operations[start ..< min(start + rowsPerTransaction, operations.count)])
            let applied = try await writer.write { database in
                guard try SeratoPlayCounts.librarySignature(in: database) == plan.library else { return false }
                for operation in chunk {
                    try operation.execute(in: database)
                }
                return true
            }
            guard applied else { return false }
        }
        return true
    }

    private enum Operation: Sendable {
        case upsertFact(Int64, SeratoFileFacts)
        case deleteFact(Int64)
        case insertMembership(SeratoCrateMembership)
        case deleteMembership(SeratoCrateMembership)
        case stamp(ChecklistSource, String)

        func execute(in database: GRDB.Database) throws {
            switch self {
            case let .upsertFact(fileID, facts):
                try database.execute(sql: """
                INSERT INTO \(factsTable) (file_id, beatgrid_locked, added_at, added_source) VALUES (?, ?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET beatgrid_locked = excluded.beatgrid_locked, added_at = excluded.added_at,
                    added_source = excluded.added_source
                """, arguments: [fileID, facts.beatgridLocked, facts.addedAt, facts.addedSource])
            case let .deleteFact(fileID):
                try database.execute(sql: "DELETE FROM \(factsTable) WHERE file_id = ?", arguments: [fileID])
            case let .insertMembership(membership):
                try database.execute(sql: "INSERT INTO \(membershipTable) (file_id, crate_name) VALUES (?, ?)",
                                     arguments: [membership.fileID, membership.crateName])
            case let .deleteMembership(membership):
                try database.execute(sql: "DELETE FROM \(membershipTable) WHERE file_id = ? AND crate_name = ?",
                                     arguments: [membership.fileID, membership.crateName])
            case let .stamp(source, stamp):
                try writeStamp(source, stamp, in: database)
            }
        }
    }

    /// Each non-retired file's first journaled event, in Unix seconds.
    private static func firstEventSeconds(in database: GRDB.Database) throws -> [Int64: Int64] {
        var seconds: [Int64: Int64] = [:]
        let rows = try Row.fetchCursor(database, sql: """
        SELECT file_id, MIN(timestamp) AS first_timestamp FROM events
        WHERE file_id IN (SELECT id FROM files WHERE library_membership != ?) GROUP BY file_id
        """, arguments: [LibraryMembership.retired])
        while let row = try rows.next() {
            seconds[row["file_id"]] = (row["first_timestamp"] as Int64) / 1000
        }
        return seconds
    }

    /// Maps Serato paths to the one non-retired file at each normalized path.
    private struct PathResolver {
        private var claimants: [String: [Int64]] = [:]
        private(set) var fileIDs = Set<Int64>()

        init(in database: GRDB.Database) throws {
            let rows = try Row.fetchCursor(database, sql: "SELECT id, path FROM files WHERE library_membership != ?",
                                           arguments: [LibraryMembership.retired])
            while let row = try rows.next() {
                let fileID: Int64 = row["id"]
                fileIDs.insert(fileID)
                claimants[SeratoPath.normalized(row["path"]), default: []].append(fileID)
            }
        }

        func fileID(for seratoPath: String) -> Int64? {
            guard let files = claimants[SeratoPath.normalized(seratoPath)], files.count == 1 else { return nil }
            return files.first
        }
    }
}
