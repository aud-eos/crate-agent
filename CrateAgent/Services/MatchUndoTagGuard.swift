import Foundation

extension ApplyMusicBrainzMatchPayload {
    /// What undo restores into the audio file's tags: the file's own
    /// pre-match tags, falling back to the row snapshot for older events.
    var fileTagRestoreSnapshot: SeratoMetadata {
        previousFileTags ?? previousMetadata ?? .empty
    }
}

/// The audio-tag side of undoing or redoing a MusicBrainz match (#111).
///
/// Both directions rewrite only the fields the match wrote, moving each
/// between the matched value and the file's pre-match value. While the file
/// still holds one of those two, the rewrite overwrites nothing anyone else
/// wrote: a queued apply that never reached the file leaves the pre-match
/// value, which undo merely rewrites. Any other value is a later edit, ours
/// through a tag write (which deliberately leaves the Serato-mirrored `files`
/// columns alone) or an external tag editor's, so the inverse is refused.
enum MatchUndoTagGuard {
    /// The live read a guarded undo relied on; the undo transaction requires
    /// the file to be unchanged since, so the decision holds at commit.
    struct Read: Sendable {
        let fileID: Int64
        let path: String
        let identity: AudioFileReadIdentity
    }

    struct Request: Sendable {
        let fileID: Int64
        let path: String
        let applied: ApplyMusicBrainzMatchPayload
    }

    /// Reads at most `concurrency` files at a time off the caller's actor, so
    /// undoing a large batch does not hold up other engine work. When several
    /// files are refused, the first request's error is the one thrown.
    static func readAll(_ requests: [Request], reader: @escaping OperationEngine.FileTagReader, concurrency: Int = 4) async throws -> [Read] {
        var outcomes = [Result<Read, Error>?](repeating: nil, count: requests.count)
        try await withThrowingTaskGroup(of: (Int, Result<Read, Error>).self) { group in
            var next = 0
            func startNext() {
                guard next < requests.count else { return }
                let index = next
                let request = requests[index]
                group.addTask {
                    (index, Result(catching: { try read(fileID: request.fileID, path: request.path, applied: request.applied, reader: reader) }))
                }
                next += 1
            }
            for _ in 0 ..< concurrency {
                startNext()
            }
            while let (index, outcome) = try await group.next() {
                outcomes[index] = outcome
                startNext()
            }
        }
        return try outcomes.map { outcome in
            guard let outcome else { throw CancellationError() }
            return try outcome.get()
        }
    }

    static func read(fileID: Int64, path: String, applied: ApplyMusicBrainzMatchPayload,
                     reader: OperationEngine.FileTagReader) throws -> Read
    {
        let identity: AudioFileReadIdentity
        do { identity = try AudioFileReadIdentity.read(at: path) }
        catch let error as CocoaError where [.fileReadNoSuchFile, .fileReadUnsupportedScheme].contains(error.code) {
            throw OperationEngineError.undoFileUnavailable(fileId: fileID, path: path)
        }
        let live = try reader(path)
        try identity.requireUnchanged(at: path)
        let conflicts = conflictingFields(live: live, applied: applied)
        guard conflicts.isEmpty else {
            throw OperationEngineError.undoWouldOverwriteFileTags(fileId: fileID, fields: conflicts)
        }
        return Read(fileID: fileID, path: path, identity: identity)
    }

    /// The fields the inverse would rewrite whose live value is neither end
    /// of the match's change. Absent and empty text are the same tag value.
    static func conflictingFields(live: AudioTags, applied: ApplyMusicBrainzMatchPayload) -> [String] {
        let restored = applied.fileTagRestoreSnapshot
        let textFields: [(name: String, written: String?, restored: String?, live: String?)] = [
            ("artist", applied.artist, restored.artist, live.artist),
            ("title", applied.title, restored.title, live.title),
            ("album", applied.album, restored.album, live.album),
        ]
        var conflicts = textFields.compactMap { field -> String? in
            guard let written = field.written else { return nil }
            let ends = Set([written, field.restored ?? ""])
            return ends.contains(field.live ?? "") ? nil : field.name
        }
        if let year = applied.year {
            let ends: Set<Int?> = [year, applied.previousFileYear]
            if !ends.contains(live.year.map(Int.init)) {
                conflicts.append("year")
            }
        }
        return conflicts
    }
}
