import Foundation

/// One external pass over queued rows: every `database V2` metadata update in
/// one rewrite, consecutive renames in one path batch, or a single other write.
struct SeratoWriteSegment: Sendable {
    enum Kind: Sendable {
        case metadata
        case renames
        case single
    }

    struct Entry: Sendable {
        let write: GuardedSeratoWrite
        let dependency: SeratoQueueDependency
    }

    let kind: Kind
    var entries: [Entry]
}

enum SeratoWriteSegmenter {
    /// Groups eligible rows, given in queue order, into the fewest passes that
    /// keep every file's and path's effects in order. A metadata update joins
    /// the open V2 group unless a rename, add, or V2 removal emitted since that
    /// group opened shares its file or path: moving it ahead of that row would
    /// write the record at a path that does not hold it yet, so it starts a new
    /// group after that row instead.
    static func segments(_ entries: [SeratoWriteSegment.Entry]) -> [SeratoWriteSegment] {
        var segments: [SeratoWriteSegment] = []
        var openMetadata: Int?
        var pathEffectsSinceOpen = SeratoQueueDependency()
        for entry in entries {
            switch entry.write.write {
            case .metadataUpdate:
                if let index = openMetadata, !entry.dependency.intersects(pathEffectsSinceOpen) {
                    segments[index].entries.append(entry)
                } else {
                    openMetadata = segments.count
                    pathEffectsSinceOpen = SeratoQueueDependency()
                    segments.append(SeratoWriteSegment(kind: .metadata, entries: [entry]))
                }
            case .rename:
                if let last = segments.indices.last, segments[last].kind == .renames {
                    segments[last].entries.append(entry)
                } else {
                    segments.append(SeratoWriteSegment(kind: .renames, entries: [entry]))
                }
                pathEffectsSinceOpen.formUnion(entry.dependency)
            case .addTrack, .removeFromDatabase:
                segments.append(SeratoWriteSegment(kind: .single, entries: [entry]))
                pathEffectsSinceOpen.formUnion(entry.dependency)
            case .fileTagWrite, .removeFromCrates, .trashFile:
                segments.append(SeratoWriteSegment(kind: .single, entries: [entry]))
            }
        }
        return segments
    }
}
