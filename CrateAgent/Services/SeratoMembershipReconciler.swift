import Foundation
import GRDB

struct ReconciliationSummary: Sendable, Equatable {
    var retired: Int = 0
    var reactivated: Int = 0
    var unavailable: Int = 0
    var skippedUnsupported: Int = 0
}

enum SeratoReconciliationError: LocalizedError {
    case ambiguousIdentity(String)
    case alreadyReconciling

    var errorDescription: String? {
        switch self {
        case let .ambiguousIdentity(path):
            return "Cannot safely associate \(path) with one indexed file. Resolve duplicate paths or identities in Serato, then retry sync."
        case .alreadyReconciling: return "Library reconciliation is already running. Retry after it finishes."
        }
    }
}

enum SeratoPath {
    static func normalized(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : "/" + path
        return URL(fileURLWithPath: absolute).standardizedFileURL.path.precomposedStringWithCanonicalMapping
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

    func reconcile(_ snapshot: SeratoMembershipSnapshot) async throws -> ReconciliationSummary {
        guard !running else { throw SeratoReconciliationError.alreadyReconciling }
        running = true
        defer { running = false }
        try await reader.validate(snapshot)
        let savedPaths = Set(snapshot.records.map { record in SeratoPath.normalized(record.path) })
        let files = try await FileRecord.loadIdentityProjections(database: database)
        var byPath: [String: FileRecord] = [:]
        for file in files {
            let path = SeratoPath.normalized(file.path)
            guard byPath.updateValue(file, forKey: path) == nil else { throw SeratoReconciliationError.ambiguousIdentity(path) }
        }
        let moves = try resolveSavedMoves(paths: savedPaths, files: files, byPath: byPath)
        var summary = ReconciliationSummary()
        let batchID = UUID().uuidString
        for file in files {
            try Task.checkCancellation()
            guard let fileID = file.id else { continue }
            guard file.seratoLibraryId == nil || file.seratoLibraryId == snapshot.libraryID else {
                summary.skippedUnsupported += 1
                continue
            }
            let movedIdentity = moves[fileID]
            let path = movedIdentity?.path ?? file.path
            var observed = try availability.inspect(path: path, volumeID: movedIdentity?.volumeUuid ?? file.volumeUuid)
            if observed == .offline {
                summary.skippedUnsupported += 1
            }
            if observed == .missing, file.fileAvailability == .trashed {
                observed = .trashed
            }
            let saved = savedPaths.contains(SeratoPath.normalized(path))
            var mutations: [TrackMutation] = []
            var revision = file.membershipRevision
            if let movedIdentity {
                mutations.append(.observeFileIdentity(.init(fileId: fileID, expectedRevision: revision, previousIdentity: file.identity, identity: movedIdentity)))
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
                } else if membership != .pendingImport,
                          try !(await hasApplicableRename(file, observedAvailability: observed, savedPaths: savedPaths))
                {
                    membership = .retired
                }
            }
            let state = FileLibraryState(membership: membership, availability: observed,
                                         libraryID: observed == .offline ? file.seratoLibraryId : snapshot.libraryID,
                                         retiredAt: membership == .retired ? (file.retiredAt ?? Int64(Date().timeIntervalSince1970 * 1000)) : nil)
            mutations.append(.setFileLibraryState(.init(fileId: fileID, expectedRevision: revision, state: state)))
            try await beforeCommit()
            let authorization = try await reader.authorization(for: snapshot)
            let expected = FileObservationExpectation(fileId: fileID, revision: file.membershipRevision, identity: file.identity, state: file.libraryState)
            _ = try await operationEngine.applyObservedBatch(mutations, authorization: authorization, expectedFiles: [expected], batchId: batchID)
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
        return summary
    }

    private func resolveSavedMoves(paths: Set<String>, files: [FileRecord], byPath: [String: FileRecord]) throws -> [Int64: FileMetadata] {
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
            guard let basic = FileMetadataCollector.collect(at: path),
                  try availability.inspect(path: path, volumeID: basic.volumeUuid) == .available else { continue }
            let identity = try FileMetadataCollector.collectVerified(at: path)
            let inodeCandidates = byPhysicalIdentity[PhysicalIdentity(volume: identity.volumeUuid, inode: identity.inode)] ?? []
            let hashCandidates = identity.lightweightHash.flatMap { hash in byHash[hash] } ?? []
            let candidates = inodeCandidates.isEmpty ? hashCandidates : inodeCandidates
            guard !candidates.isEmpty else { continue }
            guard candidates.count == 1, let candidate = candidates.first, let fileID = candidate.id,
                  moves[fileID] == nil,
                  FileIdentityObservationMutation.matchesContent(candidate, identity: identity),
                  try availability.inspect(path: candidate.path, volumeID: candidate.volumeUuid) == .missing
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
