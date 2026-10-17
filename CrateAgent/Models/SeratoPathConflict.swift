import Foundation

struct ConflictPhysicalIdentity: Hashable, Sendable {
    let volumeID: String
    let inode: UInt64

    init(volumeID: String, inode: UInt64) {
        self.volumeID = volumeID
        self.inode = inode
    }

    init(_ file: some SeratoConflictTargetFile) {
        self.init(volumeID: file.volumeUuid, inode: UInt64(bitPattern: file.inode))
    }
}

/// The file fields a Serato path-conflict lookup reads.
public protocol SeratoConflictTargetFile {
    var id: Int64? { get }
    var path: String { get }
    var volumeUuid: String { get }
    var inode: Int64 { get }
}

extension FileRecord: SeratoConflictTargetFile {}

struct SeratoConflictTarget: Sendable {
    var fileIDs: Set<Int64> = []
    var paths: [String] = []
    var physicalIdentities: Set<ConflictPhysicalIdentity> = []
    var sharedTrackIDs: Set<Int64> = []

    mutating func include(_ file: some SeratoConflictTargetFile) {
        if let fileID = file.id {
            fileIDs.insert(fileID)
        }
        paths.append(file.path)
        if file.volumeUuid != LegacyFileIdentity.unknownVolume {
            physicalIdentities.insert(ConflictPhysicalIdentity(file))
        }
    }

    static func file(_ file: some SeratoConflictTargetFile) -> Self {
        var target = Self()
        target.include(file)
        return target
    }
}

struct SeratoConflictScope: Sendable {
    var fileGroups: [Int64: String] = [:]
    var pathGroups: [String: String] = [:]
    var physicalGroups: [ConflictPhysicalIdentity: String] = [:]
    var trackGroups: [Int64: String] = [:]

    var isEmpty: Bool {
        fileGroups.isEmpty && pathGroups.isEmpty && physicalGroups.isEmpty && trackGroups.isEmpty
    }

    var fileIDs: Set<Int64> {
        Set(fileGroups.keys)
    }

    var normalizedPaths: Set<String> {
        Set(pathGroups.keys)
    }

    var physicalIdentities: Set<ConflictPhysicalIdentity> {
        Set(physicalGroups.keys)
    }

    var sharedTrackIDs: Set<Int64> {
        Set(trackGroups.keys)
    }

    func conflictingPath(for target: SeratoConflictTarget) -> String? {
        var matches = target.fileIDs.compactMap { fileID in fileGroups[fileID] }
        matches += target.paths.compactMap { path in pathGroups[SeratoPath.normalized(path)] }
        matches += target.physicalIdentities.compactMap { identity in physicalGroups[identity] }
        matches += target.sharedTrackIDs.compactMap { trackID in trackGroups[trackID] }
        return matches.min()
    }

    mutating func protect(_ target: SeratoConflictTarget, group: String) {
        for fileID in target.fileIDs {
            fileGroups[fileID] = min(fileGroups[fileID] ?? group, group)
        }
        for path in target.paths {
            let normalized = SeratoPath.normalized(path)
            pathGroups[normalized] = min(pathGroups[normalized] ?? group, group)
        }
        for identity in target.physicalIdentities {
            physicalGroups[identity] = min(physicalGroups[identity] ?? group, group)
        }
        for trackID in target.sharedTrackIDs {
            trackGroups[trackID] = min(trackGroups[trackID] ?? group, group)
        }
    }
}

enum ConflictPathObservation: Sendable, Equatable {
    case existing(ConflictPhysicalIdentity)
    case missing
    case inaccessible
    case offline
    case unknown
    case failed(String)
}

struct SeratoConflictOccurrence: Identifiable, Sendable {
    let id: Int
    let record: SeratoTrackRecord
    let rawPathBytes: Data
    let observation: ConflictPathObservation
}

/// A file whose Serato rename is still queued: Serato's record is expected at
/// `savedPath` until the rename applies.
struct PendingRenameSource: Sendable, Equatable {
    let fileID: Int64
    let savedPath: String
    let currentPath: String
}

struct SeratoPathConflict: Identifiable, Sendable {
    let id: String
    let occurrences: [SeratoConflictOccurrence]
    let fileIDs: Set<Int64>
}

struct SeratoConflictAnalysis: Sendable {
    let source: SeratoSourceIdentity
    let libraryID: String
    let generation: UInt64
    let conflicts: [SeratoPathConflict]
    let scope: SeratoConflictScope

    func validate(_ snapshot: SeratoMembershipSnapshot) throws {
        guard source == snapshot.source, libraryID == snapshot.libraryID, generation == snapshot.generation else {
            throw SeratoMembershipSnapshotError.sourceChanged
        }
    }
}
