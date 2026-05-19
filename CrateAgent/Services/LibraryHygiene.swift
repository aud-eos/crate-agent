import Foundation

/// SP-1.5's library hygiene primitives. Pure-logic functions that
/// scan the library for issues and produce structured fix lists
/// the UI can preview and the operation engine can apply.
///
/// Today: leading/trailing whitespace detection only. The interface
/// is shaped to accept future analyzers (case-inconsistency,
/// find-and-replace, missing fields) under the same scan → preview →
/// apply pattern, all routing through the existing `setMetadata` +
/// `commitMetadataToSerato` mutations so undo + history come for
/// free per Rules 1 and 2.
public enum LibraryHygiene {

    /// One field on one file needs a value rewrite. The display
    /// captures both old and new so the UI can render diff badges
    /// without re-running the analyzer.
    public struct WhitespaceIssue: Sendable, Equatable, Identifiable {
        public let fileId: Int64
        public let path: String
        public let field: SeratoMetadataField
        public let oldValue: String
        public let newValue: String

        public var id: String { "\(fileId):\(field.rawValue)" }
    }

    /// Scan the file list for trim-worthy whitespace in any text
    /// metadata field. A "trim" is the canonical reading: drop
    /// leading + trailing characters in `.whitespacesAndNewlines`.
    /// Internal whitespace is preserved — "Aphex   Twin" (collapsed
    /// double-space) is a separate concern (case/style normalization)
    /// and lives in a future analyzer.
    public static func findWhitespaceIssues(in files: [FileRecord]) -> [WhitespaceIssue] {
        var issues: [WhitespaceIssue] = []
        for file in files {
            guard let fileId = file.id else { continue }
            for field in SeratoMetadataField.allCases {
                let rawValue = field.read(from: file)
                guard let raw = rawValue, !raw.isEmpty else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != raw {
                    issues.append(WhitespaceIssue(
                        fileId: fileId,
                        path: file.path,
                        field: field,
                        oldValue: raw,
                        newValue: trimmed
                    ))
                }
            }
        }
        return issues
    }

    /// Build the trimmed SeratoMetadata snapshot for a single file
    /// given the issues against it. Used by the runner to compose
    /// one `setMetadata` payload per file regardless of how many
    /// fields needed trimming.
    public static func mergedTrimmedMetadata(
        forFile file: FileRecord,
        issues: [WhitespaceIssue]
    ) -> SeratoMetadata {
        var artist = file.artist
        var title = file.title
        var album = file.album
        var genre = file.genre
        var bpm = file.bpm
        var musicalKey = file.musicalKey
        var comment = file.comment
        var length = file.length
        var label = file.label
        for issue in issues where issue.fileId == file.id {
            switch issue.field {
            case .artist: artist = issue.newValue
            case .title: title = issue.newValue
            case .album: album = issue.newValue
            case .genre: genre = issue.newValue
            case .bpm: bpm = issue.newValue
            case .musicalKey: musicalKey = issue.newValue
            case .comment: comment = issue.newValue
            case .length: length = issue.newValue
            case .label: label = issue.newValue
            }
        }
        return SeratoMetadata(
            artist: artist,
            title: title,
            album: album,
            genre: genre,
            bpm: bpm,
            musicalKey: musicalKey,
            comment: comment,
            length: length,
            label: label
        )
    }
}

/// One of the user-editable text fields on a Serato track record.
/// CaseIterable so the analyzer can sweep every field without
/// hard-coding the list at the call site.
public enum SeratoMetadataField: String, CaseIterable, Sendable {
    case artist
    case title
    case album
    case genre
    case bpm
    case musicalKey
    case comment
    case length
    case label

    public func read(from file: FileRecord) -> String? {
        switch self {
        case .artist: return file.artist
        case .title: return file.title
        case .album: return file.album
        case .genre: return file.genre
        case .bpm: return file.bpm
        case .musicalKey: return file.musicalKey
        case .comment: return file.comment
        case .length: return file.length
        case .label: return file.label
        }
    }

    /// User-facing label. Stable across UI surfaces so the same
    /// term shows in the analyzer, the rename dialog hint, and the
    /// settings preview.
    public var displayName: String {
        switch self {
        case .artist: return "Artist"
        case .title: return "Title"
        case .album: return "Album"
        case .genre: return "Genre"
        case .bpm: return "BPM"
        case .musicalKey: return "Key"
        case .comment: return "Comment"
        case .length: return "Length"
        case .label: return "Label"
        }
    }
}

/// Applies a batch of whitespace fixes through the OperationEngine.
/// Each file in the issue set gets one `setMetadata` +
/// `commitMetadataToSerato` mutation pair under a shared `batch_id`
/// so a single Undo on the History view reverts the entire cleanup.
public actor LibraryHygieneRunner {

    private let operationEngine: OperationEngine

    public init(operationEngine: OperationEngine) {
        self.operationEngine = operationEngine
    }

    @discardableResult
    public func applyWhitespaceFixes(
        _ issues: [LibraryHygiene.WhitespaceIssue],
        files: [FileRecord],
        batchId: String? = nil
    ) async throws -> String {
        guard !issues.isEmpty else { return batchId ?? "" }

        let effectiveBatchId = batchId ?? "hygiene-whitespace-\(UUID().uuidString)"
        let issuesByFileId = Dictionary(grouping: issues, by: \.fileId)
        let filesById = Dictionary(uniqueKeysWithValues: files.compactMap { file -> (Int64, FileRecord)? in
            guard let identifier = file.id else { return nil }
            return (identifier, file)
        })

        for (fileId, fileIssues) in issuesByFileId {
            guard let file = filesById[fileId] else { continue }
            let merged = LibraryHygiene.mergedTrimmedMetadata(
                forFile: file,
                issues: fileIssues
            )
            // The pre-hygiene snapshot — needed as `previousMetadata`
            // on the Serato commit so undo can re-issue the commit
            // with the un-trimmed values. Read straight from the
            // FileRecord we have in hand; the row reflects the
            // state Serato also holds at this moment because the
            // bi-directional sync keeps them aligned.
            let previousSnapshot = SeratoMetadata(
                artist: file.artist,
                title: file.title,
                album: file.album,
                genre: file.genre,
                bpm: file.bpm,
                musicalKey: file.musicalKey,
                comment: file.comment,
                length: file.length,
                label: file.label
            )
            try await operationEngine.apply(
                .setMetadata(SetMetadataPayload(fileId: fileId, metadata: merged)),
                batchId: effectiveBatchId
            )
            try await operationEngine.apply(
                .commitMetadataToSerato(CommitMetadataToSeratoPayload(
                    fileId: fileId,
                    metadata: merged,
                    previousMetadata: previousSnapshot
                )),
                batchId: effectiveBatchId
            )
        }

        return effectiveBatchId
    }
}
