import Foundation

enum LibrarySyncRequest: Equatable, Sendable {
    case incremental
    case forceRefresh
}

struct LibraryRefreshPlan: Sendable {
    let indexedFiles: [FileRecord]
    let metadataPaths: Set<PathBytes>
    let refreshPaths: Set<PathBytes>
    let reconcileFileIDs: Set<Int64>
    let evidence: [Int64: SyncFileEvidence]
    /// Unchanged rows indexed before subsecond times were kept, with the subsecond part
    /// their verified stat evidence already holds, so it is recorded without re-reading.
    var subsecondTimes: [Int64: Int64] = [:]
}

struct FileRefreshObservation: Sendable {
    let identity: AudioFileReadIdentity
    let volumeID: String

    static func read(at path: String) throws -> Self? {
        guard let basic = FileMetadataCollector.collect(at: path) else { return nil }
        return try Self(identity: AudioFileReadIdentity.read(at: path), volumeID: basic.volumeUuid)
    }
}

struct LibraryRefreshPlanner: Sendable {
    private let evidence: [Int64: SyncFileEvidence]
    private let validatedFileIDs: Set<Int64>
    private let requiresReconciliation: Bool
    private let inspect: @Sendable (String) throws -> FileRefreshObservation?

    init(evidence: [Int64: SyncFileEvidence], validatedFileIDs: Set<Int64>, requiresReconciliation: Bool = false,
         inspect: @escaping @Sendable (String) throws -> FileRefreshObservation? = { path in try FileRefreshObservation.read(at: path) })
    {
        self.evidence = evidence
        self.validatedFileIDs = validatedFileIDs
        self.requiresReconciliation = requiresReconciliation
        self.inspect = inspect
    }

    func makePlan(request: LibrarySyncRequest, snapshot: SeratoMembershipSnapshot, indexedFiles: [FileRecord],
                  previousRecords: [SeratoTrackRecord], dirtyFileIDs: Set<Int64>, dirtyPaths: Set<PathBytes>,
                  analysis: SeratoConflictAnalysis) async throws -> LibraryRefreshPlan
    {
        try analysis.validate(snapshot)
        let savedPaths = Set(snapshot.records.map { record in SeratoPath.normalized(record.path) })
        let previous = Dictionary(grouping: previousRecords) { record in PathBytes(record.path) }
        let indexed = Dictionary(grouping: indexedFiles) { file in SeratoPath.normalized(file.path) }
        let normalizedDirtyPaths = Set(dirtyPaths.compactMap { path in String(data: path.bytes, encoding: .utf8).map(SeratoPath.normalized) })
        var refresh: Set<PathBytes> = []
        var metadata: Set<PathBytes> = []
        var reconcile: Set<Int64> = []
        var sound: Set<Int64> = []
        var subsecondTimes: [Int64: Int64] = [:]
        for file in indexedFiles {
            try Task.checkCancellation()
            guard let identifier = file.id, analysis.scope.conflictingPath(for: .file(file)) == nil else { continue }
            let path = SeratoPath.normalized(file.path)
            let dirty = dirtyFileIDs.contains(identifier) || normalizedDirtyPaths.contains(path)
            var reusable = request != .forceRefresh && !requiresReconciliation
                && file.libraryMembership == .active && file.fileAvailability == .available
                && file.seratoLibraryId == snapshot.libraryID && savedPaths.contains(path)
            if let stored = evidence[identifier], stored.membershipRevision == file.membershipRevision,
               stored.identity == file.identity, stored.bitrateProbed, let stamp = stored.readIdentity
            {
                if reusable, dirty || !validatedFileIDs.contains(identifier) {
                    let observation = try inspect(file.path)
                    reusable = observation?.identity == stamp && observation?.volumeID == file.volumeUuid
                }
            } else {
                reusable = false
            }
            if reusable {
                sound.insert(identifier)
                if file.mtimeNanoseconds == nil, let stamp = evidence[identifier]?.readIdentity {
                    subsecondTimes[identifier] = Int64(stamp.target.modifiedNanoseconds)
                }
            } else {
                reconcile.insert(identifier)
            }
        }
        for record in snapshot.records {
            try Task.checkCancellation()
            let path = SeratoPath.normalized(record.path)
            guard analysis.scope.conflictingPath(for: SeratoConflictTarget(paths: [path])) == nil else { continue }
            let bytes = PathBytes(record.path)
            guard let candidates = indexed[path], candidates.count == 1, let file = candidates.first,
                  let identifier = file.id, sound.contains(identifier),
                  let baseline = previous[bytes], baseline.count == 1, let old = baseline.first
            else {
                refresh.insert(bytes)
                if let candidates = indexed[path] {
                    reconcile.formUnion(candidates.compactMap(\.id))
                }
                continue
            }
            if SavedSeratoOccurrence(old).metadata != SavedSeratoOccurrence(record).metadata {
                metadata.insert(bytes)
            }
        }
        return LibraryRefreshPlan(indexedFiles: indexedFiles, metadataPaths: metadata, refreshPaths: refresh, reconcileFileIDs: reconcile, evidence: evidence,
                                  subsecondTimes: subsecondTimes.filter { entry in sound.contains(entry.key) })
    }
}
