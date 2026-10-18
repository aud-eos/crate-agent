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
    private struct Destination: Sendable {
        let metadata: FileMetadata
        let readIdentity: AudioFileReadIdentity
    }

    private struct PendingMove: Sendable {
        let original: FileObservationExpectation
        let sourceReadIdentity: AudioFileReadIdentity
        var destinations: [Destination]
    }

    // At most two destinations per indexed row: the second records ambiguity.
    private var pendingMoves: [Int64: PendingMove] = [:]
    private var invalidatedSources: [Int64: AudioFileReadIdentity] = [:]
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

    public func restoreReconciliationRequest() {
        requiresReconciliation = true
    }

    public func handleBatch(_ batch: FilesystemEventBatch) async throws {
        requiresReconciliation = requiresReconciliation || batch.requiresReconciliation
        try await handleObservations(batch.observations)
    }

    public func handleObservations(_ observations: [FSEventsObservation]) async throws {
        var blocked: [FSEventsObservation] = []
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
            } catch is SeratoPathConflictError {
                blocked.append(observation)
                requiresReconciliation = true
            } catch { throw FilesystemObservationError(path: observation.path, underlying: error) }
        }
        if !blocked.isEmpty {
            throw FilesystemConflictDeferral(observations: blocked)
        }
    }

    private func handle(_ observation: FSEventsObservation, batchID: String) async throws {
        try await operationEngine.requireUnconflicted(SeratoConflictTarget(paths: [observation.path]))
        let knownPath = try await database.writer.read { connection in
            try FileRecord.filter(Column("path") == observation.path).fetchOne(connection)
        }
        if let knownPath {
            try await observeIndexedPath(of: knownPath, batchID: batchID)
            return
        }
        try await revalidateTrashLocation(at: observation.path, batchID: batchID)
        guard observation.wasRenamed || observation.wasCreated else { return }
        guard let metadata = FileMetadataCollector.collect(at: observation.path) else {
            // Unknown old-side events have no tracked row to observe. Never infer deletion from stat failure.
            return
        }
        try await operationEngine.requireUnconflicted(SeratoConflictTargets.identity(metadata))
        let inodeMatches = try await database.writer.read { connection in
            try FileRecord.filter(Column("inode") == metadata.inode)
                .filter(Column("volume_uuid") == metadata.volumeUuid).fetchAll(connection)
        }
        if inodeMatches.count > 1 {
            requiresReconciliation = true; return
        }
        if let indexed = inodeMatches.first, Self.namesSameEntry(observation.path, indexed.path) {
            try await observeIndexedPath(of: indexed, batchID: batchID)
            return
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
        try await operationEngine.requireUnconflicted(.file(existing))
        if let fileID = existing.id, invalidatedSources[fileID] != nil {
            requiresReconciliation = true
            return
        }
        let previousAvailability = try inspectKnownIdentity(existing)
        guard previousAvailability == .missing || previousAvailability == .offline else {
            requiresReconciliation = true
            if previousAvailability == .available {
                try rememberDestination(at: observation.path, for: existing)
            }
            try await observe(file: existing, availability: previousAvailability, metadata: nil, batchID: batchID)
            return
        }
        if let fileID = existing.id, pendingMoves[fileID] != nil {
            try rememberDestination(at: observation.path, for: existing)
            _ = try await resolvePendingMove(for: existing, batchID: batchID)
            return
        }
        let availability = try availabilityResolver.inspect(path: observation.path, volumeID: metadata.volumeUuid)
        var trashLocation: FileMetadata?
        if availability == .trashed {
            guard let location = try FileTrashLocation.capture(at: observation.path, for: existing) else {
                requiresReconciliation = true
                return
            }
            trashLocation = location
        }
        try await observe(file: existing, availability: availability, metadata: metadata, trashLocation: trashLocation, batchID: batchID)
    }

    private func observeIndexedPath(of file: FileRecord, batchID: String) async throws {
        try await operationEngine.requireUnconflicted(.file(file))
        if try await resolvePendingMove(for: file, batchID: batchID) {
            return
        }
        guard let current = try await currentAvailability(of: file) else { return }
        try await observe(file: file, availability: current.availability, metadata: nil, trashLocation: current.trashLocation, batchID: batchID)
    }

    /// FSEvents names an item by its real path, which an indexed path can spell differently
    /// (`/tmp` for `/private/tmp`, a symlinked folder, or case on a case-insensitive volume).
    /// Taking the row's own entry for a move destination would record a bogus move that
    /// later drops its real Trash destination (#225).
    private static func namesSameEntry(_ path: String, _ other: String) -> Bool {
        guard let resolved = realPath(path), let otherResolved = realPath(other) else { return false }
        return resolved == otherResolved
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A trashed row keeps its indexed path, so only its recorded Trash item proves the audio still exists.
    /// When the indexed path holds a different file, reconciliation is requested: an available row
    /// loses eligibility (`unknown`), while a missing or trashed row keeps its state (nil, no write).
    private func currentAvailability(of file: FileRecord) async throws -> (availability: FileAvailability, trashLocation: FileMetadata?)? {
        guard let availability = try identityAvailability(file) else {
            return file.fileAvailability == .missing || file.fileAvailability == .trashed ? nil : (.unknown, nil)
        }
        guard availability == .missing, let fileID = file.id else { return (availability, nil) }
        let location = try await database.writer.read { connection in try FileTrashLocation.load(fileID: fileID, in: connection) }
        let observed = try FileTrashLocation.availability(of: location, resolver: availabilityResolver)
        return (observed, observed == .trashed ? location : nil)
    }

    /// Removing or emptying a Trash item reports only its Trash path, never the indexed path.
    private func revalidateTrashLocation(at path: String, batchID: String) async throws {
        let trashedFiles = try await database.writer.read { connection in
            try FileTrashLocation.fileIDs(at: path, in: connection)
                .compactMap { fileID in try FileRecord.fetchOne(connection, key: fileID) }
        }
        for file in trashedFiles {
            try await operationEngine.requireUnconflicted(.file(file))
            guard let current = try await currentAvailability(of: file), current.availability != file.fileAvailability else { continue }
            try await observe(file: file, availability: current.availability, metadata: nil, trashLocation: current.trashLocation, batchID: batchID)
        }
    }

    private func rememberDestination(at path: String, for file: FileRecord) throws {
        guard let fileID = file.id else { throw OperationEngineError.insertDidNotReturnRowId }
        let readIdentity = try AudioFileReadIdentity.read(at: path)
        let metadata = try FileMetadataCollector.collectVerified(at: path)
        try readIdentity.requireUnchanged(at: path)
        guard FileIdentityObservationMutation.matchesContent(file, identity: metadata) else { return }
        var pending: PendingMove
        if let retained = pendingMoves[fileID] {
            pending = retained
        } else {
            let sourceReadIdentity = try AudioFileReadIdentity.read(at: file.path)
            guard try FileMetadataCollector.collectVerified(at: file.path) == file.identity else {
                requiresReconciliation = true
                return
            }
            try sourceReadIdentity.requireUnchanged(at: file.path)
            pending = try PendingMove(original: FileObservationExpectation(file: file), sourceReadIdentity: sourceReadIdentity, destinations: [])
        }
        guard matchesOriginal(file, pending: pending) else {
            pendingMoves.removeValue(forKey: fileID)
            requiresReconciliation = true
            return
        }
        if try inspectKnownIdentity(file) == .available, try invalidateChangedSource(pending) {
            return
        }
        let alreadyObserved = pending.destinations.contains { $0.metadata.path == path }
        pending.destinations = try validDestinations(pending.destinations)
        if alreadyObserved, !pending.destinations.contains(where: { $0.metadata.path == path }) {
            pendingMoves[fileID] = pending.destinations.isEmpty ? nil : pending
            return
        }
        if !pending.destinations.contains(where: { $0.metadata.path == path }), pending.destinations.count < 2 {
            pending.destinations.append(Destination(metadata: metadata, readIdentity: readIdentity))
        }
        pendingMoves[fileID] = pending
        guard pending.destinations.count < 2 else { throw SeratoReconciliationError.ambiguousIdentity(path) }
    }

    private func matchesOriginal(_ file: FileRecord, pending: PendingMove) -> Bool {
        let original = pending.original
        let observedSourceMissing = original.state.membership == .active && original.state.availability == .available
            && file.libraryState == FileLibraryState(membership: .active, availability: .missing,
                                                     libraryID: original.state.libraryID, retiredAt: original.state.retiredAt)
        return file.membershipRevision == original.revision && file.identity == original.identity
            && (file.libraryState == original.state || observedSourceMissing)
    }

    private func invalidateSource(_ pending: PendingMove) {
        pendingMoves.removeValue(forKey: pending.original.fileId)
        invalidatedSources[pending.original.fileId] = pending.sourceReadIdentity
        requiresReconciliation = true
    }

    private func invalidateChangedSource(_ pending: PendingMove) throws -> Bool {
        let original = pending.original
        var unchanged = false
        defer {
            if !unchanged {
                invalidateSource(pending)
            }
        }
        unchanged = try FileMetadataCollector.collectVerified(at: original.identity.path) == original.identity
            && AudioFileReadIdentity.read(at: original.identity.path) == pending.sourceReadIdentity
        return !unchanged
    }

    private func validDestinations(_ destinations: [Destination]) throws -> [Destination] {
        var valid: [Destination] = []
        for destination in destinations {
            let metadata = destination.metadata
            let availability = try availabilityResolver.inspect(path: metadata.path, volumeID: metadata.volumeUuid)
            guard availability == .available else {
                requiresReconciliation = true
                if availability == .inaccessible {
                    throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: metadata.path])
                }
                continue
            }
            guard try FileMetadataCollector.collectVerified(at: metadata.path) == metadata,
                  try AudioFileReadIdentity.read(at: metadata.path) == destination.readIdentity
            else {
                requiresReconciliation = true
                continue
            }
            valid.append(destination)
        }
        return valid
    }

    private func resolvePendingMove(for file: FileRecord, batchID: String) async throws -> Bool {
        guard let fileID = file.id, var pending = pendingMoves[fileID] else { return false }
        guard matchesOriginal(file, pending: pending) else {
            pendingMoves.removeValue(forKey: fileID)
            requiresReconciliation = true
            return false
        }
        let sourceAvailability = try inspectKnownIdentity(file)
        if sourceAvailability == .available, try invalidateChangedSource(pending) {
            return false
        }
        pending.destinations = try validDestinations(pending.destinations)
        pendingMoves[fileID] = pending.destinations.isEmpty ? nil : pending
        guard pending.destinations.count < 2 else { throw SeratoReconciliationError.ambiguousIdentity(file.path) }
        guard let destination = pending.destinations.first else { return false }
        guard sourceAvailability == .missing else {
            if sourceAvailability != .available {
                invalidateSource(pending)
            }
            return false
        }
        let expected = try FilesystemMoveExpectation(original: FileObservationExpectation(file: file), destination: destination.metadata, destinationReadIdentity: destination.readIdentity)
        try await observe(file: file, availability: .available, metadata: destination.metadata, batchID: batchID, moveExpectation: expected)
        pendingMoves.removeValue(forKey: fileID)
        return true
    }

    /// For move resolution, a path now holding a different file still counts as the row's
    /// previous missing or trashed state.
    private func inspectKnownIdentity(_ file: FileRecord) throws -> FileAvailability {
        try identityAvailability(file) ?? (file.fileAvailability == .missing || file.fileAvailability == .trashed ? file.fileAvailability : .unknown)
    }

    /// Nil when the indexed path holds a different file; reconciliation is requested.
    private func identityAvailability(_ file: FileRecord) throws -> FileAvailability? {
        let availability = try availabilityResolver.inspect(path: file.path, volumeID: file.volumeUuid)
        guard availability == .available || availability == .trashed else { return availability }
        guard let metadata = FileMetadataCollector.collect(at: file.path),
              metadata.inode == file.inode, metadata.volumeUuid == file.volumeUuid
        else {
            requiresReconciliation = true
            return nil
        }
        return availability
    }

    private func observe(file: FileRecord, availability: FileAvailability, metadata: FileMetadata?, trashLocation: FileMetadata? = nil,
                         batchID: String, moveExpectation: FilesystemMoveExpectation? = nil) async throws
    {
        guard let fileId = file.id else { throw OperationEngineError.insertDidNotReturnRowId }
        var mutations: [TrackMutation] = [.setFileLibraryState(.init(
            fileId: fileId, expectedRevision: file.membershipRevision,
            state: FileLibraryState(membership: file.libraryMembership, availability: availability,
                                    libraryID: file.seratoLibraryId, retiredAt: file.retiredAt),
            trashLocation: trashLocation
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
        do {
            _ = try await operationEngine.applyFilesystemObservations(mutations, batchId: batchID, moveExpectation: moveExpectation)
        } catch FileTrashLocationError.itemChanged {
            requiresReconciliation = true
        }
    }
}

struct FilesystemMoveExpectation: Sendable {
    let original: FileObservationExpectation
    let destination: FileMetadata
    let destinationReadIdentity: AudioFileReadIdentity

    func validate(in database: GRDB.Database) throws {
        try original.validate(in: database)
        try validatePhysicalTargets()
    }

    func validatePhysicalTargets() throws {
        guard try FileAvailabilityResolver().inspect(path: original.identity.path, volumeID: original.identity.volumeUuid) == .missing,
              try FileMetadataCollector.collectVerified(at: destination.path) == destination
        else {
            throw FileProcessingEligibilityError.superseded(fileId: original.fileId)
        }
        try destinationReadIdentity.requireUnchanged(at: destination.path)
    }
}

public struct FilesystemObservationError: LocalizedError {
    public let path: String
    public let underlying: Error
    public var errorDescription: String? {
        "Cannot synchronize filesystem observation at \(path): \(underlying.localizedDescription)"
    }
}
