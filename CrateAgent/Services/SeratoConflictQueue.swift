import Foundation
import GRDB

enum SeratoConflictQueueDisposition: Sendable, Equatable {
    case eligible
    case blocked
    case superseded
}

struct SeratoQueueDependency: Sendable {
    var fileIDs: Set<Int64> = []
    var eventIDs: Set<Int64> = []
    var normalizedPaths: Set<String> = []
    var physicalIdentities: Set<ConflictPhysicalIdentity> = []
    var sharedTrackIDs: Set<Int64> = []

    init() {}

    init(target: SeratoConflictTarget, eventID: Int64) {
        fileIDs = target.fileIDs
        eventIDs = [eventID]
        normalizedPaths = Set(target.paths.map(SeratoPath.normalized))
        physicalIdentities = target.physicalIdentities
        sharedTrackIDs = target.sharedTrackIDs
    }

    func intersects(_ other: Self) -> Bool {
        !fileIDs.isDisjoint(with: other.fileIDs) || !eventIDs.isDisjoint(with: other.eventIDs)
            || !normalizedPaths.isDisjoint(with: other.normalizedPaths)
            || !physicalIdentities.isDisjoint(with: other.physicalIdentities)
            || !sharedTrackIDs.isDisjoint(with: other.sharedTrackIDs)
    }

    mutating func formUnion(_ other: Self) {
        fileIDs.formUnion(other.fileIDs)
        eventIDs.formUnion(other.eventIDs)
        normalizedPaths.formUnion(other.normalizedPaths)
        physicalIdentities.formUnion(other.physicalIdentities)
        sharedTrackIDs.formUnion(other.sharedTrackIDs)
    }
}

enum SeratoConflictQueue {
    static func classify(_ write: GuardedSeratoWrite, blocked: SeratoQueueDependency,
                         readiness: LibrarySyncReadiness?, in database: GRDB.Database) throws -> (SeratoConflictQueueDisposition, SeratoQueueDependency)
    {
        let target = try SeratoConflictTargets.write(write, in: database)
        let dependency = SeratoQueueDependency(target: target, eventID: write.eventId)
        if readiness?.conflictPath(for: target) != nil || dependency.intersects(blocked) {
            return (.blocked, dependency)
        }
        guard let file = try FileRecord.fetchOne(database, key: write.token.fileId), SeratoWriteEligibility.permits(write, file: file) else {
            return (.superseded, dependency)
        }
        return (.eligible, dependency)
    }

    static func sameIntent(_ first: GuardedSeratoWrite, _ second: GuardedSeratoWrite) -> Bool {
        guard first.eventId == second.eventId else { return false }
        switch (first.write, second.write) {
        case (.rename, .rename), (.metadataUpdate, .metadataUpdate), (.addTrack, .addTrack),
             (.fileTagWrite, .fileTagWrite), (.removeFromDatabase, .removeFromDatabase),
             (.removeFromCrates, .removeFromCrates), (.trashFile, .trashFile), (.restoreRecords, .restoreRecords): return true
        default: return false
        }
    }
}
