import Foundation
import GRDB

/// Observes known files only. Membership is exclusively determined by Serato reconciliation.
public actor FilesystemSyncCoordinator {
    public static let defaultAudioExtensions: Set<String> = [
        "mp3", "flac", "wav", "wave", "aif", "aiff", "m4a", "mp4", "alac", "aac", "ogg", "oga", "opus",
    ]

    private let operationEngine: OperationEngine
    private let database: LibraryDatabase
    private let audioExtensions: Set<String>
    private let availabilityResolver = FileAvailabilityResolver()
    public private(set) var requiresReconciliation = false

    public init(operationEngine: OperationEngine, database: LibraryDatabase,
                audioExtensions: Set<String> = FilesystemSyncCoordinator.defaultAudioExtensions)
    {
        self.operationEngine = operationEngine
        self.database = database
        self.audioExtensions = audioExtensions
    }

    public func takeReconciliationRequest() -> Bool {
        let requested = requiresReconciliation
        requiresReconciliation = false
        return requested
    }

    public func handleBatch(_ batch: FilesystemEventBatch) async throws {
        requiresReconciliation = requiresReconciliation || batch.requiresReconciliation
        try await handleObservations(batch.observations)
    }

    public func handleObservations(_ observations: [FSEventsObservation]) async throws {
        for observation in observations {
            if observation.requiresReconciliation || observation.rootChanged || (observation.isDirectory && observation.wasRenamed) {
                requiresReconciliation = true
            }
            guard observation.isFile,
                  audioExtensions.contains((observation.path as NSString).pathExtension.lowercased()) else { continue }
            do {
                let batchID = observation.eventID.map { "filesystem-event-\($0)" } ?? UUID().uuidString
                let hasPriorWrites = try await database.writer.read { connection in
                    try EventRecord.filter(Column("batch_id") == batchID).fetchAll(connection)
                        .contains { $0.eventType.hasReplayableSeratoProjection }
                }
                if hasPriorWrites {
                    _ = try await operationEngine.resyncSeratoForBatch(batchID)
                }
                try await handle(observation, batchID: batchID)
            } catch { throw FilesystemObservationError(path: observation.path, underlying: error) }
        }
    }

    private func handle(_ observation: FSEventsObservation, batchID: String) async throws {
        let knownPath = try await database.writer.read { connection in
            try FileRecord.filter(Column("path") == observation.path).fetchOne(connection)
        }
        if let knownPath {
            var availability = try inspectKnownIdentity(knownPath)
            // An old-path removal is not evidence that a positively identified Trash item disappeared.
            if availability == .missing, knownPath.fileAvailability == .trashed {
                availability = .trashed
            }
            try await observe(file: knownPath, availability: availability, metadata: nil, batchID: batchID)
            return
        }
        guard observation.wasRenamed || observation.wasCreated else { return }
        guard let metadata = FileMetadataCollector.collect(at: observation.path) else {
            // Unknown old-side events have no tracked row to observe. Never infer deletion from stat failure.
            return
        }
        let inodeMatches = try await database.writer.read { connection in
            try FileRecord.filter(Column("inode") == metadata.inode)
                .filter(Column("volume_uuid") == metadata.volumeUuid).fetchAll(connection)
        }
        if inodeMatches.count > 1 {
            requiresReconciliation = true; return
        }
        var existing = inodeMatches.first
        if existing == nil {
            guard let hash = LightweightHashCalculator.compute(forFileAt: observation.path) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: observation.path])
            }
            let candidates = try await database.writer.read { connection in
                try FileRecord.filter(Column("file_size") == metadata.fileSize)
                    .filter(Column("lightweight_hash") == hash).fetchAll(connection)
            }
            guard candidates.count == 1 else {
                if candidates.count > 1 {
                    requiresReconciliation = true
                }
                return
            }
            existing = candidates.first
        }
        guard let existing else { return }
        let previousAvailability = try inspectKnownIdentity(existing)
        guard previousAvailability == .missing || previousAvailability == .offline else {
            requiresReconciliation = true
            try await observe(file: existing, availability: previousAvailability, metadata: nil, batchID: batchID)
            return
        }
        let availability = try availabilityResolver.inspect(path: observation.path, volumeID: metadata.volumeUuid)
        try await observe(file: existing, availability: availability, metadata: metadata, batchID: batchID)
    }

    private func inspectKnownIdentity(_ file: FileRecord) throws -> FileAvailability {
        let availability = try availabilityResolver.inspect(path: file.path, volumeID: file.volumeUuid)
        guard availability == .available || availability == .trashed else { return availability }
        guard let metadata = FileMetadataCollector.collect(at: file.path),
              metadata.inode == file.inode, metadata.volumeUuid == file.volumeUuid
        else {
            requiresReconciliation = true
            return file.fileAvailability == .missing || file.fileAvailability == .trashed ? file.fileAvailability : .unknown
        }
        return availability
    }

    private func observe(file: FileRecord, availability: FileAvailability, metadata: FileMetadata?, batchID: String) async throws {
        guard let fileId = file.id else { throw OperationEngineError.insertDidNotReturnRowId }
        var mutations: [TrackMutation] = [.setFileLibraryState(.init(
            fileId: fileId, expectedRevision: file.membershipRevision,
            state: FileLibraryState(membership: file.libraryMembership, availability: availability,
                                    libraryID: file.seratoLibraryId, retiredAt: file.retiredAt)
        ))]
        if availability == .available, let metadata,
           file.path != metadata.path || file.inode != metadata.inode || file.volumeUuid != metadata.volumeUuid
        {
            if file.libraryMembership == .active {
                mutations.append(.renameFile(.init(fileId: fileId, newPath: metadata.path,
                                                   newVolumeUuid: metadata.volumeUuid, newInode: metadata.inode)))
            } else {
                mutations.append(.observeFileLocation(.init(fileId: fileId, expectedRevision: file.membershipRevision,
                                                            path: metadata.path, volumeUuid: metadata.volumeUuid, inode: metadata.inode)))
            }
        }
        _ = try await operationEngine.applyBatch(mutations, batchId: batchID)
    }
}

public struct FilesystemObservationError: LocalizedError {
    public let path: String
    public let underlying: Error
    public var errorDescription: String? {
        "Cannot synchronize filesystem observation at \(path): \(underlying.localizedDescription)"
    }
}
