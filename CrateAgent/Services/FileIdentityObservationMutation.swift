import Foundation
import GRDB

struct FileObservationExpectation: Sendable {
    let fileId: Int64
    let revision: Int64
    let identity: FileMetadata
    let state: FileLibraryState
    var metadata: SeratoMetadata?

    func validate(in database: GRDB.Database) throws {
        guard let current = try FileRecord.fetchOne(database, key: fileId),
              current.membershipRevision == revision,
              current.identity == identity,
              current.libraryState == state,
              metadata == nil || current.seratoMetadata == metadata
        else {
            throw FileProcessingEligibilityError.superseded(fileId: fileId)
        }
    }
}

extension FileObservationExpectation {
    init(file: FileRecord) throws {
        guard let fileID = file.id else { throw OperationEngineError.insertDidNotReturnRowId }
        self.init(fileId: fileID, revision: file.membershipRevision, identity: file.identity, state: file.libraryState, metadata: file.seratoMetadata)
    }
}

public struct ObserveFileIdentityPayload: Codable, Sendable {
    public let fileId: Int64
    public let expectedRevision: Int64
    public let previousIdentity: FileMetadata
    public let identity: FileMetadata
    public var metadata: SeratoMetadata? = nil
    public var bitrateKbps: Int? = nil
    public var bitrateWasRead: Bool? = nil
    public var expectedState: FileLibraryState? = nil
    public var ownedTagWriteEventID: Int64? = nil
    public var observedMetadata: SeratoMetadata? = nil
    public var previousObservedMetadata: SeratoMetadata? = nil
    public var uncertainV2Fields: [String]? = nil
}

public struct ObserveFileMetadataPayload: Codable, Sendable {
    let observation: ObserveFileIdentityPayload
    let evidence: AudioFileReadIdentity
    let expectedMetadata: SeratoMetadata
}

extension FileRecord {
    var seratoMetadata: SeratoMetadata {
        SeratoMetadata(artist: artist, title: title, album: album, genre: genre, bpm: bpm,
                       musicalKey: musicalKey, comment: comment, length: length, label: label)
    }

    static func loadIdentityProjections(database: LibraryDatabase) async throws -> [FileRecord] {
        let columns = "id, track_id, path, volume_uuid, inode, file_size, mtime, lightweight_hash, fingerprint_status, library_membership, file_availability, serato_library_id, retired_at, membership_revision, last_projection_invalidation_revision, artist, title, album, genre, bpm, musical_key, comment, length, label, bitrate_kbps"
        var result: [FileRecord] = []
        var cursor: Int64 = 0
        while true {
            try Task.checkCancellation()
            let lowerBound = cursor
            let batch = try await database.writer.read { connection in
                try FileRecord.fetchAll(connection, sql: "SELECT \(columns) FROM files WHERE id > ? ORDER BY id LIMIT 256", arguments: [lowerBound])
            }
            guard let lastID = batch.last?.id else { return result }
            result.append(contentsOf: batch)
            cursor = lastID
        }
    }

    var identity: FileMetadata {
        FileMetadata(path: path, volumeUuid: volumeUuid, inode: inode, fileSize: fileSize, mtime: mtime, lightweightHash: lightweightHash)
    }
}

enum FileIdentityObservationMutation {
    static func recordOwnedTagWrite(previous: FileRecord, identity: FileMetadata, eventID: Int64, in database: GRDB.Database) throws {
        guard let fileID = previous.id else { throw OperationEngineError.insertDidNotReturnRowId }
        var current = previous
        if current.fingerprintedSize == previous.fileSize, current.fingerprintedMtime == previous.mtime {
            current.fingerprintedSize = identity.fileSize
            current.fingerprintedMtime = identity.mtime
        }
        applyIdentity(identity, to: &current)
        guard current != previous else { return }
        try current.update(database)
        let payload = ObserveFileIdentityPayload(fileId: fileID, expectedRevision: previous.membershipRevision,
                                                 previousIdentity: previous.identity, identity: identity, ownedTagWriteEventID: eventID)
        _ = try OperationEngine.insertEvent(batchId: "audio-written:\(eventID)", timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                                            fileId: fileID, trackId: previous.trackId, eventType: .fileIdentityObserved,
                                            forwardPayload: payload, inversePayload: previous, in: database)
    }

    static func apply(_ payload: ObserveFileIdentityPayload, batchId: String, timestamp: Int64, in database: GRDB.Database, metadataEvidence: AudioFileReadIdentity? = nil, expectedMetadata: SeratoMetadata? = nil) throws -> Int64? {
        guard var file = try FileRecord.fetchOne(database, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        guard file.membershipRevision == payload.expectedRevision,
              file.identity == payload.previousIdentity,
              payload.expectedState == nil || payload.expectedState == file.libraryState
        else {
            throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
        }
        let previous = file
        let identity = payload.identity
        if let metadataEvidence {
            guard identity == file.identity, payload.metadata != nil, expectedMetadata == file.seratoMetadata else {
                throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
            }
            try metadataEvidence.requireUnchanged(at: identity.path)
            guard FileMetadataCollector.collect(at: identity.path)?.volumeUuid == identity.volumeUuid else {
                throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
            }
        } else {
            guard try FileMetadataCollector.collectVerified(at: identity.path) == identity else {
                throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
            }
        }
        if file.volumeUuid == LegacyFileIdentity.unknownVolume, !LegacyFileIdentity.canAdoptVolume(file, identity: identity) {
            throw SeratoReconciliationError.ambiguousIdentity(identity.path)
        }
        let moved = SeratoPath.normalized(file.path) != SeratoPath.normalized(identity.path)
        if moved {
            guard matchesContent(file, identity: identity),
                  try (SeratoPath.isVerifiedCaseAlias(file, identity: identity)
                      || FileAvailabilityResolver().inspect(path: file.path, volumeID: file.volumeUuid) == .missing)
            else {
                throw SeratoReconciliationError.ambiguousIdentity(identity.path)
            }
        }
        let replacement = !moved && isReplacement(file, identity: identity)
        if replacement {
            file.membershipRevision += 1
            file.lastProjectionInvalidationRevision = file.membershipRevision
            file.trackId = nil
            file.chromaprintFingerprint = nil
            file.fingerprintStatus = .pending
            file.fingerprintedSize = nil
            file.fingerprintedMtime = nil
            file.bitrateKbps = nil
            applyMetadata(SeratoMetadata(), to: &file)
        }
        applyIdentity(identity, to: &file)
        if let metadata = payload.metadata {
            applyMetadata(metadata, to: &file)
        }
        if payload.bitrateWasRead == true {
            file.bitrateKbps = payload.bitrateKbps
        } else if let bitrate = payload.bitrateKbps {
            file.bitrateKbps = bitrate
        }
        var journaled = payload
        if let observed = payload.observedMetadata, payload.previousObservedMetadata == nil {
            let uncertain = Set(payload.uncertainV2Fields ?? []).union(OperationEngine.changedMetadataFields(observed, previous: previous.seratoMetadata))
            journaled.uncertainV2Fields = uncertain.isEmpty ? nil : uncertain.sorted()
        }
        let changedExternalMetadata = payload.previousObservedMetadata != nil
            && payload.observedMetadata != payload.previousObservedMetadata
        guard file != previous || changedExternalMetadata || journaled.uncertainV2Fields?.isEmpty == false else { return nil }
        if file != previous {
            try file.update(database)
        }
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: file.id, trackId: previous.trackId,
                                               eventType: .fileIdentityObserved, forwardPayload: journaled, inversePayload: previous, in: database)
    }

    static func isReplacement(_ file: FileRecord, identity: FileMetadata) -> Bool {
        if LegacyFileIdentity.canAdoptVolume(file, identity: identity) {
            return false
        }
        return file.volumeUuid != identity.volumeUuid || file.inode != identity.inode
            || file.fileSize != identity.fileSize || file.mtime != identity.mtime
            || (file.lightweightHash != nil && file.lightweightHash != identity.lightweightHash)
    }

    private static func applyIdentity(_ identity: FileMetadata, to file: inout FileRecord) {
        file.path = identity.path
        file.volumeUuid = identity.volumeUuid
        file.inode = identity.inode
        file.fileSize = identity.fileSize
        file.mtime = identity.mtime
        file.lightweightHash = identity.lightweightHash
    }

    static func matchesContent(_ file: FileRecord, identity: FileMetadata) -> Bool {
        guard file.fileSize == identity.fileSize else { return false }
        if let hash = file.lightweightHash {
            return hash == identity.lightweightHash
        }
        return file.inode == identity.inode && file.volumeUuid == identity.volumeUuid && file.mtime == identity.mtime
    }

    private static func applyMetadata(_ metadata: SeratoMetadata, to file: inout FileRecord) {
        file.artist = metadata.artist
        file.title = metadata.title
        file.album = metadata.album
        file.genre = metadata.genre
        file.bpm = metadata.bpm
        file.musicalKey = metadata.musicalKey
        file.comment = metadata.comment
        file.length = metadata.length
        file.label = metadata.label
    }
}
