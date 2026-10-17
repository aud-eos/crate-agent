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
        let direction: MatchHistoryDirection
        let identity: AudioFileReadIdentity
    }

    struct Request: Sendable {
        let fileID: Int64
        let path: String
        let direction: MatchHistoryDirection
        let applied: ApplyMusicBrainzMatchPayload
    }

    /// Reads at most `concurrency` files at a time off the caller's actor, so
    /// undoing a large batch does not hold up other engine work. Reading stops
    /// at the first refusal; the lowest refused request's error is thrown.
    static func readAll(_ requests: [Request], reader: @escaping OperationEngine.FileTagReader, concurrency: Int = 4) async throws -> [Read] {
        var reads = [Read?](repeating: nil, count: requests.count)
        var refusal: (index: Int, error: Error)?
        try await withThrowingTaskGroup(of: (Int, Result<Read, Error>).self) { group in
            var next = 0
            func startNext() throws {
                try Task.checkCancellation()
                guard refusal == nil, next < requests.count else { return }
                let index = next
                let request = requests[index]
                group.addTask {
                    (index, Result(catching: { try read(request, reader: reader) }))
                }
                next += 1
            }
            for _ in 0 ..< concurrency {
                try startNext()
            }
            while let (index, outcome) = try await group.next() {
                switch outcome {
                case let .success(read): reads[index] = read
                case let .failure(error) where index < refusal?.index ?? .max: refusal = (index, error)
                case .failure: break
                }
                try startNext()
            }
        }
        if let refusal {
            throw refusal.error
        }
        return try reads.map { read in
            guard let read else { throw CancellationError() }
            return read
        }
    }

    static func read(_ request: Request, reader: OperationEngine.FileTagReader) throws -> Read {
        let fileID = request.fileID, path = request.path, direction = request.direction
        let identity = try reaching(fileID: fileID, path: path, direction: direction) { try AudioFileReadIdentity.read(at: path) }
        let read = Read(fileID: fileID, path: path, direction: direction, identity: identity)
        let live: AudioTags
        do { live = try reader(path) }
        catch {
            // A file that vanished mid-read is reported as unavailable, not as a tag-read failure.
            try requireUnchanged(read)
            let reason = access(path, R_OK) == 0 ? "its tags could not be read: \(String(describing: error))" : describing(errno: errno)
            throw OperationEngineError.undoFileUnreadable(fileId: fileID, path: path, reason: reason, direction: direction)
        }
        try requireUnchanged(read)
        let conflicts = conflictingFields(live: live, applied: request.applied)
        guard conflicts.isEmpty else {
            throw OperationEngineError.undoWouldOverwriteFileTags(fileId: fileID, fields: conflicts, direction: direction)
        }
        return read
    }

    /// The file still is the one whose tags were checked.
    static func requireUnchanged(_ read: Read) throws {
        try reaching(fileID: read.fileID, path: read.path, direction: read.direction) { try read.identity.requireUnchanged(at: read.path) }
    }

    /// Maps a failure to reach the file into undo's typed errors: missing is
    /// unavailable, a changed file or link target changed while checking, and
    /// any other failure (permission, I/O, not a regular file) names its reason.
    private static func reaching<Value>(fileID: Int64, path: String, direction: MatchHistoryDirection,
                                        _ body: () throws -> Value) throws -> Value
    {
        do { return try body() }
        catch SeratoMembershipSnapshotError.sourceChanged {
            throw OperationEngineError.undoFileChangedWhileChecking(fileId: fileID, direction: direction)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw OperationEngineError.undoFileUnavailable(fileId: fileID, path: path, direction: direction)
        } catch let error as CocoaError {
            let reason = switch error.code {
            case .fileReadNoPermission: describing(errno: EACCES)
            case .fileReadUnsupportedScheme: "it is not a regular file"
            default: error.localizedDescription
            }
            throw OperationEngineError.undoFileUnreadable(fileId: fileID, path: path, reason: reason, direction: direction)
        } catch let error as POSIXError {
            throw OperationEngineError.undoFileUnreadable(fileId: fileID, path: path, reason: describing(errno: error.code.rawValue), direction: direction)
        }
    }

    private static func describing(errno code: Int32) -> String {
        switch code {
        case EACCES, EPERM: "permission denied"
        default: String(cString: strerror(code))
        }
    }

    /// The fields the inverse would rewrite whose live value is neither end
    /// of the match's change. Absent and empty text are the same tag value.
    static func conflictingFields(live: AudioTags, applied: ApplyMusicBrainzMatchPayload) -> [String] {
        let restored = applied.fileTagRestoreSnapshot
        // A field the match left untouched on disk is not rewritten, so a later edit to it is safe.
        let untouched = applied.fileTagFieldsAlreadyOnDisk ?? []
        let textFields: [(name: String, written: String?, restored: String?, live: String?)] = [
            ("artist", applied.artist, restored.artist, live.artist),
            ("title", applied.title, restored.title, live.title),
            ("album", applied.album, restored.album, live.album),
        ]
        var conflicts = textFields.compactMap { field -> String? in
            guard let written = field.written, !untouched.contains(field.name) else { return nil }
            let ends = Set([written, field.restored ?? ""])
            return ends.contains(field.live ?? "") ? nil : field.name
        }
        if let year = applied.year, !untouched.contains(OperationEngine.fileYearField) {
            let ends: Set<Int?> = [year, applied.previousFileYear]
            if !ends.contains(live.year.map(Int.init)) {
                conflicts.append("year")
            }
        }
        return conflicts
    }
}
