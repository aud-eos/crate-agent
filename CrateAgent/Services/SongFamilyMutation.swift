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

/// A file link a song-family event created or removed; the payload of both
/// link events. `membershipRevision` is the file's revision when the event was
/// written, so replaying it is refused once the file was retired or replaced.
public struct SongFamilyRecordingLink: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let trackId: Int64
    public let membershipRevision: Int64
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

    /// Clears a family left with fewer than two live versions, including any
    /// members without files, leaving the rest standalone. `liveVersions`
    /// maps each live member to its version key.
    mutating func dissolveIfTooSmall(_ familyId: Int64, liveVersions: [Int64: String]) {
        guard Set(members(of: familyId).compactMap { member in liveVersions[member] }).count < 2 else { return }
        dissolve(familyId)
    }

    mutating func dissolve(_ familyId: Int64) {
        assign(members(of: familyId), to: nil)
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

/// Refusals name files and recordings the way the Library shows them: by
/// title, else by file name.
public enum SongFamilyError: LocalizedError, Equatable {
    case familyNotFound
    case familyNoLongerShown(family: String)
    case trackNotFound
    case recordingUnidentified(file: String)
    case fileRetired(file: String)
    case recordingHasNoFiles(recording: String)
    /// The file's fingerprint identifies a recording that another file or an
    /// identity source already claims; grouping never shares or rewrites it.
    case fingerprintCollision(file: String, otherFile: String?)
    case linkChanged(file: String)
    /// A file the command was authorized for changed after it was shown.
    case changedSinceShown(file: String)
    /// The recording belongs to a family that still has two or more live
    /// versions, named here.
    case memberAlreadyInFamily(recording: String, familyVersions: [String])
    case notAMember(recording: String)
    case tooFewMembers
    case representativeNotMember
    case invalidMerge
    case splitTakesEveryMember
    case changedSinceRecorded
    case malformedRestore

    public var errorDescription: String? {
        switch self {
        case .familyNotFound:
            "This song family no longer exists."
        case let .familyNoLongerShown(family):
            "The song family of “\(family)” has fewer than two recordings left in the library, so it no longer shows. Group the recordings again instead."
        case .trackNotFound:
            "A chosen recording is no longer in the library."
        case let .recordingUnidentified(file):
            "“\(file)” has no current fingerprint yet, so its recording can't be grouped. Wait for fingerprinting to finish."
        case let .fileRetired(file):
            "“\(file)” is no longer in the library, so it can't be grouped."
        case let .recordingHasNoFiles(recording):
            "“\(recording)” has no file in the library, so it can't be grouped."
        case let .fingerprintCollision(file, otherFile?):
            "“\(file)” and “\(otherFile)” share an audio fingerprint, so crate-agent treats them as one recording. Group them as different recordings to keep them as separate versions."
        case let .fingerprintCollision(file, nil):
            "“\(file)” has the same audio fingerprint as a recording crate-agent already identified, so it treats them as one recording. Group them as different recordings to keep them as separate versions."
        case let .linkChanged(file):
            "“\(file)” was linked to a different recording since this was recorded."
        case let .changedSinceShown(file):
            "“\(file)” changed after it was shown. Review it and try again."
        case let .memberAlreadyInFamily(recording, familyVersions):
            "“\(recording)” is already in a song family with \(familyVersions.map { version in "“\(version)”" }.formatted(.list(type: .and))). Merge the families instead."
        case let .notAMember(recording):
            "“\(recording)” is not in this song family."
        case .tooFewMembers:
            "A song family needs at least two different recordings."
        case .representativeNotMember:
            "The main version must be one of the family's recordings."
        case .invalidMerge:
            "Choose at least one other existing song family to merge."
        case .splitTakesEveryMember:
            "Splitting every recording out of this song family would leave it empty."
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
            change = try plan(operation, batchId: batchId, in: database)
        }
        guard change.before != change.after else { return nil }
        try write(change.after, in: database)
        let inverse = RestoreSongFamiliesPayload(target: change.before, expected: change.after)
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: nil, eventType: operation.eventType,
                                               forwardPayload: change, inversePayload: inverse, in: database)
    }

    private static func plan(_ operation: SongFamilyOperation, batchId: String, in database: GRDB.Database) throws -> SongFamilyChange {
        switch operation {
        case let .create(members, representative):
            let trackIDs = try resolve(members, in: database)
            guard try versionKeys(of: trackIDs, in: database).count >= 2 else { throw SongFamilyError.tooFewMembers }
            let dissolving = try familiesToDissolve(for: trackIDs, joining: nil, batchId: batchId, in: database)
            let representativeID = try representative.map { member in try resolve([member], in: database)[0] }
            if let representativeID, !trackIDs.contains(representativeID) {
                throw SongFamilyError.representativeNotMember
            }
            var before = try capture(familyIds: dissolving, trackIds: trackIDs, in: database)
            let familyID = try insertFamily(into: &before, in: database)
            var after = before
            dissolving.forEach { familyID in after.dissolve(familyID) }
            after.setFamily(familyID, exists: true, representativeTrackId: representativeID)
            after.assign(trackIDs, to: familyID)
            return SongFamilyChange(operation: operation, familyId: familyID, before: before, after: after)

        case let .attach(familyID, members):
            try requireLiveFamily(familyID, in: database)
            let trackIDs = try resolve(members, in: database)
            guard !trackIDs.isEmpty else { throw SongFamilyError.tooFewMembers }
            let dissolving = try familiesToDissolve(for: trackIDs, joining: familyID, batchId: batchId, in: database)
            let before = try capture(familyIds: dissolving.union([familyID]), trackIds: trackIDs, in: database)
            var after = before
            dissolving.forEach { familyID in after.dissolve(familyID) }
            after.assign(trackIDs, to: familyID)
            return SongFamilyChange(operation: operation, familyId: familyID, before: before, after: after)

        case let .detach(familyID, trackIds):
            try requireFamily(familyID, in: database)
            let before = try capture(familyIds: [familyID], trackIds: trackIds, in: database)
            try requireMembers(trackIds, of: familyID, in: before, database: database)
            var after = before
            after.assign(trackIds, to: nil)
            if let representative = before.family(familyID)?.representativeTrackId, trackIds.contains(representative) {
                after.setFamily(familyID, exists: true, representativeTrackId: nil)
            }
            try after.dissolveIfTooSmall(familyID, liveVersions: liveVersions(in: before, database: database))
            return SongFamilyChange(operation: operation, familyId: after.family(familyID)?.exists == true ? familyID : nil, before: before, after: after)

        case let .merge(familyID, mergedFamilyIds):
            let merged = Set(mergedFamilyIds)
            guard !merged.isEmpty, !merged.contains(familyID) else { throw SongFamilyError.invalidMerge }
            for id in [familyID] + merged.sorted() {
                try requireLiveFamily(id, in: database)
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
            guard try versionKeys(of: moving, in: database).count >= 2 else { throw SongFamilyError.tooFewMembers }
            try requireLiveFamily(familyID, in: database)
            var before = try capture(familyIds: [familyID], trackIds: moving, in: database)
            try requireMembers(moving, of: familyID, in: before, database: database)
            let live = try liveVersions(in: before, database: database)
            guard before.members(of: familyID).contains(where: { member in live[member] != nil && !moving.contains(member) }) else {
                throw SongFamilyError.splitTakesEveryMember
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
            after.dissolveIfTooSmall(familyID, liveVersions: live)
            return SongFamilyChange(operation: operation, familyId: splitID, before: before, after: after)

        case let .setRepresentative(familyID, trackID):
            try requireLiveFamily(familyID, in: database)
            let before = try capture(familyIds: [familyID], trackIds: [], in: database)
            if let trackID {
                try requireMembers([trackID], of: familyID, in: before, database: database)
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
                guard try TrackRecord.exists(database, key: id) else { throw SongFamilyError.trackNotFound }
                guard try TrackRecord.filter(key: id).filter(sql: liveTrackSQL).fetchCount(database) > 0 else {
                    throw try SongFamilyError.recordingHasNoFiles(recording: name(ofTrack: id, in: database))
                }
                trackID = id
            case let .file(fileID):
                let file = try activeFile(fileID, in: database)
                guard let linked = file.trackId else { throw SongFamilyError.recordingUnidentified(file: file.displayName) }
                trackID = linked
            }
            if !trackIDs.contains(trackID) {
                trackIDs.append(trackID)
            }
        }
        return trackIDs
    }

    private static func activeFile(_ fileID: Int64, in database: GRDB.Database) throws -> FileRecord {
        let file = try fileRecord(fileID, in: database)
        guard file.libraryMembership != .retired else { throw SongFamilyError.fileRetired(file: file.displayName) }
        return file
    }

    private static func fileRecord(_ fileID: Int64, in database: GRDB.Database) throws -> FileRecord {
        guard let file = try FileRecord.fetchOne(database, key: fileID) else { throw OperationEngineError.fileNotFound(fileId: fileID) }
        return file
    }

    /// A recording's name: its first library file's title or file name,
    /// preferring a file still in the library, else its own title.
    private static func name(ofTrack trackID: Int64, in database: GRDB.Database) throws -> String {
        if let file = try FileRecord.filter(Column("track_id") == trackID)
            .order(SQL(sql: "CASE WHEN \(FileProcessingEligibility.activeSQL) THEN 0 ELSE 1 END"), Column("id")).fetchOne(database)
        {
            return file.displayName
        }
        return try TrackRecord.fetchOne(database, key: trackID)?.title ?? "Untitled recording"
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
        guard let hash = try RecordingIdentity.key(of: file, in: database) else { throw SongFamilyError.recordingUnidentified(file: file.displayName) }
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
        return try setLink(SongFamilyRecordingLink(fileId: fileID, trackId: trackID, membershipRevision: file.membershipRevision), in: database)
    }

    /// Redo of a link, under the same rule as `link`: the file's current
    /// fingerprint must still identify the recording.
    private static func relink(_ recorded: SongFamilyRecordingLink, in database: GRDB.Database) throws -> SongFamilyRecordingLink? {
        guard try fileRecord(recorded.fileId, in: database).trackId != recorded.trackId else { return nil }
        let file = try activeFile(recorded.fileId, in: database)
        guard file.trackId == nil, let track = try TrackRecord.fetchOne(database, key: recorded.trackId),
              try RecordingIdentity.key(of: file, in: database) == track.fingerprintHash
        else {
            throw SongFamilyError.linkChanged(file: file.displayName)
        }
        try requireUnclaimed(track, by: recorded.fileId, in: database)
        return try setLink(SongFamilyRecordingLink(fileId: recorded.fileId, trackId: recorded.trackId, membershipRevision: file.membershipRevision),
                           in: database)
    }

    /// A link a later identity change claimed stays; that change owns it now.
    /// A retired file keeps its link too, as retirement keeps every file's
    /// recording link, so undoing a group never waits on a file's return.
    private static func unlink(_ recorded: SongFamilyRecordingLink, in database: GRDB.Database) throws -> SongFamilyRecordingLink? {
        let file = try fileRecord(recorded.fileId, in: database)
        guard file.libraryMembership != .retired, file.trackId == recorded.trackId, let track = try TrackRecord.fetchOne(database, key: recorded.trackId),
              try isUnclaimed(track, by: recorded.fileId, in: database)
        else {
            return nil
        }
        try database.execute(sql: "UPDATE files SET track_id = NULL WHERE id = ?", arguments: [recorded.fileId])
        return SongFamilyRecordingLink(fileId: recorded.fileId, trackId: recorded.trackId, membershipRevision: file.membershipRevision)
    }

    private static func setLink(_ link: SongFamilyRecordingLink, in database: GRDB.Database) throws -> SongFamilyRecordingLink {
        try database.execute(sql: "UPDATE files SET track_id = ? WHERE id = ?", arguments: [link.trackId, link.fileId])
        return link
    }

    private static func isUnclaimed(_ track: TrackRecord, by fileID: Int64, in database: GRDB.Database) throws -> Bool {
        try !track.hasRecordingIdentity && FileRecord.otherActiveFileReferencingTrack(track.id, excluding: fileID, in: database) == nil
    }

    private static func requireUnclaimed(_ track: TrackRecord, by fileID: Int64, in database: GRDB.Database) throws {
        guard let trackID = track.id else { throw OperationEngineError.insertDidNotReturnRowId }
        let other = try FileRecord.otherActiveFileReferencingTrack(trackID, excluding: fileID, in: database)
        guard other != nil || track.hasRecordingIdentity else { return }
        throw try SongFamilyError.fingerprintCollision(file: fileRecord(fileID, in: database).displayName, otherFile: other.map(\.displayName))
    }

    // MARK: - Membership

    /// Recordings with at least one file still in the library. Only these
    /// count as versions; a member that lost its last file keeps its
    /// assignment so restoring the file restores the member.
    static let liveTrackSQL = "EXISTS (SELECT 1 FROM files WHERE files.track_id = tracks.id AND \(FileProcessingEligibility.activeSQL))"

    /// What makes recordings one version: rows that share a MusicBrainz
    /// recording are one version, every other row is its own.
    static let versionKeySQL = "COALESCE(tracks.musicbrainz_recording_id, 'track:' || tracks.id)"

    /// The families the user can see, with their live version counts as
    /// `family_id, versions`: every family with two or more live versions.
    static let liveFamiliesSQL = """
    SELECT work_id AS family_id, COUNT(DISTINCT \(versionKeySQL)) AS versions FROM tracks
    WHERE work_id IS NOT NULL AND \(liveTrackSQL) GROUP BY work_id HAVING COUNT(DISTINCT \(versionKeySQL)) >= 2
    """

    private static func versionsByTrack(_ request: QueryInterfaceRequest<TrackRecord>, in database: GRDB.Database) throws -> [Int64: String] {
        try Row.fetchAll(database, request.select(Column("id"), SQL(sql: versionKeySQL).forKey("version")))
            .reduce(into: [Int64: String]()) { byTrack, row in byTrack[row["id"]] = row["version"] }
    }

    private static func versionKeys(of trackIds: some Sequence<Int64>, in database: GRDB.Database) throws -> Set<String> {
        try Set(versionsByTrack(TrackRecord.filter(keys: Array(trackIds)), in: database).values)
    }

    private static func liveVersions(in snapshot: SongFamilySnapshot, database: GRDB.Database) throws -> [Int64: String] {
        try versionsByTrack(TrackRecord.filter(keys: snapshot.assignments.map(\.trackId)).filter(sql: liveTrackSQL), in: database)
    }

    private static func requireFamily(_ familyID: Int64, in database: GRDB.Database) throws {
        guard try SongFamilyRecord.exists(database, key: familyID) else { throw SongFamilyError.familyNotFound }
    }

    /// A family with fewer than two live versions no longer shows, so
    /// changing it would revive it behind the user's back.
    private static func requireLiveFamily(_ familyID: Int64, in database: GRDB.Database) throws {
        guard let family = try SongFamilyRecord.fetchOne(database, key: familyID) else { throw SongFamilyError.familyNotFound }
        let members = TrackRecord.filter(Column("work_id") == familyID)
        guard try Set(versionsByTrack(members.filter(sql: liveTrackSQL), in: database).values).count >= 2 else {
            let named = try family.representativeTrackId ?? Int64.fetchOne(database, members.select(Column("id")).order(Column("id")))
            throw try SongFamilyError.familyNoLongerShown(family: named.map { trackID in try name(ofTrack: trackID, in: database) } ?? "Untitled recording")
        }
    }

    /// The other families the recordings belong to, which the change
    /// dissolves. A recording already in `familyID` is left where it is. A
    /// family with fewer than two live versions is already dissolved as far as
    /// the user can tell, so it may be taken over (the journal keeps it for
    /// undo); a recording in a live family is refused. Liveness is measured
    /// before this batch's own links, which would otherwise revive the very
    /// family the user is regrouping out of.
    private static func familiesToDissolve(for trackIds: [Int64], joining familyID: Int64?, batchId: String,
                                           in database: GRDB.Database) throws -> Set<Int64>
    {
        var dissolving = Set<Int64>()
        // Read only once a recording is in another family: a batch grouping
        // thousands of new recordings never needs it.
        var batchLinks: [Int64]?
        for track in try TrackRecord.filter(keys: trackIds).fetchAll(database) {
            guard let current = track.workId, current != familyID, !dissolving.contains(current), let trackID = track.id else { continue }
            let linkedByBatch = try batchLinks ?? Int64.fetchAll(database, EventRecord.select(Column("file_id"))
                .filter(Column("batch_id") == batchId && Column("event_type") == EventType.songFamilyRecordingLinked.rawValue))
            batchLinks = linkedByBatch
            let liveBeforeBatch: SQL = """
            EXISTS (SELECT 1 FROM files WHERE files.track_id = tracks.id AND \(sql: FileProcessingEligibility.activeSQL) \
            AND files.id NOT IN \(linkedByBatch))
            """
            let liveVersions = try versionsByTrack(TrackRecord.filter(Column("work_id") == current).filter(liveBeforeBatch), in: database)
            guard Set(liveVersions.values).count >= 2 else {
                dissolving.insert(current)
                continue
            }
            let ownVersion = try versionKeys(of: [trackID], in: database).first
            let otherVersions = Dictionary(grouping: liveVersions.keys, by: { member in liveVersions[member] })
                .filter { version, _ in version != ownVersion }.values.compactMap { members in members.min() }.sorted()
            throw try SongFamilyError.memberAlreadyInFamily(recording: name(ofTrack: trackID, in: database),
                                                            familyVersions: otherVersions.map { version in try name(ofTrack: version, in: database) })
        }
        return dissolving
    }

    private static func requireMembers(_ trackIds: some Sequence<Int64>, of familyID: Int64, in snapshot: SongFamilySnapshot, database: GRDB.Database) throws {
        let members = Set(snapshot.members(of: familyID))
        for trackID in trackIds where !members.contains(trackID) {
            throw try SongFamilyError.notAMember(recording: name(ofTrack: trackID, in: database))
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
                guard let familyID = assignments[id] else { throw SongFamilyError.trackNotFound }
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
