import Foundation

struct SyncCheckpointHeader: Codable, Equatable, Sendable {
    static let currentVersion = 1
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
        metadata = SeratoMetadata(artist: record.artist, title: record.title, album: record.album, genre: record.genre,
                                  bpm: record.bpm, musicalKey: record.key, comment: record.comment, length: record.length, label: record.label)
    }

    func record() throws -> SeratoTrackRecord {
        guard let path = String(data: pathBytes, encoding: .utf8) else { throw SyncCheckpointError.malformed }
        return SeratoTrackRecord(path: path, artist: metadata.artist, title: metadata.title, album: metadata.album,
                                 genre: metadata.genre, bpm: metadata.bpm, key: metadata.musicalKey,
                                 comment: metadata.comment, length: metadata.length, label: metadata.label)
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
