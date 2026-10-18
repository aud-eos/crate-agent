import Foundation

struct SyncCheckpointHeader: Codable, Equatable, Sendable {
    /// 2 saves Serato's year (#95); a version 1 checkpoint forces one full sync.
    static let currentVersion = 2
    var formatVersion = currentVersion
    let libraryID: String
    let source: SeratoSourceIdentity
    let localRevision: Int64
    let watchRoots: [String]
    let eventID: UInt64
    let hadConflicts: Bool
    var complete = true
}

struct SavedSeratoOccurrence: Codable, Equatable, Sendable {
    let pathBytes: Data
    let metadata: SeratoMetadata

    init(pathBytes: Data, metadata: SeratoMetadata) {
        self.pathBytes = pathBytes
        self.metadata = metadata
    }

    init(_ record: SeratoTrackRecord) {
        pathBytes = Data(record.path.utf8)
        metadata = SeratoMetadata(record)
    }

    func record() throws -> SeratoTrackRecord {
        guard let path = String(data: pathBytes, encoding: .utf8) else { throw SyncCheckpointError.malformed }
        return metadata.record(path: path)
    }
}

struct SyncFileEvidence: Codable, Equatable, Sendable {
    let fileID: Int64
    let membershipRevision: Int64
    let identity: FileMetadata
    let readIdentity: AudioFileReadIdentity?
    let bitrateProbed: Bool
    var bitrateError: String? = nil
}

struct LibrarySyncCheckpoint: Sendable {
    let header: SyncCheckpointHeader
    let records: [SavedSeratoOccurrence]
    let files: [SyncFileEvidence]
}

struct SyncDirtyFiles: Sendable {
    let fileIDs: Set<Int64>
    let paths: Set<Data>
}

enum SyncCheckpointError: LocalizedError {
    case changed
    case incompleteEffects
    case queuedChangesPending
    case malformed

    var errorDescription: String? {
        switch self {
        case .changed: "Library evidence changed during startup validation. Retry sync."
        case .incompleteEffects: "An interrupted file move or pre-upgrade change has not finished. Retry Sync or review History before processing resumes."
        case .queuedChangesPending: "Queued library changes have not finished applying. Retry Sync to apply them."
        case .malformed: "Saved validation data is invalid. Use Re-scan File Info to rebuild it."
        }
    }
}
