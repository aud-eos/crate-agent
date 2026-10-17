import CryptoKit
import Foundation
import GRDB

/// A recording to place in a song family. `.file` names a Library row and
/// resolves to the recording it is linked to; `SongFamilyService` links an
/// unlinked file first with `.linkRecording`. Either way the recording must
/// have a file in the library.
public enum SongFamilyMember: Codable, Sendable, Hashable {
    case track(Int64)
    case file(Int64)
}

/// User-directed song-family changes, applied through
/// `OperationEngine.apply(.songFamily(_:))`. Membership operations journal the
/// affected families and recording assignments before and after, so undo
/// restores membership and the saved representative exactly. File links are
/// separate per-file events; see docs/song-families.md for the link rule.
public enum SongFamilyOperation: Codable, Sendable, Equatable {
    /// Links an unlinked file to the recording its fingerprint identifies. A
    /// no-op for a file that is already linked.
    case linkRecording(fileId: Int64)
    /// Undo of a link: removes it only while grouping still owns it.
    case unlinkRecording(SongFamilyRecordingLink)
    /// Redo of a link.
    case relinkRecording(SongFamilyRecordingLink)
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
        case .linkRecording, .relinkRecording: .songFamilyRecordingLinked
        case .unlinkRecording: .songFamilyRecordingUnlinked
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

/// A file link a song-family event created or removed; the payload of both link events.
public struct SongFamilyRecordingLink: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let trackId: Int64
}

/// The journaled state of every family and recording an operation touched. A
/// family's members are exactly the `assignments` naming it.
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

    public var families: [Family]
    public var assignments: [Assignment]

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

    /// Clears a family left with fewer than two live members, including any
    /// members without files, leaving the rest standalone.
    mutating func dissolveIfTooSmall(_ familyId: Int64, live: Set<Int64>) {
        let remaining = members(of: familyId)
        guard remaining.filter(live.contains).count < 2 else { return }
        assign(remaining, to: nil)
        setFamily(familyId, exists: false, representativeTrackId: nil)
    }

    var coverage: [String] {
        families.map { family in "family:\(family.familyId)" } + assignments.map { assignment in "track:\(assignment.trackId)" }
    }
}

/// Undo payload: return to `target`, but only if the journaled state is still
/// `expected`. A later change to any covered family or recording makes
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
    case fileRetired(fileId: Int64)
    case recordingHasNoFiles(trackId: Int64)
    /// The file's fingerprint identifies a recording that another file or an
    /// identity source already claims; grouping never shares or rewrites it.
    case fingerprintCollision(fileId: Int64, trackId: Int64, otherFileId: Int64?)
    case linkChanged(fileId: Int64)
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
        case let .fileRetired(fileId):
            "File \(fileId) is no longer in the library, so it can't be grouped."
        case let .recordingHasNoFiles(trackId):
            "Recording \(trackId) has no file in the library, so it can't be grouped."
        case let .fingerprintCollision(fileId, trackId, otherFileId?):
            "File \(fileId) has the same fingerprint as file \(otherFileId), which is linked to recording \(trackId). Grouping doesn't merge recordings. Match file \(fileId) with Auto-Tag first."
        case let .fingerprintCollision(fileId, trackId, nil):
            "File \(fileId)'s fingerprint matches recording \(trackId), which already has MusicBrainz identifiers. Match file \(fileId) with Auto-Tag first."
        case let .linkChanged(fileId):
            "File \(fileId) was linked to a different recording since this was recorded."
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
        switch operation {
        case let .linkRecording(fileID):
            try logLink(link(fileID, in: database), operation: operation, batchId: batchId, timestamp: timestamp, in: database)
        case let .relinkRecording(recorded):
            try logLink(relink(recorded, in: database), operation: operation, batchId: batchId, timestamp: timestamp, in: database)
        case let .unlinkRecording(recorded):
            try logLink(unlink(recorded, in: database), operation: operation, batchId: batchId, timestamp: timestamp, in: database)
        default:
            try applyMembership(operation, batchId: batchId, timestamp: timestamp, in: database)
        }
    }

    private static func applyMembership(_ operation: SongFamilyOperation, batchId: String, timestamp: Int64, in database: GRDB.Database) throws -> Int64? {
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
            let trackIDs = try resolve(members, in: database)
            guard trackIDs.count >= 2 else { throw SongFamilyError.tooFewMembers }
            try requireUnassigned(trackIDs, joining: nil, in: database)
            let representativeID = try representative.map { member in try resolve([member], in: database)[0] }
            if let representativeID, !trackIDs.contains(representativeID) {
                throw SongFamilyError.representativeNotMember
            }
            var before = try capture(familyIds: [], trackIds: trackIDs, in: database)
            let familyID = try insertFamily(into: &before, in: database)
            var after = before
            after.setFamily(familyID, exists: true, representativeTrackId: representativeID)
            after.assign(trackIDs, to: familyID)
            return SongFamilyChange(operation: operation, familyId: familyID, before: before, after: after)

        case let .attach(familyID, members):
            try requireFamily(familyID, in: database)
            let trackIDs = try resolve(members, in: database)
            guard !trackIDs.isEmpty else { throw SongFamilyError.tooFewMembers }
            try requireUnassigned(trackIDs, joining: familyID, in: database)
            let before = try capture(familyIds: [familyID], trackIds: trackIDs, in: database)
            var after = before
            after.assign(trackIDs, to: familyID)
            return SongFamilyChange(operation: operation, familyId: familyID, before: before, after: after)

        case let .detach(familyID, trackIds):
            try requireFamily(familyID, in: database)
            let before = try capture(familyIds: [familyID], trackIds: trackIds, in: database)
            try requireMembers(trackIds, of: familyID, in: before)
            var after = before
            after.assign(trackIds, to: nil)
            if let representative = before.family(familyID)?.representativeTrackId, trackIds.contains(representative) {
                after.setFamily(familyID, exists: true, representativeTrackId: nil)
            }
            try after.dissolveIfTooSmall(familyID, live: liveTracks(in: before, database: database))
            return SongFamilyChange(operation: operation, familyId: after.family(familyID)?.exists == true ? familyID : nil, before: before, after: after)

        case let .merge(familyID, mergedFamilyIds):
            let merged = Set(mergedFamilyIds)
            guard !merged.isEmpty, !merged.contains(familyID) else { throw SongFamilyError.invalidMerge }
            for id in [familyID] + merged.sorted() {
                try requireFamily(id, in: database)
            }
            let before = try capture(familyIds: merged.union([familyID]), trackIds: [], in: database)
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
            var before = try capture(familyIds: [familyID], trackIds: moving, in: database)
            try requireMembers(moving, of: familyID, in: before)
            let live = try liveTracks(in: before, database: database)
            guard before.members(of: familyID).contains(where: { member in live.contains(member) && !moving.contains(member) }) else {
                throw SongFamilyError.splitTakesEveryMember(familyId: familyID)
            }
            let splitID = try insertFamily(into: &before, in: database)
            var after = before
            let representative = before.family(familyID)?.representativeTrackId
            let representativeMoves = representative.map(moving.contains) ?? false
            after.assign(moving, to: splitID)
            after.setFamily(splitID, exists: true, representativeTrackId: representativeMoves ? representative : nil)
            if representativeMoves {
                after.setFamily(familyID, exists: true, representativeTrackId: nil)
            }
            after.dissolveIfTooSmall(familyID, live: live)
            return SongFamilyChange(operation: operation, familyId: splitID, before: before, after: after)

        case let .setRepresentative(familyID, trackID):
            try requireFamily(familyID, in: database)
            let before = try capture(familyIds: [familyID], trackIds: [], in: database)
            if let trackID {
                try requireMembers([trackID], of: familyID, in: before)
            }
            var after = before
            after.setFamily(familyID, exists: true, representativeTrackId: trackID)
            return SongFamilyChange(operation: operation, familyId: familyID, before: before, after: after)

        case .restore, .linkRecording, .unlinkRecording, .relinkRecording:
            preconditionFailure("applied directly")
        }
    }

    /// Distinct recordings in request order; files that share a recording count once.
    private static func resolve(_ members: [SongFamilyMember], in database: GRDB.Database) throws -> [Int64] {
        var trackIDs: [Int64] = []
        for member in members {
            let trackID: Int64
            switch member {
            case let .track(id):
                guard try TrackRecord.exists(database, key: id) else { throw SongFamilyError.trackNotFound(trackId: id) }
                guard try TrackRecord.filter(key: id).filter(sql: liveTrackSQL).fetchCount(database) > 0 else {
                    throw SongFamilyError.recordingHasNoFiles(trackId: id)
                }
                trackID = id
            case let .file(fileID):
                let file = try activeFile(fileID, in: database)
                guard let linked = file.trackId else { throw SongFamilyError.recordingUnidentified(fileId: fileID) }
                trackID = linked
            }
            if !trackIDs.contains(trackID) {
                trackIDs.append(trackID)
            }
        }
        return trackIDs
    }

    private static func activeFile(_ fileID: Int64, in database: GRDB.Database) throws -> FileRecord {
        guard let file = try FileRecord.fetchOne(database, key: fileID) else { throw OperationEngineError.fileNotFound(fileId: fileID) }
        guard file.libraryMembership != .retired else { throw SongFamilyError.fileRetired(fileId: fileID) }
        return file
    }

    // MARK: - File links

    private static func logLink(_ link: SongFamilyRecordingLink?, operation: SongFamilyOperation, batchId: String, timestamp: Int64,
                                in database: GRDB.Database) throws -> Int64?
    {
        guard let link else { return nil }
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: link.fileId, trackId: link.trackId,
                                               eventType: operation.eventType, forwardPayload: link, inversePayload: link, in: database)
    }

    private static func link(_ fileID: Int64, in database: GRDB.Database) throws -> SongFamilyRecordingLink? {
        let file = try activeFile(fileID, in: database)
        guard file.trackId == nil else { return nil }
        guard file.fingerprintStatus == .done, let fingerprint = file.chromaprintFingerprint,
              (file.fingerprintedSize ?? file.fileSize) == file.fileSize, (file.fingerprintedMtime ?? file.mtime) == file.mtime
        else {
            throw SongFamilyError.recordingUnidentified(fileId: fileID)
        }
        let hash = Data(SHA256.hash(data: fingerprint))
        let trackID: Int64
        if let existing = try TrackRecord.filter(Column("fingerprint_hash") == hash).fetchOne(database), let existingID = existing.id {
            try requireUnclaimed(existing, by: fileID, in: database)
            trackID = existingID
        } else {
            var track = TrackRecord(fingerprintHash: hash)
            try track.insert(database)
            guard let id = track.id else { throw OperationEngineError.insertDidNotReturnRowId }
            trackID = id
        }
        return try setLink(SongFamilyRecordingLink(fileId: fileID, trackId: trackID), in: database)
    }

    private static func relink(_ recorded: SongFamilyRecordingLink, in database: GRDB.Database) throws -> SongFamilyRecordingLink? {
        let file = try activeFile(recorded.fileId, in: database)
        guard file.trackId != recorded.trackId else { return nil }
        guard file.trackId == nil, let track = try TrackRecord.fetchOne(database, key: recorded.trackId) else {
            throw SongFamilyError.linkChanged(fileId: recorded.fileId)
        }
        try requireUnclaimed(track, by: recorded.fileId, in: database)
        return try setLink(recorded, in: database)
    }

    /// A link a later identity change claimed stays; that change owns it now.
    private static func unlink(_ recorded: SongFamilyRecordingLink, in database: GRDB.Database) throws -> SongFamilyRecordingLink? {
        let file = try activeFile(recorded.fileId, in: database)
        guard file.trackId == recorded.trackId, let track = try TrackRecord.fetchOne(database, key: recorded.trackId),
              try isUnclaimed(track, by: recorded.fileId, in: database)
        else {
            return nil
        }
        try database.execute(sql: "UPDATE files SET track_id = NULL WHERE id = ?", arguments: [recorded.fileId])
        return recorded
    }

    private static func setLink(_ link: SongFamilyRecordingLink, in database: GRDB.Database) throws -> SongFamilyRecordingLink {
        try database.execute(sql: "UPDATE files SET track_id = ? WHERE id = ?", arguments: [link.trackId, link.fileId])
        return link
    }

    private static func isUnclaimed(_ track: TrackRecord, by fileID: Int64, in database: GRDB.Database) throws -> Bool {
        try !track.hasRecordingIdentity && !FileRecord.hasOtherFilesReferencingTrack(track.id, excluding: fileID, in: database)
    }

    private static func requireUnclaimed(_ track: TrackRecord, by fileID: Int64, in database: GRDB.Database) throws {
        guard let trackID = track.id else { throw OperationEngineError.insertDidNotReturnRowId }
        if let otherFileID = try FileRecord.otherFileReferencingTrack(trackID, excluding: fileID, in: database) {
            throw SongFamilyError.fingerprintCollision(fileId: fileID, trackId: trackID, otherFileId: otherFileID)
        }
        if track.hasRecordingIdentity {
            throw SongFamilyError.fingerprintCollision(fileId: fileID, trackId: trackID, otherFileId: nil)
        }
    }

    // MARK: - Membership

    /// Recordings with at least one file still in the library. Only these
    /// count as versions; a member that lost its last file keeps its
    /// assignment so restoring the file restores the member.
    static let liveTrackSQL = "EXISTS (SELECT 1 FROM files WHERE files.track_id = tracks.id AND \(FileProcessingEligibility.activeSQL))"

    private static func liveTracks(in snapshot: SongFamilySnapshot, database: GRDB.Database) throws -> Set<Int64> {
        let trackIDs = snapshot.assignments.map(\.trackId)
        return try Set(Int64.fetchAll(database, TrackRecord.select(Column("id")).filter(keys: trackIDs).filter(sql: liveTrackSQL)))
    }

    private static func requireFamily(_ familyID: Int64, in database: GRDB.Database) throws {
        guard try SongFamilyRecord.exists(database, key: familyID) else { throw SongFamilyError.familyNotFound(familyId: familyID) }
    }

    /// A recording already in `familyID` is left where it is; one in another family is refused.
    private static func requireUnassigned(_ trackIds: [Int64], joining familyID: Int64?, in database: GRDB.Database) throws {
        for track in try TrackRecord.filter(keys: trackIds).fetchAll(database) {
            if let current = track.workId, current != familyID, let trackID = track.id {
                throw SongFamilyError.memberAlreadyInFamily(trackId: trackID, familyId: current)
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
        try capture(familyIds: snapshot.families.map(\.familyId), trackIds: snapshot.assignments.map(\.trackId), in: database)
    }

    /// Current state of the named families (with all of their members) and recordings.
    private static func capture(familyIds: some Sequence<Int64>, trackIds: some Sequence<Int64>,
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
        return try SongFamilySnapshot(
            families: familyIDs.map { id in
                .init(familyId: id, exists: families[id] != nil, representativeTrackId: families[id]?.representativeTrackId)
            },
            assignments: coveredTrackIDs.map { id in
                guard let familyID = assignments[id] else { throw SongFamilyError.trackNotFound(trackId: id) }
                return .init(trackId: id, familyId: familyID)
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
        for family in target.families where !family.exists {
            try SongFamilyRecord.deleteOne(database, key: family.familyId)
        }
    }
}
