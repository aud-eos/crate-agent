import Foundation
import GRDB

/// The journaled form of recording the subsecond modification time of a row indexed
/// before migration 018: only the file, its revision and the nanoseconds, so a library's
/// one-time upgrade stays small in the event log. The inverse carries `nil`.
public struct SubsecondModificationTimePayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let membershipRevision: Int64
    public let mtimeNanoseconds: Int64?
}

/// Records a legacy row's subsecond modification time from the read identity the sync
/// already verified for it, without re-reading the audio.
public struct RecordSubsecondModificationTimePayload: Sendable {
    let time: SubsecondModificationTimePayload
    let identity: FileMetadata
    let evidence: AudioFileReadIdentity
}

enum SubsecondModificationTimeMutation {
    /// Returns nil without a change when the row or file moved on since the evidence was
    /// read, so one edited file leaves only its own row for the next sync to plan again.
    static func apply(_ payload: RecordSubsecondModificationTimePayload, batchId: String, timestamp: Int64,
                      in database: GRDB.Database) throws -> Int64?
    {
        let time = payload.time
        guard var file = try FileRecord.fetchOne(database, key: time.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: time.fileId)
        }
        let target = payload.evidence.target
        guard let nanoseconds = time.mtimeNanoseconds, Int64(target.modifiedNanoseconds) == nanoseconds,
              target.size == payload.identity.fileSize, Int64(bitPattern: target.inode) == payload.identity.inode,
              Int64(target.modifiedSeconds) == payload.identity.mtime
        else {
            throw SyncCheckpointError.malformed
        }
        guard file.membershipRevision == time.membershipRevision, file.mtimeNanoseconds == nil, file.identity == payload.identity,
              FileProcessingEligibility.isProcessable(membership: file.libraryMembership, availability: file.fileAvailability)
        else { return nil }
        do {
            try payload.evidence.requireUnchanged(at: file.path)
        } catch SeratoMembershipSnapshotError.sourceChanged {
            return nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        file.mtimeNanoseconds = nanoseconds
        try file.update(database)
        let inverse = SubsecondModificationTimePayload(fileId: time.fileId, membershipRevision: time.membershipRevision, mtimeNanoseconds: nil)
        return try OperationEngine.insertEvent(batchId: batchId, timestamp: timestamp, fileId: file.id, trackId: file.trackId,
                                               eventType: .fileModificationTimeRecorded, forwardPayload: time, inversePayload: inverse, in: database)
    }
}
