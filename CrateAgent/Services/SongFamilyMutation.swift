import CryptoKit
import Foundation
import GRDB

/// A recording to place in a song family. `.file` names a Library row; inside
/// the transaction it resolves to the file's linked recording, or to the
/// `tracks` row its current Chromaprint fingerprint identifies (created when
/// none exists yet), so unmatched files can be grouped without MusicBrainz data.
public enum SongFamilyMember: Codable, Sendable, Hashable {
    case track(Int64)
    case file(Int64)
}

/// User-directed song-family changes, applied through
/// `OperationEngine.apply(.songFamily(_:))`. Each journals the affected
/// families, recording assignments, and file links before and after, so undo
/// restores membership and the saved representative exactly.
public enum SongFamilyOperation: Codable, Sendable, Equatable {
    case create(members: [SongFamilyMember], representative: SongFamilyMember?)
    case attach(familyId: Int64, members: [SongFamilyMember])
    case detach(familyId: Int64, trackIds: [Int64])
    case merge(familyId: Int64, mergedFamilyIds: [Int64])
    case split(familyId: Int64, trackIds: [Int64])
    case setRepresentative(familyId: Int64, trackId: Int64?)
    /// The inverse of every other operation. Produced by undo only.
    case restore(RestoreSongFamiliesPayload)

    var eventType: EventType {
        switch self {
        case .create: .songFamilyCreated
        case .attach: .songFamilyMembersAttached
        case .detach: .songFamilyMembersDetached
        case .merge: .songFamiliesMerged
        case .split: .songFamilySplit
        case .setRepresentative: .songFamilyRepresentativeChanged
        case .restore: .songFamilyRestored
        }
    }
}

/// The journaled state of every family, recording, and file link an operation
/// touched. A family's members are exactly the `assignments` naming it.
public struct SongFamilySnapshot: Codable, Sendable, Equatable {
    public struct Family: Codable, Sendable, Equatable {
        public let familyId: Int64
        public var exists: Bool
        public var representativeTrackId: Int64?
    }

    public struct Assignment: Codable, Sendable, Equatable {
        public let trackId: Int64
        public var familyId: Int64?
    }

    public struct FileLink: Codable, Sendable, Equatable {
        public let fileId: Int64
        public var trackId: Int64?
    }

    public var families: [Family]
    public var assignments: [Assignment]
    public var fileLinks: [FileLink]

    func members(of familyId: Int64) -> [Int64] {
        assignments.filter { assignment in assignment.familyId == familyId }.map(\.trackId)
    }

    func family(_ familyId: Int64) -> Family? {
        families.first { family in family.familyId == familyId }
    }

    mutating func assign(_ trackIds: some Sequence<Int64>, to familyId: Int64?) {
        let moved = Set(trackIds)
        for index in assignments.indices where moved.contains(assignments[index].trackId) {
            assignments[index].familyId = familyId
        }
    }

    mutating func setFamily(_ familyId: Int64, exists: Bool, representativeTrackId: Int64?) {
        guard let index = families.firstIndex(where: { family in family.familyId == familyId }) else { return }
        families[index].exists = exists
        families[index].representativeTrackId = exists ? representativeTrackId : nil
    }

    /// Clears a family whose members dropped below two, leaving them standalone.
    mutating func dissolveIfTooSmall(_ familyId: Int64) {
        let remaining = members(of: familyId)
        guard remaining.count < 2 else { return }
        assign(remaining, to: nil)
        setFamily(familyId, exists: false, representativeTrackId: nil)
    }

    var coverage: [String] {
        families.map { family in "family:\(family.familyId)" } + assignments.map { assignment in "track:\(assignment.trackId)" }
            + fileLinks.map { link in "file:\(link.fileId)" }
    }
}

/// Undo payload: return to `target`, but only if the journaled state is still
/// `expected`. A later change to any covered family, recording, or link makes
/// the undo stale rather than overwriting that change.
public struct RestoreSongFamiliesPayload: Codable, Sendable, Equatable {
    public let target: SongFamilySnapshot
    public let expected: SongFamilySnapshot
}

/// Forward event payload for every song-family event.
public struct SongFamilyChange: Codable, Sendable, Equatable {
    public let operation: SongFamilyOperation
    /// The family the operation created or changed; nil when it dissolved.
    public let familyId: Int64?
    public let before: SongFamilySnapshot
    public let after: SongFamilySnapshot
}

public enum SongFamilyError: LocalizedError, Equatable {
    case familyNotFound(familyId: Int64)
    case trackNotFound(trackId: Int64)
    case recordingUnidentified(fileId: Int64)
    case memberAlreadyInFamily(trackId: Int64, familyId: Int64)
    case notAMember(trackId: Int64, familyId: Int64)
    case tooFewMembers
    case representativeNotMember
    case invalidMerge
    case splitTakesEveryMember(familyId: Int64)
    case changedSinceRecorded
    case malformedRestore

    public var errorDescription: String? {
        switch self {
        case let .familyNotFound(familyId):
            "Song family \(familyId) no longer exists."
        case let .trackNotFound(trackId):
            "Recording \(trackId) is not in the library."
        case let .recordingUnidentified(fileId):
            "File \(fileId) has no current fingerprint yet, so its recording can't be grouped. Wait for fingerprinting to finish."
        case let .memberAlreadyInFamily(trackId, familyId):
            "Recording \(trackId) already belongs to song family \(familyId). Merge the families instead."
        case let .notAMember(trackId, familyId):
            "Recording \(trackId) is not a member of song family \(familyId)."
        case .tooFewMembers:
            "A song family needs at least two different recordings."
        case .representativeNotMember:
            "The main version must be one of the family's recordings."
        case .invalidMerge:
            "Choose at least one other existing song family to merge."
        case let .splitTakesEveryMember(familyId):
            "Splitting every recording out of song family \(familyId) would leave it empty."
        case .changedSinceRecorded:
            "These song families changed after this was recorded. Undo the later change first."
        case .malformedRestore:
            "The recorded song-family undo state is inconsistent."
        }
    }
}

enum SongFamilyMutation {
    static func apply(_ operation: SongFamilyOperation, batchId: String, timestamp: Int64, in database: GRDB.Database) throws -> Int64? {
        let change: SongFamilyChange
        if case let .restore(payload) = operation {
            guard payload.target.coverage == payload.expected.coverage else { throw SongFamilyError.malformedRestore }
            guard try capture(like: payload.expected, in: database) == payload.expected else { throw SongFamilyError.changedSinceRecorded }
            change = SongFamilyChange(operation: operation, familyId: nil, before: payload.expected, after: payload.target)
        } else {
            change = try plan(operation, in: database)
        }
        guard change.before != change.after else { return nil }
        try write(change.after, in: database)
        let inverse = RestoreSongFamiliesPayload(target: change.before, expected: change.after)
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: nil, eventType: operation.eventType,
                                               forwardPayload: change, inversePayload: inverse, in: database)
    }

    private static func plan(_ operation: SongFamilyOperation, in database: GRDB.Database) throws -> SongFamilyChange {
        switch operation {
        case let .create(members, representative):
            let resolved = try resolve(members, in: database)
            guard resolved.trackIds.count >= 2 else { throw SongFamilyError.tooFewMembers }
            try requireStandalone(resolved.trackIds, in: database)
            let representativeID = try representative.map { member in try resolve([member], in: database).trackIds[0] }
            if let representativeID, !resolved.trackIds.contains(representativeID) {
                throw SongFamilyError.representativeNotMember
            }
            var before = try capture(familyIds: [], trackIds: resolved.trackIds, fileIds: resolved.links.keys, in: database)
            let familyID = try insertFamily(into: &before, in: database)
            var after = before
            after.setFamily(familyID, exists: true, representativeTrackId: representativeID)
            after.assign(resolved.trackIds, to: familyID)
            after.fileLinks = linking(after.fileLinks, resolved.links)
            return SongFamilyChange(operation: operation, familyId: familyID, before: before, after: after)

        case let .attach(familyID, members):
            try requireFamily(familyID, in: database)
            let resolved = try resolve(members, in: database)
            guard !resolved.trackIds.isEmpty else { throw SongFamilyError.tooFewMembers }
            try requireStandalone(resolved.trackIds, in: database)
            let before = try capture(familyIds: [familyID], trackIds: resolved.trackIds, fileIds: resolved.links.keys, in: database)
            var after = before
            after.assign(resolved.trackIds, to: familyID)
            after.fileLinks = linking(after.fileLinks, resolved.links)
            return SongFamilyChange(operation: operation, familyId: familyID, before: before, after: after)

        case let .detach(familyID, trackIds):
            try requireFamily(familyID, in: database)
            let before = try capture(familyIds: [familyID], trackIds: trackIds, fileIds: [], in: database)
            try requireMembers(trackIds, of: familyID, in: before)
            var after = before
            after.assign(trackIds, to: nil)
            if let representative = before.family(familyID)?.representativeTrackId, trackIds.contains(representative) {
                after.setFamily(familyID, exists: true, representativeTrackId: nil)
            }
            after.dissolveIfTooSmall(familyID)
            return SongFamilyChange(operation: operation, familyId: after.family(familyID)?.exists == true ? familyID : nil, before: before, after: after)

        case let .merge(familyID, mergedFamilyIds):
            let merged = Set(mergedFamilyIds)
            guard !merged.isEmpty, !merged.contains(familyID) else { throw SongFamilyError.invalidMerge }
            for id in [familyID] + merged.sorted() {
                try requireFamily(id, in: database)
            }
            let before = try capture(familyIds: merged.union([familyID]), trackIds: [], fileIds: [], in: database)
            var after = before
            for id in merged {
                after.assign(before.members(of: id), to: familyID)
                after.setFamily(id, exists: false, representativeTrackId: nil)
            }
            return SongFamilyChange(operation: operation, familyId: familyID, before: before, after: after)

        case let .split(familyID, trackIds):
            let moving = Set(trackIds)
            guard moving.count >= 2 else { throw SongFamilyError.tooFewMembers }
            try requireFamily(familyID, in: database)
            var before = try capture(familyIds: [familyID], trackIds: moving, fileIds: [], in: database)
            try requireMembers(moving, of: familyID, in: before)
            guard before.members(of: familyID).count > moving.count else { throw SongFamilyError.splitTakesEveryMember(familyId: familyID) }
            let splitID = try insertFamily(into: &before, in: database)
            var after = before
            let representative = before.family(familyID)?.representativeTrackId
            let representativeMoves = representative.map(moving.contains) ?? false
            after.assign(moving, to: splitID)
            after.setFamily(splitID, exists: true, representativeTrackId: representativeMoves ? representative : nil)
            if representativeMoves {
                after.setFamily(familyID, exists: true, representativeTrackId: nil)
            }
            after.dissolveIfTooSmall(familyID)
            return SongFamilyChange(operation: operation, familyId: splitID, before: before, after: after)

        case let .setRepresentative(familyID, trackID):
            try requireFamily(familyID, in: database)
            let before = try capture(familyIds: [familyID], trackIds: [], fileIds: [], in: database)
            if let trackID {
                try requireMembers([trackID], of: familyID, in: before)
            }
            var after = before
            after.setFamily(familyID, exists: true, representativeTrackId: trackID)
            return SongFamilyChange(operation: operation, familyId: familyID, before: before, after: after)

        case .restore:
            preconditionFailure("restore is applied directly")
        }
    }

    private struct ResolvedMembers {
        var trackIds: [Int64] = []
        var links: [Int64: Int64] = [:]
    }

    /// Distinct recordings in request order; encodings of one recording count once.
    private static func resolve(_ members: [SongFamilyMember], in database: GRDB.Database) throws -> ResolvedMembers {
        var resolved = ResolvedMembers()
        for member in members {
            let trackID: Int64
            switch member {
            case let .track(id):
                guard try TrackRecord.exists(database, key: id) else { throw SongFamilyError.trackNotFound(trackId: id) }
                trackID = id
            case let .file(fileID):
                guard let file = try FileRecord.fetchOne(database, key: fileID) else { throw OperationEngineError.fileNotFound(fileId: fileID) }
                if let linked = file.trackId {
                    trackID = linked
                } else {
                    trackID = try recording(identifiedBy: file, fileID: fileID, in: database)
                    resolved.links[fileID] = trackID
                }
            }
            if !resolved.trackIds.contains(trackID) {
                resolved.trackIds.append(trackID)
            }
        }
        return resolved
    }

    private static func recording(identifiedBy file: FileRecord, fileID: Int64, in database: GRDB.Database) throws -> Int64 {
        guard file.libraryMembership != .retired, file.fingerprintStatus == .done, let fingerprint = file.chromaprintFingerprint,
              (file.fingerprintedSize ?? file.fileSize) == file.fileSize, (file.fingerprintedMtime ?? file.mtime) == file.mtime
        else {
            throw SongFamilyError.recordingUnidentified(fileId: fileID)
        }
        let hash = Data(SHA256.hash(data: fingerprint))
        if let existing = try TrackRecord.filter(Column("fingerprint_hash") == hash).fetchOne(database)?.id {
            return existing
        }
        var track = TrackRecord(fingerprintHash: hash)
        try track.insert(database)
        guard let id = track.id else { throw OperationEngineError.insertDidNotReturnRowId }
        return id
    }

    private static func linking(_ links: [SongFamilySnapshot.FileLink], _ resolved: [Int64: Int64]) -> [SongFamilySnapshot.FileLink] {
        links.map { link in
            var linked = link
            linked.trackId = resolved[link.fileId] ?? link.trackId
            return linked
        }
    }

    private static func requireFamily(_ familyID: Int64, in database: GRDB.Database) throws {
        guard try SongFamilyRecord.exists(database, key: familyID) else { throw SongFamilyError.familyNotFound(familyId: familyID) }
    }

    private static func requireStandalone(_ trackIds: [Int64], in database: GRDB.Database) throws {
        for track in try TrackRecord.filter(keys: trackIds).fetchAll(database) {
            if let familyID = track.workId, let trackID = track.id {
                throw SongFamilyError.memberAlreadyInFamily(trackId: trackID, familyId: familyID)
            }
        }
    }

    private static func requireMembers(_ trackIds: some Sequence<Int64>, of familyID: Int64, in snapshot: SongFamilySnapshot) throws {
        let members = Set(snapshot.members(of: familyID))
        for trackID in trackIds where !members.contains(trackID) {
            throw SongFamilyError.notAMember(trackId: trackID, familyId: familyID)
        }
    }

    private static func insertFamily(into snapshot: inout SongFamilySnapshot, in database: GRDB.Database) throws -> Int64 {
        var family = SongFamilyRecord()
        try family.insert(database)
        guard let id = family.id else { throw OperationEngineError.insertDidNotReturnRowId }
        snapshot.families.append(.init(familyId: id, exists: false, representativeTrackId: nil))
        snapshot.families.sort { first, second in first.familyId < second.familyId }
        return id
    }

    private static func capture(like snapshot: SongFamilySnapshot, in database: GRDB.Database) throws -> SongFamilySnapshot {
        try capture(familyIds: snapshot.families.map(\.familyId), trackIds: snapshot.assignments.map(\.trackId),
                    fileIds: snapshot.fileLinks.map(\.fileId), in: database)
    }

    /// Current state of the named families (with all of their members), recordings, and file links.
    private static func capture(familyIds: some Sequence<Int64>, trackIds: some Sequence<Int64>, fileIds: some Sequence<Int64>,
                                in database: GRDB.Database) throws -> SongFamilySnapshot
    {
        let familyIDs = Set(familyIds).sorted()
        let families = try SongFamilyRecord.filter(keys: familyIDs).fetchAll(database).reduce(into: [Int64: SongFamilyRecord]()) { byID, family in
            if let id = family.id {
                byID[id] = family
            }
        }
        let members = try Int64.fetchAll(database, TrackRecord.select(Column("id")).filter(familyIDs.contains(Column("work_id"))))
        let coveredTrackIDs = Set(trackIds).union(members).sorted()
        let assignments = try Row.fetchAll(database, TrackRecord.select(Column("id"), Column("work_id")).filter(keys: coveredTrackIDs))
            .reduce(into: [Int64: Int64?]()) { byID, row in byID[row["id"]] = row["work_id"] as Int64? }
        let fileIDs = Set(fileIds).sorted()
        let links = try Row.fetchAll(database, FileRecord.select(Column("id"), Column("track_id")).filter(keys: fileIDs))
            .reduce(into: [Int64: Int64?]()) { byID, row in byID[row["id"]] = row["track_id"] as Int64? }
        return try SongFamilySnapshot(
            families: familyIDs.map { id in
                .init(familyId: id, exists: families[id] != nil, representativeTrackId: families[id]?.representativeTrackId)
            },
            assignments: coveredTrackIDs.map { id in
                guard let familyID = assignments[id] else { throw SongFamilyError.trackNotFound(trackId: id) }
                return .init(trackId: id, familyId: familyID)
            },
            fileLinks: fileIDs.map { id in
                guard let trackID = links[id] else { throw OperationEngineError.fileNotFound(fileId: id) }
                return .init(fileId: id, trackId: trackID)
            }
        )
    }

    private static func write(_ target: SongFamilySnapshot, in database: GRDB.Database) throws {
        for family in target.families where family.exists {
            var record = SongFamilyRecord(id: family.familyId, representativeTrackId: family.representativeTrackId)
            try record.save(database)
        }
        for assignment in target.assignments {
            try database.execute(sql: "UPDATE tracks SET work_id = ? WHERE id = ?", arguments: [assignment.familyId, assignment.trackId])
        }
        for link in target.fileLinks {
            try database.execute(sql: "UPDATE files SET track_id = ? WHERE id = ?", arguments: [link.trackId, link.fileId])
        }
        for family in target.families where !family.exists {
            try SongFamilyRecord.deleteOne(database, key: family.familyId)
        }
    }
}
