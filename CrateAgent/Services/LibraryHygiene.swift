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

    // MARK: - Find and replace

    /// One in-place substitution found by a find/replace scan. Same
    /// scan → preview → apply skeleton as whitespace issues; the
    /// difference is the *user* supplies the rewrite rule rather than
    /// the analyzer deriving it.
    public struct FindAndReplaceMatch: Sendable, Equatable, Identifiable {
        public let fileId: Int64
        public let path: String
        public let field: SeratoMetadataField
        public let oldValue: String
        public let newValue: String

        public var id: String { "\(fileId):\(field.rawValue)" }
    }

    /// Parameters for a find/replace scan. Bundled together so the
    /// pure function signature stays compact and so the parameters
    /// can flow as one Sendable value through the runner.
    public struct FindAndReplaceQuery: Sendable, Equatable {
        public let find: String
        public let replace: String
        public let fields: Set<SeratoMetadataField>
        public let caseSensitive: Bool

        public init(
            find: String,
            replace: String,
            fields: Set<SeratoMetadataField>,
            caseSensitive: Bool
        ) {
            self.find = find
            self.replace = replace
            self.fields = fields
            self.caseSensitive = caseSensitive
        }
    }

    /// Scan the file list for matches against `query`. The match
    /// list is suitable for direct rendering as a preview pane —
    /// each entry already carries the rewritten value so the UI
    /// shows the user exactly what will land if they apply.
    /// Empty find string returns no matches (avoids the "match
    /// everything, rewrite to nothing" footgun).
    public static func findAndReplaceMatches(
        in files: [FileRecord],
        query: FindAndReplaceQuery
    ) -> [FindAndReplaceMatch] {
        guard !query.find.isEmpty else { return [] }
        var matches: [FindAndReplaceMatch] = []
        for file in files {
            guard let fileId = file.id else { continue }
            for field in query.fields {
                guard let raw = field.read(from: file), !raw.isEmpty else { continue }
                let replaced = applyReplacement(
                    to: raw,
                    find: query.find,
                    replace: query.replace,
                    caseSensitive: query.caseSensitive
                )
                if replaced != raw {
                    matches.append(FindAndReplaceMatch(
                        fileId: fileId,
                        path: file.path,
                        field: field,
                        oldValue: raw,
                        newValue: replaced
                    ))
                }
            }
        }
        return matches
    }

    /// Composes a SeratoMetadata snapshot for a single file given
    /// the find/replace matches that apply to it. Mirrors
    /// `mergedTrimmedMetadata` so the runner reuses one mutation
    /// per file regardless of how many fields matched.
    public static func mergedFindReplaceMetadata(
        forFile file: FileRecord,
        matches: [FindAndReplaceMatch]
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
        for match in matches where match.fileId == file.id {
            switch match.field {
            case .artist: artist = match.newValue
            case .title: title = match.newValue
            case .album: album = match.newValue
            case .genre: genre = match.newValue
            case .bpm: bpm = match.newValue
            case .musicalKey: musicalKey = match.newValue
            case .comment: comment = match.newValue
            case .length: length = match.newValue
            case .label: label = match.newValue
            }
        }
        return SeratoMetadata(
            artist: artist, title: title, album: album, genre: genre,
            bpm: bpm, musicalKey: musicalKey, comment: comment,
            length: length, label: label
        )
    }

    /// Internal: case-aware substring replace. Foundation's
    /// `String.replacingOccurrences(of:with:options:)` does the heavy
    /// lifting; we route through here so the call site is uniform
    /// and so the test surface for case-handling is one function.
    static func applyReplacement(
        to subject: String,
        find: String,
        replace: String,
        caseSensitive: Bool
    ) -> String {
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return subject.replacingOccurrences(of: find, with: replace, options: options)
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
            try await applyMergedMetadata(
                fileId: fileId,
                file: file,
                merged: merged,
                batchId: effectiveBatchId
            )
        }

        return effectiveBatchId
    }

    @discardableResult
    public func applyFindAndReplaceFixes(
        _ matches: [LibraryHygiene.FindAndReplaceMatch],
        files: [FileRecord],
        batchId: String? = nil
    ) async throws -> String {
        guard !matches.isEmpty else { return batchId ?? "" }

        let effectiveBatchId = batchId ?? "hygiene-find-replace-\(UUID().uuidString)"
        let matchesByFileId = Dictionary(grouping: matches, by: \.fileId)
        let filesById = Dictionary(uniqueKeysWithValues: files.compactMap { file -> (Int64, FileRecord)? in
            guard let identifier = file.id else { return nil }
            return (identifier, file)
        })

        for (fileId, fileMatches) in matchesByFileId {
            guard let file = filesById[fileId] else { continue }
            let merged = LibraryHygiene.mergedFindReplaceMetadata(
                forFile: file,
                matches: fileMatches
            )
            try await applyMergedMetadata(
                fileId: fileId,
                file: file,
                merged: merged,
                batchId: effectiveBatchId
            )
        }

        return effectiveBatchId
    }

    /// Shared mutation pair: setMetadata (DB) + commitMetadataToSerato
    /// (Serato), both under the same batch so undo reverts together.
    /// The Serato commit captures `previousMetadata` from the file's
    /// pre-fix state so the batch is fully invertible — see PR #21's
    /// engine extension.
    private func applyMergedMetadata(
        fileId: Int64,
        file: FileRecord,
        merged: SeratoMetadata,
        batchId: String
    ) async throws {
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
            batchId: batchId
        )
        try await operationEngine.apply(
            .commitMetadataToSerato(CommitMetadataToSeratoPayload(
                fileId: fileId,
                metadata: merged,
                previousMetadata: previousSnapshot
            )),
            batchId: batchId
        )
    }
}
