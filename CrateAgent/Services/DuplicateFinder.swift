import Foundation

/// SP-1.5 audit tool: detects duplicate audio files in the library.
/// Read-only — does not delete, move, or modify anything. The user
/// resolves duplicates manually via Finder (or via a future
/// "consolidate Serato references onto the keeper" action).
///
/// Two detection modes:
///
/// - **Byte-level**: groups files that are byte-equivalent. Match
///   condition: same `file_size` AND same `lightweight_hash`. Picks
///   up the classic "copied the same MP3 into two folders" case.
///   The lightweight hash (SHA-256 of first 1MB + last 1MB) was
///   populated for cross-volume move detection in #13; it doubles
///   as the duplicate-detection primitive here at zero extra cost.
///
/// - **Perceptual**: groups files that are the same *recording*,
///   even at different bitrates or in different formats. Match
///   condition: same `chromaprint_fingerprint`. Chromaprint by
///   design produces stable hashes across re-encodings of the same
///   audio. Result only meaningful for files where the
///   FingerprintWorker has produced a fingerprint
///   (`fingerprint_status = 'done'`); pending / failed rows are
///   excluded from perceptual grouping.
public enum DuplicateFinder {
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        case byteLevel
        case perceptual

        public var displayName: String {
            switch self {
            case .byteLevel: return "Byte-level"
            case .perceptual: return "Perceptual"
            }
        }
    }

    /// One cluster of files that match each other under the current
    /// detection mode. `files` is sorted by path for deterministic
    /// UI rendering.
    public struct DuplicateGroup: Sendable, Equatable, Identifiable {
        public let groupKey: String
        public let mode: Mode
        public let files: [FileRecord]

        public var id: String {
            "\(mode.rawValue):\(groupKey)"
        }

        public var size: Int {
            files.count
        }
    }

    /// Find groups according to `mode`. Files that don't have the
    /// necessary fields populated (e.g., no lightweight_hash, or no
    /// chromaprint_fingerprint in perceptual mode) are silently
    /// excluded from grouping — they simply can't be matched, so
    /// listing them as "non-duplicates" would be misleading.
    /// Singleton groups (one file with a key no other shares) are
    /// dropped from the result.
    public static func findDuplicates(
        in files: [FileRecord],
        mode: Mode
    ) -> [DuplicateGroup] {
        var bucketed: [String: [FileRecord]] = [:]
        for file in files {
            guard let key = groupKey(for: file, mode: mode) else { continue }
            bucketed[key, default: []].append(file)
        }
        return bucketed
            .filter { $0.value.count >= 2 }
            .map { key, members in
                DuplicateGroup(
                    groupKey: key,
                    mode: mode,
                    files: members.sorted { $0.path < $1.path }
                )
            }
            // Sort groups by descending size then by groupKey for
            // a deterministic, "biggest issues first" layout.
            .sorted { lhs, rhs in
                if lhs.size != rhs.size {
                    return lhs.size > rhs.size
                }
                return lhs.groupKey < rhs.groupKey
            }
    }

    /// How many files in `files` could in principle participate in
    /// perceptual matching. Useful for the UI's "X of Y
    /// fingerprinted" status badge so the user understands a low
    /// duplicate count might mean fingerprinting is still in
    /// progress rather than zero duplicates.
    public static func fingerprintCoverage(in files: [FileRecord]) -> (done: Int, total: Int) {
        let total = files.count
        let done = files.reduce(into: 0) { count, file in
            if file.fingerprintStatus == .done, file.chromaprintFingerprint != nil {
                count += 1
            }
        }
        return (done: done, total: total)
    }

    // MARK: - Internals (testable)

    /// Per-mode group key for a single file. Returns nil when the
    /// file lacks the data needed to participate in the mode.
    static func groupKey(for file: FileRecord, mode: Mode) -> String? {
        switch mode {
        case .byteLevel:
            guard let hash = file.lightweightHash else { return nil }
            // file_size goes in the key so the same hash across
            // different sizes (effectively impossible but cheap
            // belt-and-braces) doesn't false-positive.
            return "\(file.fileSize):\(hash.base64EncodedString())"
        case .perceptual:
            guard file.fingerprintStatus == .done,
                  let fingerprint = file.chromaprintFingerprint else { return nil }
            return fingerprint.base64EncodedString()
        }
    }
}
