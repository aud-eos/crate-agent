import Foundation
import GRDB

struct FileObservationExpectation: Sendable {
    let fileId: Int64
    let revision: Int64
    let identity: FileMetadata
    let state: FileLibraryState

    func validate(in database: GRDB.Database) throws {
        guard let current = try FileRecord.fetchOne(database, key: fileId),
              current.membershipRevision == revision,
              current.identity == identity,
              current.libraryState == state
        else {
            throw FileProcessingEligibilityError.superseded(fileId: fileId)
        }
    }
}

public struct ObserveFileIdentityPayload: Codable, Sendable {
    public let fileId: Int64
    public let expectedRevision: Int64
    public let previousIdentity: FileMetadata
    public let identity: FileMetadata
    public var metadata: SeratoMetadata? = nil
    public var bitrateKbps: Int? = nil
    public var expectedState: FileLibraryState? = nil
}

extension FileRecord {
    static func loadIdentityProjections(database: LibraryDatabase) async throws -> [FileRecord] {
        let columns = "id, path, volume_uuid, inode, file_size, mtime, lightweight_hash, fingerprint_status, library_membership, file_availability, serato_library_id, retired_at, membership_revision, last_projection_invalidation_revision"
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
    static func apply(_ payload: ObserveFileIdentityPayload, batchId: String, timestamp: Int64, in database: GRDB.Database) throws -> Int64? {
        guard var file = try FileRecord.fetchOne(database, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        guard file.membershipRevision == payload.expectedRevision,
              FileImportIdentity.matches(file, identity: payload.previousIdentity),
              payload.expectedState == nil || payload.expectedState == file.libraryState
        else {
            throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
        }
        let previous = file
        let identity = payload.identity
        guard try FileMetadataCollector.collectVerified(at: identity.path) == identity else {
            throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
        }
        let moved = SeratoPath.normalized(file.path) != SeratoPath.normalized(identity.path)
        if moved {
            guard matchesContent(file, identity: identity),
                  try FileAvailabilityResolver().inspect(path: file.path, volumeID: file.volumeUuid) == .missing
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
        file.path = identity.path
        file.volumeUuid = identity.volumeUuid
        file.inode = identity.inode
        file.fileSize = identity.fileSize
        file.mtime = identity.mtime
        file.lightweightHash = identity.lightweightHash
        if let metadata = payload.metadata {
            applyMetadata(metadata, to: &file)
        }
        if let bitrate = payload.bitrateKbps {
            file.bitrateKbps = bitrate
        }
        guard file != previous else { return nil }
        try file.update(database)
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: file.id, trackId: previous.trackId,
                                               eventType: .fileIdentityObserved, forwardPayload: payload, inversePayload: previous, in: database)
    }

    static func isReplacement(_ file: FileRecord, identity: FileMetadata) -> Bool {
        file.volumeUuid != identity.volumeUuid || file.inode != identity.inode
            || file.fileSize != identity.fileSize || file.mtime != identity.mtime
            || (file.lightweightHash != nil && file.lightweightHash != identity.lightweightHash)
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
