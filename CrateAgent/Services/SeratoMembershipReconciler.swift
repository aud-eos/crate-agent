import Foundation
import GRDB

struct ReconciliationSummary: Sendable, Equatable {
    var retired: Int = 0
    var reactivated: Int = 0
    var unavailable: Int = 0
    var skippedUnsupported: Int = 0
    var notAppliedWrites = SeratoWriteDispositionCounts()
    var pathConflictCount: Int = 0
    var conflictBlockedWriteCount: Int = 0
    var duplicateCleanupMessage: String?
    /// Rows whose Trash item changed before their state was saved. They keep their old
    /// state and are left out of the checkpoint, so the next sync checks them again.
    var trashChangedFileIDs: Set<Int64> = []
    /// Missing rows whose volume's Trash could not be listed, so they may really be trashed.
    /// Left out of the checkpoint like `trashChangedFileIDs`, so a later sync searches again.
    var trashUncheckedFileIDs: Set<Int64> = []

    var needsAttention: Bool {
        pathConflictCount > 0 || notAppliedWrites.total > 0 || !trashUncheckedFileIDs.isEmpty
    }
}

enum SeratoReconciliationError: LocalizedError {
    case ambiguousIdentity(String)
    case alreadyReconciling

    var errorDescription: String? {
        switch self {
        case let .ambiguousIdentity(path):
            "Cannot safely associate \(path) with one indexed file. Resolve duplicate paths or identities in Serato, then retry sync."
        case .alreadyReconciling: "Library reconciliation is already running. Retry after it finishes."
        }
    }
}

enum SeratoPath {
    static func normalized(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : "/" + path
        return URL(fileURLWithPath: absolute).standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    static func isVerifiedCaseAlias(_ file: FileRecord, identity: FileMetadata) throws -> Bool {
        let original = normalized(file.path)
        let observed = normalized(identity.path)
        guard original != observed, original.caseInsensitiveCompare(observed) == .orderedSame,
              file.volumeUuid == identity.volumeUuid, file.inode == identity.inode,
              FileIdentityObservationMutation.matchesContent(file, identity: identity),
              try URL(fileURLWithPath: observed).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false
        else { return false }
        let current = try FileMetadataCollector.collectVerified(at: file.path)
        return current.volumeUuid == identity.volumeUuid && current.inode == identity.inode
            && current.fileSize == identity.fileSize && current.mtime == identity.mtime
            && current.lightweightHash == identity.lightweightHash
    }
}

actor SeratoMembershipReconciler {
    private let database: LibraryDatabase
    private let operationEngine: OperationEngine
    private let reader: SeratoMembershipSnapshotReader
    private let availability = FileAvailabilityResolver()
    private let beforeCommit: @Sendable () async throws -> Void
    private var running = false

    init(database: LibraryDatabase, operationEngine: OperationEngine, reader: SeratoMembershipSnapshotReader,
         beforeCommit: @escaping @Sendable () async throws -> Void = {})
    {
        self.database = database
        self.operationEngine = operationEngine
        self.reader = reader
        self.beforeCommit = beforeCommit
    }

    func reconcile(_ snapshot: SeratoMembershipSnapshot, analysis suppliedAnalysis: SeratoConflictAnalysis? = nil, plan: LibraryRefreshPlan? = nil) async throws -> ReconciliationSummary {
        guard !running else { throw SeratoReconciliationError.alreadyReconciling }
        running = true
        defer { running = false }
        try await reader.validate(snapshot)
        let savedPaths = Set(snapshot.records.map { record in SeratoPath.normalized(record.path) })
        let directAuthorization = suppliedAnalysis == nil ? await operationEngine.captureConflictScope() : nil
        let files: [FileRecord] = if let plan {
            plan.indexedFiles
        } else {
            try await FileRecord.loadIdentityProjections(database: database)
        }
        let analysis: SeratoConflictAnalysis = if let suppliedAnalysis {
            suppliedAnalysis
        } else {
            try await SeratoConflictAnalyzer().analyze(snapshot: snapshot, files: files, pendingRenames: operationEngine.pendingRenameSources())
        }
        try analysis.validate(snapshot)
        try await reader.validate(snapshot)
        if suppliedAnalysis == nil {
            try await operationEngine.installDirectConflictAnalysis(analysis, authorization: directAuthorization)
        }
        let eligibleFiles = files.filter { file in analysis.scope.conflictingPath(for: .file(file)) == nil }
        var byPath: [String: FileRecord] = [:]
        for file in eligibleFiles {
            let path = SeratoPath.normalized(file.path)
            guard byPath.updateValue(file, forKey: path) == nil else { throw SeratoReconciliationError.ambiguousIdentity(path) }
        }
        let moves = try resolveSavedMoves(paths: savedPaths, files: files, byPath: byPath, scope: analysis.scope)
        var summary = ReconciliationSummary()
        summary.pathConflictCount = analysis.conflicts.count
        let batchID = UUID().uuidString
        var trashIndex = NativeTrashIndex()
        for file in eligibleFiles {
            if let plan, let identifier = file.id, !plan.reconcileFileIDs.contains(identifier) {
                continue
            }
            try Task.checkCancellation()
            guard let fileID = file.id else { continue }
            guard file.seratoLibraryId == nil || file.seratoLibraryId == snapshot.libraryID else {
                summary.skippedUnsupported += 1
                continue
            }
            let observedIdentity = try moves[fileID] ?? repairedLegacyVolume(file)
            let path = observedIdentity?.path ?? file.path
            var observed = try availability.inspect(path: path, volumeID: observedIdentity?.volumeUuid ?? file.volumeUuid)
            if observed == .offline {
                summary.skippedUnsupported += 1
            }
            if observed == .trashed {
                observed = try FileTrashLocation.ownPathAvailability(path: path, volumeUuid: observedIdentity?.volumeUuid ?? file.volumeUuid,
                                                                     inode: observedIdentity?.inode ?? file.inode, resolver: availability)
            }
            var verifiedTrashLocation: FileMetadata?
            if observed == .missing {
                let location = try await database.writer.read { connection in try FileTrashLocation.load(fileID: fileID, in: connection) }
                observed = try FileTrashLocation.availability(of: location, resolver: availability)
                verifiedTrashLocation = observed == .trashed ? location : nil
                if observed == .missing, observedIdentity == nil {
                    switch try trashIndex.locate(file) {
                    case let .found(discovered):
                        observed = .trashed
                        verifiedTrashLocation = discovered
                    case .unchecked:
                        summary.trashUncheckedFileIDs.insert(fileID)
                    case .notFound:
                        break
                    }
                }
            }
            let saved = savedPaths.contains(SeratoPath.normalized(path))
            let ownedRemoval = try await operationEngine.pendingCleanupOwnsRemoval(of: file)
            let readdedAfterOwnedRemoval = ownedRemoval && saved
            var mutations: [TrackMutation] = []
            var revision = file.membershipRevision
            if let observedIdentity {
                mutations.append(.observeFileIdentity(.init(fileId: fileID, expectedRevision: revision, previousIdentity: file.identity, identity: observedIdentity)))
            } else if observed == .available {
                let identity = try FileMetadataCollector.collectVerified(at: path)
                if identity != file.identity {
                    if saved {
                        mutations.append(.observeFileIdentity(.init(fileId: fileID, expectedRevision: revision, previousIdentity: file.identity, identity: identity)))
                        if FileIdentityObservationMutation.isReplacement(file, identity: identity) {
                            revision += 1
                        }
                    } else if FileIdentityObservationMutation.isReplacement(file, identity: identity) {
                        observed = .unknown
                    }
                }
            }
            var membership = file.libraryMembership
            if observed != .offline {
                if saved {
                    membership = .active
                } else if membership != .pendingImport, !ownedRemoval,
                          try await !hasApplicableRename(file, observedAvailability: observed, savedPaths: savedPaths)
                {
                    membership = .retired
                }
            }
            let state = FileLibraryState(membership: membership, availability: observed,
                                         libraryID: observed == .offline ? file.seratoLibraryId : snapshot.libraryID,
                                         retiredAt: membership == .retired ? (file.retiredAt ?? Int64(Date().timeIntervalSince1970 * 1000)) : nil)
            mutations.append(.setFileLibraryState(.init(fileId: fileID, expectedRevision: revision, state: state, observedReadditionAfterOwnedRemoval: readdedAfterOwnedRemoval ? true : nil,
                                                        trashLocation: verifiedTrashLocation)))
            try await beforeCommit()
            let authorization = try await reader.authorization(for: snapshot)
            let expected = FileObservationExpectation(fileId: fileID, revision: file.membershipRevision, identity: file.identity, state: file.libraryState)
            do {
                _ = try await operationEngine.applyObservedBatch(mutations, authorization: authorization, expectedFiles: [expected], batchId: batchID)
            } catch FileTrashLocationError.itemChanged {
                summary.trashChangedFileIDs.insert(fileID)
                continue
            }
            if readdedAfterOwnedRemoval {
                try await operationEngine.supersedeReappearedCleanup(fileID: fileID)
            }
            if membership == .retired, file.libraryMembership != .retired {
                summary.retired += 1
            }
            if membership == .active, file.libraryMembership == .retired {
                summary.reactivated += 1
            }
            if observed != .available {
                summary.unavailable += 1
            }
        }
        try await reader.validate(snapshot)
        return summary
    }

    private func repairedLegacyVolume(_ file: FileRecord) throws -> FileMetadata? {
        guard file.volumeUuid == LegacyFileIdentity.unknownVolume,
              let basic = FileMetadataCollector.collect(at: file.path),
              try availability.inspect(path: file.path, volumeID: basic.volumeUuid) == .available else { return nil }
        let identity = try FileMetadataCollector.collectVerified(at: file.path)
        guard LegacyFileIdentity.canAdoptVolume(file, identity: identity) else {
            throw SeratoReconciliationError.ambiguousIdentity(file.path)
        }
        return identity
    }

    private func resolveSavedMoves(paths: Set<String>, files: [FileRecord], byPath: [String: FileRecord], scope: SeratoConflictScope) throws -> [Int64: FileMetadata] {
        struct PhysicalIdentity: Hashable {
            let volume: String
            let inode: Int64
        }
        let byPhysicalIdentity = Dictionary(grouping: files) { file in PhysicalIdentity(volume: file.volumeUuid, inode: file.inode) }
        var byHash: [Data: [FileRecord]] = [:]
        for file in files {
            if let hash = file.lightweightHash {
                byHash[hash, default: []].append(file)
            }
        }
        var moves: [Int64: FileMetadata] = [:]
        for path in paths.sorted() where byPath[path] == nil {
            try Task.checkCancellation()
            guard scope.conflictingPath(for: SeratoConflictTarget(paths: [path])) == nil, let basic = FileMetadataCollector.collect(at: path),
                  try availability.inspect(path: path, volumeID: basic.volumeUuid) == .available else { continue }
            let identity = try FileMetadataCollector.collectVerified(at: path)
            guard scope.conflictingPath(for: SeratoConflictTargets.identity(identity)) == nil else { continue }
            let inodeCandidates = byPhysicalIdentity[PhysicalIdentity(volume: identity.volumeUuid, inode: identity.inode)] ?? []
            let hashCandidates = identity.lightweightHash.flatMap { hash in byHash[hash] } ?? []
            let candidates = inodeCandidates.isEmpty ? hashCandidates : inodeCandidates
            guard !candidates.contains(where: { file in scope.conflictingPath(for: .file(file)) != nil }) else {
                throw SeratoReconciliationError.ambiguousIdentity(path)
            }
            guard !candidates.isEmpty else { continue }
            guard candidates.count == 1, let candidate = candidates.first, let fileID = candidate.id,
                  moves[fileID] == nil,
                  FileIdentityObservationMutation.matchesContent(candidate, identity: identity),
                  try (SeratoPath.isVerifiedCaseAlias(candidate, identity: identity)
                      || availability.inspect(path: candidate.path, volumeID: candidate.volumeUuid) == .missing)
            else {
                throw SeratoReconciliationError.ambiguousIdentity(path)
            }
            moves[fileID] = identity
        }
        return moves
    }

    private func hasApplicableRename(_ file: FileRecord, observedAvailability: FileAvailability, savedPaths: Set<String>) async throws -> Bool {
        guard file.libraryMembership == .active, observedAvailability == .available,
              let fileID = file.id,
              try availability.inspect(path: file.path, volumeID: file.volumeUuid) == .available,
              try Self.matchesKnownFile(file, identity: FileMetadataCollector.collectVerified(at: file.path)) else { return false }
        let events = try await database.writer.read { connection in
            try EventRecord.filter(Column("file_id") == fileID && Column("event_type") == EventType.fileRenamed.rawValue).order(Column("event_id").desc).fetchAll(connection)
        }
        for event in events {
            guard try SeratoWriteEligibility.replayToken(event: event, file: file) != nil else { continue }
            let rename = try JSONDecoder().decode(RenameFilePayload.self, from: Data(event.payloadJson.utf8))
            guard savedPaths.contains(SeratoPath.normalized(rename.previousPath)),
                  try availability.inspect(path: rename.previousPath, volumeID: rename.previousVolumeUuid ?? file.volumeUuid) == .missing else { continue }
            return true
        }
        return false
    }

    private static func matchesKnownFile(_ file: FileRecord, identity: FileMetadata) -> Bool {
        SeratoPath.normalized(file.path) == SeratoPath.normalized(identity.path)
            && file.inode == identity.inode && file.volumeUuid == identity.volumeUuid
            && file.fileSize == identity.fileSize && file.mtime == identity.mtime
            && (file.lightweightHash == nil || file.lightweightHash == identity.lightweightHash)
    }

    /// One validated pass for coalesced dropped/root/directory observations. The caller
    /// retains a failed filesystem batch and only checkpoints after this returns.
    func reconcileRequestedFilesystemChanges() async throws -> ReconciliationSummary {
        try await reconcile(reader.read())
    }
}
