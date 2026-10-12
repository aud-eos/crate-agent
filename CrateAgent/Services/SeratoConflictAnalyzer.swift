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

    func analyze(snapshot: SeratoMembershipSnapshot, files: [FileRecord]) async throws -> SeratoConflictAnalysis {
        var occurrencesByPath: [String: [Int]] = [:]
        for (index, record) in snapshot.records.enumerated() {
            if index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            occurrencesByPath[SeratoPath.normalized(record.path), default: []].append(index)
        }
        let duplicatePaths = occurrencesByPath.keys.filter { occurrencesByPath[$0]!.count > 1 }.sorted()
        guard !duplicatePaths.isEmpty else {
            return SeratoConflictAnalysis(libraryID: snapshot.libraryID, generation: snapshot.generation, conflicts: [], scope: SeratoConflictScope())
        }
        var filesByPath: [String: [Int]] = [:]
        var filesByIdentity: [ConflictPhysicalIdentity: [Int]] = [:]
        for (index, file) in files.enumerated() {
            if index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            filesByPath[SeratoPath.normalized(file.path), default: []].append(index)
            if file.volumeUuid != LegacyFileIdentity.unknownVolume {
                filesByIdentity[ConflictPhysicalIdentity(file), default: []].append(index)
            }
        }
        var conflicts: [SeratoPathConflict] = []
        var scope = SeratoConflictScope()
        var observationsByBytes: [Data: ConflictPathObservation] = [:]
        for path in duplicatePaths {
            try Task.checkCancellation()
            var target = SeratoConflictTarget(paths: [path])
            var occurrences: [SeratoConflictOccurrence] = []
            let indexedVolumes = Set((filesByPath[path] ?? []).map { files[$0].volumeUuid }.filter { $0 != LegacyFileIdentity.unknownVolume })
            for index in occurrencesByPath[path]! {
                let record = snapshot.records[index]
                let absolutePath = record.path.hasPrefix("/") ? record.path : "/" + record.path
                let rawPathBytes = Data(record.path.utf8)
                let observation: ConflictPathObservation
                if let cached = observationsByBytes[rawPathBytes] {
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
                    observationsByBytes[rawPathBytes] = observation
                }
                if case let .existing(identity) = observation {
                    target.physicalIdentities.insert(identity)
                }
                occurrences.append(SeratoConflictOccurrence(id: index, record: record, rawPathBytes: rawPathBytes, observation: observation))
            }
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
                let normalizedPath = SeratoPath.normalized(file.path)
                if expandedPaths.insert(normalizedPath).inserted {
                    candidates += filesByPath[normalizedPath] ?? []
                }
                let identity = ConflictPhysicalIdentity(file)
                if expandedIdentities.insert(identity).inserted {
                    candidates += filesByIdentity[identity] ?? []
                }
            }
            scope.protect(target, group: path)
            conflicts.append(SeratoPathConflict(id: path, occurrences: occurrences, fileIDs: target.fileIDs))
        }
        return SeratoConflictAnalysis(libraryID: snapshot.libraryID, generation: snapshot.generation, conflicts: conflicts, scope: scope)
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
