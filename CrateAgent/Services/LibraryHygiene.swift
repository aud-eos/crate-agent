import Foundation

/// Shared protocol that both `FileRecord` and `HygieneFileRow`
/// conform to. The analyzers and runner are generic over this so
/// they can accept either a full record (production OperationEngine
/// path; tests) or the lightweight projection used by Library
/// Cleanup panels.
///
/// Fields list = exactly what the analyzers read: id + path + every
/// text metadata column. No BLOBs, no identity fields, no
/// fingerprint state.
public protocol HygieneFileSource {
    var id: Int64? { get }
    var path: String { get }
    var artist: String? { get }
    var title: String? { get }
    var album: String? { get }
    var genre: String? { get }
    var bpm: String? { get }
    var musicalKey: String? { get }
    var comment: String? { get }
    var length: String? { get }
    var label: String? { get }
}

extension FileRecord: HygieneFileSource {}
extension HygieneFileRow: HygieneFileSource {}

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
    public static func findWhitespaceIssues<F: HygieneFileSource>(in files: [F]) -> [WhitespaceIssue] {
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
    public static func findAndReplaceMatches<F: HygieneFileSource>(
        in files: [F],
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
    public static func mergedFindReplaceMetadata<F: HygieneFileSource>(
        forFile file: F,
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

    // MARK: - Case consistency

    /// A group of files whose value in a single field collapses to
    /// the same lowercased string but is spelled with different
    /// cases ("the strokes" vs "The Strokes"). The hygiene UI
    /// presents one group per row with the user picking the
    /// canonical spelling.
    public struct CaseInconsistencyGroup: Sendable, Equatable, Identifiable {
        public let field: SeratoMetadataField
        public let canonicalKey: String  // lowercased identity
        /// All distinct cased spellings observed in this group,
        /// sorted by descending count then alphabetical for
        /// deterministic UI rendering.
        public let variants: [CaseVariant]
        /// Suggested canonical spelling — the most-common variant,
        /// alphabetical tiebreak. Pre-selected in the UI; the user
        /// can override by picking a different variant.
        public let suggestedCanonical: String
        public let totalFiles: Int

        public var id: String { "\(field.rawValue):\(canonicalKey)" }
    }

    public struct CaseVariant: Sendable, Equatable {
        public let value: String       // the cased spelling
        public let count: Int          // how many files use it
        public let fileIds: [Int64]    // files using this variant
    }

    /// Scan for groups where the same field has 2+ different
    /// casings. Returns one CaseInconsistencyGroup per field × per
    /// case-insensitive value with >1 variant; groups with a single
    /// consistent spelling are not reported (nothing to fix).
    public static func findCaseInconsistencies<F: HygieneFileSource>(
        in files: [F]
    ) -> [CaseInconsistencyGroup] {
        var groups: [CaseInconsistencyGroup] = []
        for field in SeratoMetadataField.allCases {
            // (lowercased key) -> (cased spelling -> [fileId])
            var bucketed: [String: [String: [Int64]]] = [:]
            for file in files {
                guard let fileId = file.id else { continue }
                guard let raw = field.read(from: file), !raw.isEmpty else { continue }
                let key = raw.lowercased()
                bucketed[key, default: [:]][raw, default: []].append(fileId)
            }

            for (key, variantsByCasing) in bucketed where variantsByCasing.count > 1 {
                let variants = variantsByCasing
                    .map { CaseVariant(value: $0.key, count: $0.value.count, fileIds: $0.value) }
                    .sorted { lhs, rhs in
                        if lhs.count != rhs.count { return lhs.count > rhs.count }
                        return lhs.value < rhs.value
                    }
                let totalFiles = variants.reduce(0) { $0 + $1.count }
                let suggestedCanonical = variants.first?.value ?? ""
                groups.append(CaseInconsistencyGroup(
                    field: field,
                    canonicalKey: key,
                    variants: variants,
                    suggestedCanonical: suggestedCanonical,
                    totalFiles: totalFiles
                ))
            }
        }
        // Stable cross-field ordering: alphabetical by field then by
        // canonicalKey. Avoids "the row jumped" surprises across
        // re-renders.
        return groups.sorted { lhs, rhs in
            if lhs.field.rawValue != rhs.field.rawValue {
                return lhs.field.rawValue < rhs.field.rawValue
            }
            return lhs.canonicalKey < rhs.canonicalKey
        }
    }

    /// Project a user's resolution (group → chosen canonical value)
    /// onto a flat list of per-file fixes. Returns one entry per
    /// file whose current variant differs from the chosen canonical;
    /// files already using the canonical aren't included.
    public struct CaseFix: Sendable, Equatable, Identifiable {
        public let fileId: Int64
        public let field: SeratoMetadataField
        public let oldValue: String
        public let newValue: String

        public var id: String { "\(fileId):\(field.rawValue)" }
    }

    /// Project per-group canonical choices onto a flat list of
    /// per-file fixes. `canonicalFor` returns the chosen spelling
    /// for a group, or nil if the user opted to leave it alone.
    /// Skips files already on the canonical and files whose live
    /// value has drifted from the variant snapshot (rare but
    /// possible if the user edits in another flow between scan
    /// and apply).
    public static func caseFixes<F: HygieneFileSource>(
        forGroups groups: [CaseInconsistencyGroup],
        canonicalFor: (CaseInconsistencyGroup) -> String?,
        in files: [F]
    ) -> [CaseFix] {
        let filesById = Dictionary(uniqueKeysWithValues: files.compactMap { file -> (Int64, F)? in
            guard let identifier = file.id else { return nil }
            return (identifier, file)
        })
        var fixes: [CaseFix] = []
        for group in groups {
            guard let canonical = canonicalFor(group) else { continue }
            for variant in group.variants where variant.value != canonical {
                for fileId in variant.fileIds {
                    guard let file = filesById[fileId] else { continue }
                    guard let raw = group.field.read(from: file) else { continue }
                    if raw == variant.value {
                        fixes.append(CaseFix(
                            fileId: fileId,
                            field: group.field,
                            oldValue: raw,
                            newValue: canonical
                        ))
                    }
                }
            }
        }
        return fixes
    }

    // MARK: - Missing fields

    /// One file missing a value for a specific field. The fill-in
    /// value isn't part of the entry — it's user-supplied at apply
    /// time, the same way the canonical spelling is user-supplied
    /// for case normalization.
    public struct MissingFieldEntry: Sendable, Equatable, Identifiable {
        public let fileId: Int64
        public let path: String
        public let field: SeratoMetadataField

        public var id: String { "\(fileId):\(field.rawValue)" }
    }

    /// Per-field count of how many files have no value for that
    /// field. Drives the dashboard / "you have N gaps" header in
    /// the UI without paying for the full entry-list scan up-front.
    public struct MissingFieldSummary: Sendable, Equatable, Identifiable {
        public let field: SeratoMetadataField
        public let count: Int

        public var id: String { field.rawValue }
    }

    /// Empty-field detection: a row "is missing" a field when the
    /// trimmed value is empty. Matches the whitespace analyzer's
    /// canonical reading — `" "` counts as missing because it
    /// trims to "".
    static func isMissing(_ raw: String?) -> Bool {
        guard let raw else { return true }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Roll up the count of missing rows per field. One pass over
    /// the file list; cheap enough to run on every tab activation.
    public static func missingFieldSummaries<F: HygieneFileSource>(
        in files: [F]
    ) -> [MissingFieldSummary] {
        var counts: [SeratoMetadataField: Int] = [:]
        for file in files {
            for field in SeratoMetadataField.allCases {
                if isMissing(field.read(from: file)) {
                    counts[field, default: 0] += 1
                }
            }
        }
        // Stable order matching SeratoMetadataField.allCases so the
        // UI doesn't reorder between renders.
        return SeratoMetadataField.allCases.compactMap { field in
            guard let count = counts[field], count > 0 else { return nil }
            return MissingFieldSummary(field: field, count: count)
        }
    }

    /// Detailed list of every file missing the specified field.
    /// Used to render the preview list once the user has picked a
    /// field to fill. Sorted by path for deterministic UI ordering.
    public static func missingFieldEntries<F: HygieneFileSource>(
        forField field: SeratoMetadataField,
        in files: [F]
    ) -> [MissingFieldEntry] {
        files.compactMap { file -> MissingFieldEntry? in
            guard let fileId = file.id else { return nil }
            guard isMissing(field.read(from: file)) else { return nil }
            return MissingFieldEntry(fileId: fileId, path: file.path, field: field)
        }
        .sorted { $0.path < $1.path }
    }

    /// Compose the SeratoMetadata snapshot for one file when filling
    /// in a missing field. Sets exactly one field on the otherwise-
    /// preserved snapshot.
    public static func mergedMissingFieldMetadata<F: HygieneFileSource>(
        forFile file: F,
        field: SeratoMetadataField,
        value: String
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
        switch field {
        case .artist: artist = value
        case .title: title = value
        case .album: album = value
        case .genre: genre = value
        case .bpm: bpm = value
        case .musicalKey: musicalKey = value
        case .comment: comment = value
        case .length: length = value
        case .label: label = value
        }
        return SeratoMetadata(
            artist: artist, title: title, album: album, genre: genre,
            bpm: bpm, musicalKey: musicalKey, comment: comment,
            length: length, label: label
        )
    }

    /// Compose the SeratoMetadata snapshot for one file given the
    /// case fixes against it. Same shape as the other mergedXxx
    /// helpers so the runner can route through `applyMergedMetadata`.
    public static func mergedCaseMetadata<F: HygieneFileSource>(
        forFile file: F,
        fixes: [CaseFix]
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
        for fix in fixes where fix.fileId == file.id {
            switch fix.field {
            case .artist: artist = fix.newValue
            case .title: title = fix.newValue
            case .album: album = fix.newValue
            case .genre: genre = fix.newValue
            case .bpm: bpm = fix.newValue
            case .musicalKey: musicalKey = fix.newValue
            case .comment: comment = fix.newValue
            case .length: length = fix.newValue
            case .label: label = fix.newValue
            }
        }
        return SeratoMetadata(
            artist: artist, title: title, album: album, genre: genre,
            bpm: bpm, musicalKey: musicalKey, comment: comment,
            length: length, label: label
        )
    }

    /// Build the trimmed SeratoMetadata snapshot for a single file
    /// given the issues against it. Used by the runner to compose
    /// one `setMetadata` payload per file regardless of how many
    /// fields needed trimming.
    public static func mergedTrimmedMetadata<F: HygieneFileSource>(
        forFile file: F,
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

    public func read<F: HygieneFileSource>(from file: F) -> String? {
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
    public func applyWhitespaceFixes<F: HygieneFileSource>(
        _ issues: [LibraryHygiene.WhitespaceIssue],
        files: [F],
        batchId: String? = nil
    ) async throws -> String {
        guard !issues.isEmpty else { return batchId ?? "" }

        let effectiveBatchId = batchId ?? "hygiene-whitespace-\(UUID().uuidString)"
        let issuesByFileId = Dictionary(grouping: issues, by: \.fileId)
        let filesById = Dictionary(uniqueKeysWithValues: files.compactMap { file -> (Int64, F)? in
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
    public func applyFindAndReplaceFixes<F: HygieneFileSource>(
        _ matches: [LibraryHygiene.FindAndReplaceMatch],
        files: [F],
        batchId: String? = nil
    ) async throws -> String {
        guard !matches.isEmpty else { return batchId ?? "" }

        let effectiveBatchId = batchId ?? "hygiene-find-replace-\(UUID().uuidString)"
        let matchesByFileId = Dictionary(grouping: matches, by: \.fileId)
        let filesById = Dictionary(uniqueKeysWithValues: files.compactMap { file -> (Int64, F)? in
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

    @discardableResult
    public func applyCaseFixes<F: HygieneFileSource>(
        _ fixes: [LibraryHygiene.CaseFix],
        files: [F],
        batchId: String? = nil
    ) async throws -> String {
        guard !fixes.isEmpty else { return batchId ?? "" }

        let effectiveBatchId = batchId ?? "hygiene-case-\(UUID().uuidString)"
        let fixesByFileId = Dictionary(grouping: fixes, by: \.fileId)
        let filesById = Dictionary(uniqueKeysWithValues: files.compactMap { file -> (Int64, F)? in
            guard let identifier = file.id else { return nil }
            return (identifier, file)
        })

        for (fileId, fileFixes) in fixesByFileId {
            guard let file = filesById[fileId] else { continue }
            let merged = LibraryHygiene.mergedCaseMetadata(
                forFile: file,
                fixes: fileFixes
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

    /// Set the same value on `field` across every file in `fileIds`
    /// — bulk fill for missing fields. The runner trims the
    /// supplied value (whitespace-only fills would be a no-op), and
    /// skips files whose live value is already non-missing (the
    /// scan-vs-apply race could otherwise overwrite a real value
    /// the user typed in elsewhere between scan and apply).
    @discardableResult
    public func applyMissingFieldFill<F: HygieneFileSource>(
        field: SeratoMetadataField,
        value: String,
        fileIds: [Int64],
        files: [F],
        batchId: String? = nil
    ) async throws -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty, !fileIds.isEmpty else {
            return batchId ?? ""
        }

        let effectiveBatchId = batchId ?? "hygiene-missing-\(UUID().uuidString)"
        let filesById = Dictionary(uniqueKeysWithValues: files.compactMap { file -> (Int64, F)? in
            guard let identifier = file.id else { return nil }
            return (identifier, file)
        })

        for fileId in fileIds {
            guard let file = filesById[fileId] else { continue }
            guard LibraryHygiene.isMissing(field.read(from: file)) else {
                // Field acquired a value since the scan (manual
                // edit elsewhere, Serato exit reload, etc.). Skip
                // rather than clobber.
                continue
            }
            let merged = LibraryHygiene.mergedMissingFieldMetadata(
                forFile: file,
                field: field,
                value: trimmedValue
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

    /// Shared mutation triple: setMetadata (crate-agent DB) +
    /// commitMetadataToSerato (Serato's database V2) + writeFileTags
    /// (the audio file's embedded ID3v2.4 / Vorbis / iTunes tags).
    /// All three under the same batch_id so a single Undo from
    /// History reverts the file tags, the Serato snapshot, and the
    /// DB row in lockstep.
    ///
    /// All three carry the pre-fix `previousMetadata` so each is
    /// individually invertible — see the matching engine extensions.
    private func applyMergedMetadata<F: HygieneFileSource>(
        fileId: Int64,
        file: F,
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
        try await operationEngine.apply(
            .writeFileTags(WriteFileTagsPayload(
                fileId: fileId,
                metadata: merged,
                previousMetadata: previousSnapshot
            )),
            batchId: batchId
        )
    }
}
