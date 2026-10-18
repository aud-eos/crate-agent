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
    var membershipRevision: Int64 { get }
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
    var seratoYear: String? { get }
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
    public static func normalizedMissingFieldValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One field on one file needs a value rewrite. The display
    /// captures both old and new so the UI can render diff badges
    /// without re-running the analyzer.
    public struct WhitespaceIssue: Sendable, Equatable, Identifiable {
        public let fileId: Int64
        public let path: String
        public let field: SeratoMetadataField
        public let oldValue: String
        public let newValue: String

        public var id: String {
            "\(fileId):\(field.rawValue)"
        }
    }

    /// Scan the file list for trim-worthy whitespace in any text
    /// metadata field. A "trim" is the canonical reading: drop
    /// leading + trailing characters in `.whitespacesAndNewlines`.
    /// Internal whitespace is preserved — "Aphex   Twin" (collapsed
    /// double-space) is a separate concern (case/style normalization)
    /// and lives in a future analyzer.
    public static func findWhitespaceIssues(in files: [some HygieneFileSource]) -> [WhitespaceIssue] {
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

        public var id: String {
            "\(fileId):\(field.rawValue)"
        }
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
        in files: [some HygieneFileSource],
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
        forFile file: some HygieneFileSource,
        matches: [FindAndReplaceMatch]
    ) -> SeratoMetadata {
        var merged = SeratoMetadata(mirroredBy: file)
        for match in matches where match.fileId == file.id {
            merged[keyPath: match.field.metadataKeyPath] = match.newValue
        }
        return merged
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
        public let canonicalKey: String // lowercased identity
        /// All distinct cased spellings observed in this group,
        /// sorted by descending count then alphabetical for
        /// deterministic UI rendering.
        public let variants: [CaseVariant]
        /// Suggested canonical spelling — the most-common variant,
        /// alphabetical tiebreak. Pre-selected in the UI; the user
        /// can override by picking a different variant.
        public let suggestedCanonical: String
        public let totalFiles: Int

        public var id: String {
            "\(field.rawValue):\(canonicalKey)"
        }
    }

    public struct CaseVariant: Sendable, Equatable {
        public let value: String // the cased spelling
        public let count: Int // how many files use it
        public let fileIds: [Int64] // files using this variant
    }

    /// Scan for groups where the same field has 2+ different
    /// casings. Returns one CaseInconsistencyGroup per field × per
    /// case-insensitive value with >1 variant; groups with a single
    /// consistent spelling are not reported (nothing to fix).
    public static func findCaseInconsistencies(
        in files: [some HygieneFileSource]
    ) -> [CaseInconsistencyGroup] {
        var groups: [CaseInconsistencyGroup] = []
        for field in SeratoMetadataField.allCases {
            // (lowercased key) -> (cased spelling -> [fileId])
            var bucketed: [String: [String: [Int64]]] = [:]
            for file in files {
                guard let fileId = file.id, let raw = field.read(from: file), !raw.isEmpty else { continue }
                let key = raw.lowercased()
                bucketed[key, default: [:]][raw, default: []].append(fileId)
            }

            for (key, variantsByCasing) in bucketed where variantsByCasing.count > 1 {
                let variants = variantsByCasing
                    .map { CaseVariant(value: $0.key, count: $0.value.count, fileIds: $0.value) }
                    .sorted { lhs, rhs in
                        if lhs.count != rhs.count {
                            return lhs.count > rhs.count
                        }
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

        public var id: String {
            "\(fileId):\(field.rawValue)"
        }
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
                    guard let file = filesById[fileId], let raw = group.field.read(from: file) else { continue }
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

        public var id: String {
            "\(fileId):\(field.rawValue)"
        }
    }

    /// Per-field count of how many files have no value for that
    /// field. Drives the dashboard / "you have N gaps" header in
    /// the UI without paying for the full entry-list scan up-front.
    public struct MissingFieldSummary: Sendable, Equatable, Identifiable {
        public let field: SeratoMetadataField
        public let count: Int

        public var id: String {
            field.rawValue
        }
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
    public static func missingFieldSummaries(
        in files: [some HygieneFileSource]
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
    public static func missingFieldEntries(
        forField field: SeratoMetadataField,
        in files: [some HygieneFileSource]
    ) -> [MissingFieldEntry] {
        files.compactMap { file -> MissingFieldEntry? in
            guard let fileId = file.id, isMissing(field.read(from: file)) else { return nil }
            return MissingFieldEntry(fileId: fileId, path: file.path, field: field)
        }
        .sorted { $0.path < $1.path }
    }

    /// Compose the SeratoMetadata snapshot for one file when filling
    /// in a missing field. Sets exactly one field on the otherwise-
    /// preserved snapshot.
    public static func mergedMissingFieldMetadata(
        forFile file: some HygieneFileSource,
        field: SeratoMetadataField,
        value: String
    ) -> SeratoMetadata {
        var merged = SeratoMetadata(mirroredBy: file)
        merged[keyPath: field.metadataKeyPath] = value
        return merged
    }

    /// Compose the SeratoMetadata snapshot for one file given the
    /// case fixes against it. Same shape as the other mergedXxx
    /// helpers so the runner can route through `applyMergedMetadata`.
    public static func mergedCaseMetadata(
        forFile file: some HygieneFileSource,
        fixes: [CaseFix]
    ) -> SeratoMetadata {
        var merged = SeratoMetadata(mirroredBy: file)
        for fix in fixes where fix.fileId == file.id {
            merged[keyPath: fix.field.metadataKeyPath] = fix.newValue
        }
        return merged
    }

    /// Build the trimmed SeratoMetadata snapshot for a single file
    /// given the issues against it. Used by the runner to compose
    /// one `setMetadata` payload per file regardless of how many
    /// fields needed trimming.
    public static func mergedTrimmedMetadata(
        forFile file: some HygieneFileSource,
        issues: [WhitespaceIssue]
    ) -> SeratoMetadata {
        var merged = SeratoMetadata(mirroredBy: file)
        for issue in issues where issue.fileId == file.id {
            merged[keyPath: issue.field.metadataKeyPath] = issue.newValue
        }
        return merged
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

    public func read(from file: some HygieneFileSource) -> String? {
        switch self {
        case .artist: file.artist
        case .title: file.title
        case .album: file.album
        case .genre: file.genre
        case .bpm: file.bpm
        case .musicalKey: file.musicalKey
        case .comment: file.comment
        case .length: file.length
        case .label: file.label
        }
    }

    var metadataKeyPath: WritableKeyPath<SeratoMetadata, String?> {
        switch self {
        case .artist: \.artist
        case .title: \.title
        case .album: \.album
        case .genre: \.genre
        case .bpm: \.bpm
        case .musicalKey: \.musicalKey
        case .comment: \.comment
        case .length: \.length
        case .label: \.label
        }
    }

    /// User-facing label. Stable across UI surfaces so the same
    /// term shows in the analyzer, the rename dialog hint, and the
    /// settings preview.
    public var displayName: String {
        switch self {
        case .artist: "Artist"
        case .title: "Title"
        case .album: "Album"
        case .genre: "Genre"
        case .bpm: "BPM"
        case .musicalKey: "Key"
        case .comment: "Comment"
        case .length: "Length"
        case .label: "Label"
        }
    }
}

/// Applies a batch of whitespace fixes through the OperationEngine.
/// Each file in the issue set gets one `setMetadata` +
/// `commitMetadataToSerato` mutation pair under a shared `batch_id`
/// so a single Undo on the History view reverts the entire cleanup.
public actor LibraryHygieneRunner {
    private let operationEngine: OperationEngine
    private let activityLog: ActivityLog?

    public init(
        operationEngine: OperationEngine,
        activityLog: ActivityLog? = nil
    ) {
        self.operationEngine = operationEngine
        self.activityLog = activityLog
    }

    /// Post a status message to the activity log, if one is wired
    /// in. The log is `@MainActor`-isolated; `await`ing the hop
    /// keeps every entry in a consistent order. Existing call sites
    /// without a log (tests, etc.) pay zero cost — the optional is
    /// nil and the call is a no-op.
    private func note(_ message: String) async {
        guard let log = activityLog else { return }
        await log.log(message, category: .hygiene)
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

        await note("Trimming whitespace on \(issues.count) field\(issues.count == 1 ? "" : "s") across \(issuesByFileId.count) file\(issuesByFileId.count == 1 ? "" : "s")…")

        var filesProcessed = 0
        var filesChanged = 0
        for (fileId, fileIssues) in issuesByFileId {
            guard let file = filesById[fileId] else { continue }
            let merged = LibraryHygiene.mergedTrimmedMetadata(
                forFile: file,
                issues: fileIssues
            )
            await note("Trimming \(fileIssues.count) field\(fileIssues.count == 1 ? "" : "s") on \(filenameOnly(file.path))")
            if try await applyMergedMetadata(
                fileId: fileId,
                file: file,
                merged: merged,
                batchId: effectiveBatchId
            ) {
                filesProcessed += 1
            } else {
                filesChanged += 1
            }
        }

        await note("Trimmed whitespace on \(issues.count) field\(issues.count == 1 ? "" : "s") across \(filesProcessed) file\(filesProcessed == 1 ? "" : "s")\(changedNote(filesChanged))")
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

        await note("Applying find/replace across \(matches.count) field\(matches.count == 1 ? "" : "s") in \(matchesByFileId.count) file\(matchesByFileId.count == 1 ? "" : "s")…")

        var filesProcessed = 0
        var filesChanged = 0
        for (fileId, fileMatches) in matchesByFileId {
            guard let file = filesById[fileId] else { continue }
            let merged = LibraryHygiene.mergedFindReplaceMetadata(
                forFile: file,
                matches: fileMatches
            )
            await note("Replacing text in \(fileMatches.count) field\(fileMatches.count == 1 ? "" : "s") on \(filenameOnly(file.path))")
            if try await applyMergedMetadata(
                fileId: fileId,
                file: file,
                merged: merged,
                batchId: effectiveBatchId
            ) {
                filesProcessed += 1
            } else {
                filesChanged += 1
            }
        }

        await note("Replaced text in \(matches.count) field\(matches.count == 1 ? "" : "s") across \(filesProcessed) file\(filesProcessed == 1 ? "" : "s")\(changedNote(filesChanged))")
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

        await note("Normalizing case on \(fixes.count) field\(fixes.count == 1 ? "" : "s") in \(fixesByFileId.count) file\(fixesByFileId.count == 1 ? "" : "s")…")

        var filesProcessed = 0
        var filesChanged = 0
        for (fileId, fileFixes) in fixesByFileId {
            guard let file = filesById[fileId] else { continue }
            let merged = LibraryHygiene.mergedCaseMetadata(
                forFile: file,
                fixes: fileFixes
            )
            await note("Normalizing case on \(fileFixes.count) field\(fileFixes.count == 1 ? "" : "s") on \(filenameOnly(file.path))")
            if try await applyMergedMetadata(
                fileId: fileId,
                file: file,
                merged: merged,
                batchId: effectiveBatchId
            ) {
                filesProcessed += 1
            } else {
                filesChanged += 1
            }
        }

        await note("Normalized case on \(fixes.count) field\(fixes.count == 1 ? "" : "s") across \(filesProcessed) file\(filesProcessed == 1 ? "" : "s")\(changedNote(filesChanged))")
        return effectiveBatchId
    }

    /// Set the same value on `field` across every file in `fileIds`
    /// — bulk fill for missing fields. The runner trims the
    /// supplied value (whitespace-only fills would be a no-op), skips
    /// files whose snapshot already has a value, and skips files whose
    /// metadata changed after the snapshot was taken.
    @discardableResult
    public func applyMissingFieldFill<F: HygieneFileSource>(
        field: SeratoMetadataField,
        value: String,
        fileIds: [Int64],
        files: [F],
        batchId: String? = nil
    ) async throws -> String {
        let trimmedValue = LibraryHygiene.normalizedMissingFieldValue(value)
        guard !trimmedValue.isEmpty, !fileIds.isEmpty else {
            return batchId ?? ""
        }

        let effectiveBatchId = batchId ?? "hygiene-missing-\(UUID().uuidString)"
        let filesById = Dictionary(uniqueKeysWithValues: files.compactMap { file -> (Int64, F)? in
            guard let identifier = file.id else { return nil }
            return (identifier, file)
        })

        await note("Filling \(field.displayName) on \(fileIds.count) file\(fileIds.count == 1 ? "" : "s") with “\(trimmedValue)”…")

        var filesProcessed = 0
        var filesSkipped = 0
        var filesChanged = 0
        for fileId in fileIds {
            guard let file = filesById[fileId] else { continue }
            guard LibraryHygiene.isMissing(field.read(from: file)) else {
                filesSkipped += 1
                continue
            }
            let merged = LibraryHygiene.mergedMissingFieldMetadata(
                forFile: file,
                field: field,
                value: trimmedValue
            )
            await note("Filling \(field.displayName) on \(filenameOnly(file.path))")
            if try await applyMergedMetadata(
                fileId: fileId,
                file: file,
                merged: merged,
                batchId: effectiveBatchId
            ) {
                filesProcessed += 1
            } else {
                filesChanged += 1
            }
        }

        let skippedNote = filesSkipped > 0 ? ", \(filesSkipped) skipped (already populated)" : ""
        await note("Filled \(field.displayName) on \(filesProcessed) file\(filesProcessed == 1 ? "" : "s")\(skippedNote)\(changedNote(filesChanged))")
        return effectiveBatchId
    }

    /// Applies `merged` through `OperationEngine.applyMetadataEdit`. `merged`
    /// was derived from the scan-time snapshot, so the engine rejects the
    /// write if the live row has diverged from it. Returns false for that
    /// file instead of overwriting the newer values.
    private func applyMergedMetadata(
        fileId: Int64,
        file: some HygieneFileSource,
        merged: SeratoMetadata,
        batchId: String
    ) async throws -> Bool {
        let previousSnapshot = SeratoMetadata(mirroredBy: file)
        do {
            try await operationEngine.applyMetadataEdit(fileId: fileId, membershipRevision: file.membershipRevision,
                                                        previous: previousSnapshot, edited: merged, batchId: batchId)
        } catch OperationEngineError.metadataChanged {
            return false
        }
        return true
    }

    private nonisolated func changedNote(_ count: Int) -> String {
        count > 0 ? ", \(count) skipped (changed since scan)" : ""
    }

    private nonisolated func filenameOnly(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
