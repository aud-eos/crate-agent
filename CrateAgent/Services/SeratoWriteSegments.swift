import Foundation

/// One external pass over queued rows: `database V2` metadata updates in one
/// rewrite, consecutive renames in one path batch, consecutive adds of
/// distinct files in one registration, or a single other write. Batched
/// segments hold at most `SeratoWriteSegmenter.maximumEntriesPerSegment` rows.
struct SeratoWriteSegment: Sendable {
    enum Kind: Sendable {
        case metadata
        case renames
        case adds
        case single
    }

    struct Entry: Sendable {
        var write: GuardedSeratoWrite
        let dependency: SeratoQueueDependency
    }

    let kind: Kind
    var entries: [Entry]
}

enum SeratoWriteSegmenter {
    /// Each segment's I/O and its rows' verification and confirmation run in
    /// one writer transaction, so this bounds how long a drain blocks other
    /// writes. At about 1 ms per row plus a ~50 ms rewrite of a production-size
    /// `database V2`, 200 rows keeps that under the 500 ms interaction budget
    /// (#189); a larger backlog pays one more library rewrite per 200 rows.
    static let maximumEntriesPerSegment = 200

    /// Groups eligible rows, given in queue order, into the fewest passes that
    /// keep every file's and path's effects in order. A metadata update joins
    /// the open V2 group unless a rename, add, or V2 removal emitted since that
    /// group opened shares its file or path: moving it ahead of that row would
    /// write the record at a path that does not hold it yet, so it starts a new
    /// group after that row instead.
    static func segments(_ passEntries: [SeratoWriteSegment.Entry]) -> [SeratoWriteSegment] {
        // Across the whole pass, since a chain's rows can fall in different segments.
        let refilled = SeratoWriteEligibility.renamesWithRefilledOldPaths(passEntries.map(\.write))
        let entries = passEntries.map { passEntry in
            var entry = passEntry
            entry.write.oldPathRefilled = entry.write.queueID.map(refilled.contains) == true
            return entry
        }
        var segments: [SeratoWriteSegment] = []
        var openMetadata: Int?
        var pathEffectsSinceOpen = SeratoQueueDependency()
        var openAddTargets = SeratoQueueDependency()
        for entry in entries {
            switch entry.write.write {
            case .metadataUpdate:
                if let index = openMetadata, segments[index].entries.count < maximumEntriesPerSegment,
                   !entry.dependency.intersects(pathEffectsSinceOpen)
                {
                    segments[index].entries.append(entry)
                } else {
                    openMetadata = segments.count
                    pathEffectsSinceOpen = SeratoQueueDependency()
                    segments.append(SeratoWriteSegment(kind: .metadata, entries: [entry]))
                }
            case .rename:
                if let last = segments.indices.last, segments[last].kind == .renames, segments[last].entries.count < maximumEntriesPerSegment {
                    segments[last].entries.append(entry)
                } else {
                    segments.append(SeratoWriteSegment(kind: .renames, entries: [entry]))
                }
                pathEffectsSinceOpen.formUnion(entry.dependency)
            case .addTrack:
                // A second add of the same file must see the first one's
                // confirmation, so it starts a new registration.
                if let last = segments.indices.last, segments[last].kind == .adds, segments[last].entries.count < maximumEntriesPerSegment,
                   !entry.dependency.intersects(openAddTargets)
                {
                    segments[last].entries.append(entry)
                } else {
                    segments.append(SeratoWriteSegment(kind: .adds, entries: [entry]))
                    openAddTargets = SeratoQueueDependency()
                }
                openAddTargets.formUnion(entry.dependency)
                pathEffectsSinceOpen.formUnion(entry.dependency)
            case .removeFromDatabase, .restoreRecords:
                segments.append(SeratoWriteSegment(kind: .single, entries: [entry]))
                pathEffectsSinceOpen.formUnion(entry.dependency)
            case .fileTagWrite, .removeFromCrates, .trashFile, .crateMembership:
                segments.append(SeratoWriteSegment(kind: .single, entries: [entry]))
            }
        }
        return segments
    }
}
