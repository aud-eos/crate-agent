import Darwin
import Foundation

struct SeratoConflictAnalyzer: Sendable {
    private let inspect: (@Sendable (String) throws -> ConflictPathObservation)?

    init() {
        inspect = nil
    }

    init(inspect: @escaping @Sendable (String) throws -> ConflictPathObservation) {
        self.inspect = inspect
    }

    /// `pendingRenames` adds a conflict for each queued rename whose old and
    /// new paths both hold a saved record: applying the rename would leave two
    /// records for one file, and either one may hold the user's newer edits.
    func analyze(snapshot: SeratoMembershipSnapshot, files: [FileRecord], pendingRenames: [PendingRenameSource] = []) async throws -> SeratoConflictAnalysis {
        var normalizedPaths: [String: String] = [:]
        func normalized(_ path: String) -> String {
            if let cached = normalizedPaths[path] {
                return cached
            }
            let result = SeratoPath.normalized(path)
            normalizedPaths[path] = result
            return result
        }
        var occurrencesByPath: [String: [Int]] = [:]
        for (index, record) in snapshot.records.enumerated() {
            if index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            occurrencesByPath[normalized(record.path), default: []].append(index)
        }
        let duplicatePaths = occurrencesByPath.keys.filter { path in occurrencesByPath[path]!.count > 1 }.sorted()
        let duplicates = Set(duplicatePaths)
        let collisions = pendingRenames.filter { rename in
            let saved = normalized(rename.savedPath)
            let current = normalized(rename.currentPath)
            return saved != current && occurrencesByPath[saved] != nil && occurrencesByPath[current] != nil
                && !duplicates.contains(saved) && !duplicates.contains(current)
        }
        guard !duplicatePaths.isEmpty || !collisions.isEmpty else {
            return SeratoConflictAnalysis(source: snapshot.source, libraryID: snapshot.libraryID, generation: snapshot.generation, conflicts: [], scope: SeratoConflictScope())
        }
        var filesByPath: [String: [Int]] = [:]
        var filesByIdentity: [ConflictPhysicalIdentity: [Int]] = [:]
        for (index, file) in files.enumerated() {
            if index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            filesByPath[normalized(file.path), default: []].append(index)
            if file.volumeUuid != LegacyFileIdentity.unknownVolume {
                filesByIdentity[ConflictPhysicalIdentity(file), default: []].append(index)
            }
        }
        var conflicts: [SeratoPathConflict] = []
        var scope = SeratoConflictScope()
        var observationsByBytes: [PathBytes: ConflictPathObservation] = [:]
        func observe(_ path: String, into target: inout SeratoConflictTarget) throws -> [SeratoConflictOccurrence] {
            let indexedVolumes = Set((filesByPath[path] ?? []).map { index in files[index].volumeUuid }.filter { volume in volume != LegacyFileIdentity.unknownVolume })
            var occurrences: [SeratoConflictOccurrence] = []
            for index in occurrencesByPath[path] ?? [] {
                let record = snapshot.records[index]
                let absolutePath = record.path.hasPrefix("/") ? record.path : "/" + record.path
                let rawPathBytes = Data(record.path.utf8)
                let observation: ConflictPathObservation
                if let cached = observationsByBytes[PathBytes(bytes: rawPathBytes)] {
                    observation = cached
                } else {
                    do {
                        if let inspect {
                            observation = try inspect(absolutePath)
                        } else {
                            observation = try Self.inspectPath(absolutePath, volumeID: indexedVolumes.count == 1 ? indexedVolumes.first : nil)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { observation = .failed(error.localizedDescription) }
                    observationsByBytes[PathBytes(bytes: rawPathBytes)] = observation
                }
                if case let .existing(identity) = observation {
                    target.physicalIdentities.insert(identity)
                }
                occurrences.append(SeratoConflictOccurrence(id: index, record: record, rawPathBytes: rawPathBytes, observation: observation))
            }
            return occurrences
        }
        for collision in collisions {
            try Task.checkCancellation()
            let saved = normalized(collision.savedPath)
            let current = normalized(collision.currentPath)
            var target = SeratoConflictTarget(fileIDs: [collision.fileID], paths: [saved, current])
            let occurrences = try observe(saved, into: &target) + observe(current, into: &target)
            for index in (filesByPath[saved] ?? []) + (filesByPath[current] ?? []) {
                target.include(files[index])
            }
            scope.protect(target, group: current)
            conflicts.append(SeratoPathConflict(id: current, occurrences: occurrences, fileIDs: target.fileIDs, renameSource: collision.savedPath))
        }
        for path in duplicatePaths {
            try Task.checkCancellation()
            var target = SeratoConflictTarget(paths: [path])
            let occurrences = try observe(path, into: &target)
            var candidates = filesByPath[path] ?? []
            for identity in target.physicalIdentities {
                candidates += filesByIdentity[identity] ?? []
            }
            var expandedPaths: Set<String> = [path]
            var expandedIdentities = target.physicalIdentities
            var visited = Set<Int>()
            var cursor = 0
            while cursor < candidates.count {
                let index = candidates[cursor]
                cursor += 1
                guard visited.insert(index).inserted else { continue }
                let file = files[index]
                target.include(file)
                if let trackID = file.trackId {
                    target.sharedTrackIDs.insert(trackID)
                }
                let normalizedPath = normalized(file.path)
                if expandedPaths.insert(normalizedPath).inserted {
                    candidates += filesByPath[normalizedPath] ?? []
                }
                let identity = ConflictPhysicalIdentity(file)
                if expandedIdentities.insert(identity).inserted {
                    candidates += filesByIdentity[identity] ?? []
                }
            }
            scope.protect(target, group: path)
            conflicts.append(SeratoPathConflict(id: path, occurrences: occurrences, fileIDs: target.fileIDs, renameSource: nil))
        }
        return SeratoConflictAnalysis(source: snapshot.source, libraryID: snapshot.libraryID, generation: snapshot.generation, conflicts: conflicts, scope: scope)
    }

    static func inspectPath(_ path: String, volumeID: String? = nil) throws -> ConflictPathObservation {
        var metadata = stat()
        guard stat(path, &metadata) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR:
                if let volumeID {
                    switch try FileAvailabilityResolver().inspect(path: path, volumeID: volumeID) {
                    case .offline: return .offline
                    case .missing: return .missing
                    case .inaccessible: return .inaccessible
                    case .available, .trashed, .unknown: return .unknown
                    }
                }
                // A missing mount point does not prove that its audio was deleted.
                return path.hasPrefix("/Volumes/") ? .unknown : .missing
            case EACCES, EPERM: return .inaccessible
            default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { return .unknown }
        guard access(path, R_OK) == 0 else { return .inaccessible }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let volumeID = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else { return .unknown }
        return .existing(ConflictPhysicalIdentity(volumeID: volumeID, inode: UInt64(metadata.st_ino)))
    }
}
