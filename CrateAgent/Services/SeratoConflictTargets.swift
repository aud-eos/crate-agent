import CryptoKit
import Foundation
import GRDB

enum SeratoConflictTargets {
    static func mutation(_ mutation: TrackMutation, in database: GRDB.Database) throws -> SeratoConflictTarget {
        var target = SeratoConflictTarget()
        let fileID: Int64?
        switch mutation {
        case let .indexNewFile(payload):
            fileID = try FileRecord.filter(Column("path") == payload.path).fetchOne(database)?.id
            target.paths.append(payload.path)
            target.physicalIdentities.insert(.init(volumeID: payload.volumeUuid, inode: UInt64(bitPattern: payload.inode)))
        case let .renameFile(payload):
            fileID = payload.fileId
            target.paths += [payload.previousPath, payload.newPath].filter { path in !path.isEmpty }
            if let volumeID = payload.newVolumeUuid, let inode = payload.newInode {
                target.physicalIdentities.insert(.init(volumeID: volumeID, inode: UInt64(bitPattern: inode)))
            }
            if let volumeID = payload.previousVolumeUuid, let inode = payload.previousInode {
                target.physicalIdentities.insert(.init(volumeID: volumeID, inode: UInt64(bitPattern: inode)))
            }
        case let .observeFileLocation(payload):
            fileID = payload.fileId
            target.paths.append(payload.path)
            target.physicalIdentities.insert(.init(volumeID: payload.volumeUuid, inode: UInt64(bitPattern: payload.inode)))
        case let .observeFileMetadata(payload):
            fileID = payload.observation.fileId
            include(payload.observation.identity, in: &target)
        case let .recordSubsecondModificationTime(payload):
            fileID = payload.time.fileId
            include(payload.identity, in: &target)
        case let .observeFileIdentity(payload):
            fileID = payload.fileId
            include(payload.previousIdentity, in: &target)
            include(payload.identity, in: &target)
        case let .beginFileImport(payload):
            fileID = payload.fileId
            include(payload.identity, in: &target)
        case let .removeFile(payload): fileID = payload.fileId
        case let .setFileLibraryState(payload): fileID = payload.fileId
        case let .setMetadata(payload): fileID = payload.fileId
        case let .commitMetadataToSerato(payload): fileID = payload.fileId
        case let .addTrackToSerato(payload): fileID = payload.fileId
        case let .writeFileTags(payload): fileID = payload.fileId
        case let .trashFile(payload): fileID = payload.fileId
        case let .removeTrackFromSerato(payload): fileID = payload.fileId
        case let .removeFileFromCrates(payload): fileID = payload.fileId
        case let .restoreFromTrash(payload):
            fileID = try FileRecord.filter(Column("path") == payload.originalPath).fetchOne(database)?.id
            target.paths.append(payload.originalPath)
            include(payload.identity, in: &target)
            if let trashItem = try SeratoRemovalCaptureStore.trashDestination(eventID: payload.removalEventID, in: database)?.identity {
                include(trashItem, in: &target)
            }
        case let .restoreSeratoRecords(payload):
            fileID = try FileRecord.filter(Column("path") == payload.trackPath).fetchOne(database)?.id
            target.paths.append(payload.trackPath)
        case let .applyMusicBrainzMatch(payload):
            fileID = payload.fileID
            try includeSharedTrack(payload.fingerprintHash, in: &target, database: database)
        case let .revertMusicBrainzMatch(payload):
            fileID = payload.applied.fileID
            try includeSharedTrack(payload.applied.fingerprintHash, in: &target, database: database)
        case let .songFamily(operation):
            fileID = try includeRecordingLink(operation, in: &target, database: database)
        case let .discardQueuedSeratoChange(payload):
            fileID = payload.fileId
            for discarded in payload.writes {
                include(discarded.queued.originalIdentity, in: &target)
                target.paths += discarded.queued.originalReferencePaths + discarded.queued.write.referencePaths
            }
        case let .recordMusicBrainzWork(payload):
            // Writes only `tracks.musicbrainz_work_id`; no file, path or
            // Serato field mirrors it, so it targets the recording alone.
            fileID = nil
            target.sharedTrackIDs.insert(payload.trackId)
        case let .duplicateLabelReview(.keepBoth(payload)), let .duplicateLabelReview(.reopen(payload)):
            fileID = nil
            target.fileIDs.formUnion(payload.fileIds)
            for file in try FileRecord.fetchAll(database, keys: payload.fileIds) {
                target.include(file)
            }
        }
        if let fileID {
            target.fileIDs.insert(fileID)
            if let file = try FileRecord.fetchOne(database, key: fileID) {
                target.include(file)
            }
        }
        includeLiveIdentities(in: &target)
        return target
    }

    static func write(_ write: GuardedSeratoWrite, in database: GRDB.Database) throws -> SeratoConflictTarget {
        var target = SeratoConflictTarget(fileIDs: [write.token.fileId])
        include(write.originalIdentity, in: &target)
        if let file = try FileRecord.fetchOne(database, key: write.token.fileId) {
            target.include(file)
        }
        if let keeper = write.requiredKeeper {
            target.fileIDs.insert(keeper.token.fileId)
            include(keeper.identity, in: &target)
            if let file = try FileRecord.fetchOne(database, key: keeper.token.fileId) {
                target.include(file)
            }
        }
        target.paths += write.originalReferencePaths + write.write.referencePaths
        includeLiveIdentities(in: &target)
        return target
    }

    static func identity(_ identity: FileMetadata) -> SeratoConflictTarget {
        var target = SeratoConflictTarget()
        include(identity, in: &target)
        return target
    }

    private static func include(_ identity: FileMetadata, in target: inout SeratoConflictTarget) {
        target.paths.append(identity.path)
        if identity.volumeUuid != LegacyFileIdentity.unknownVolume {
            target.physicalIdentities.insert(.init(volumeID: identity.volumeUuid, inode: UInt64(bitPattern: identity.inode)))
        }
    }

    /// Linking, unlinking or relinking sets a file's `track_id`, so it targets
    /// that file and the recording it joins or leaves. Every other family
    /// change writes only `works` and `tracks.work_id`, which no Serato file
    /// or path mirrors.
    private static func includeRecordingLink(_ operation: SongFamilyOperation, in target: inout SeratoConflictTarget,
                                             database: GRDB.Database) throws -> Int64?
    {
        switch operation {
        case let .linkRecording(fileID):
            if let file = try FileRecord.fetchOne(database, key: fileID), let fingerprint = file.chromaprintFingerprint {
                try includeSharedTrack(Data(SHA256.hash(data: fingerprint)), in: &target, database: database)
            }
            return fileID
        case let .unlinkRecording(link), let .relinkRecording(link):
            target.sharedTrackIDs.insert(link.trackId)
            return link.fileId
        case .create, .attach, .detach, .merge, .split, .setRepresentative, .restore:
            return nil
        }
    }

    private static func includeSharedTrack(_ fingerprint: Data, in target: inout SeratoConflictTarget, database: GRDB.Database) throws {
        if let trackID = try TrackRecord.filter(Column("fingerprint_hash") == fingerprint).fetchOne(database)?.id {
            target.sharedTrackIDs.insert(trackID)
        }
    }

    private static func includeLiveIdentities(in target: inout SeratoConflictTarget) {
        for path in target.paths {
            // Missing destinations and historical references are legitimate; the
            // existing physical-write guard remains authoritative for actual I/O.
            if let identity = FileMetadataCollector.collect(at: path) {
                target.physicalIdentities.insert(.init(volumeID: identity.volumeUuid, inode: UInt64(bitPattern: identity.inode)))
            }
        }
    }
}

extension SeratoPendingWrite {
    var referencePaths: [String] {
        switch self {
        case let .rename(payload): [payload.oldAbsolutePath, payload.newAbsolutePath]
        case let .metadataUpdate(payload): [payload.absolutePath]
        case let .addTrack(payload): [payload.absolutePath]
        case let .fileTagWrite(payload): [payload.absolutePath]
        case let .removeFromDatabase(payload), let .removeFromCrates(payload): [payload.absolutePath]
        case let .trashFile(payload): [payload.absolutePath]
        case let .restoreRecords(payload): [payload.absolutePath]
        }
    }
}
