import Foundation

/// Ranks the files in a `DuplicateFinder.DuplicateGroup` and picks
/// the one we'd default to keeping if the user resolves the group.
/// Pure logic, no I/O — all inputs are columns already on FileRecord.
///
/// Rules in priority order:
///
/// 1. **Quality** — lossless format > lossy format. Within a format,
///    higher bitrate wins. Lossless formats are all considered equal
///    at the format tier (FLAC == WAV == AIFF == ALAC) — comparing
///    lossless bitrates is meaningless because lossless encoders
///    don't have a fixed bitrate target.
/// 2. **Bucket match** — a file at `<Music>/<Bucket>/...` where
///    `<Bucket>` matches the artist's normalized bucket name (per
///    Invariant 5) is preferred over copies that drifted out of the
///    canonical location.
/// 3. **Oldest mtime** — interpreting "the original copy" as the
///    one that's been on disk the longest. If you'd rather prefer
///    the most-recently-edited copy, flip the comparator.
/// 4. **Lexicographic path** — deterministic last-resort tiebreaker.
public enum DuplicateKeeperPicker {
    /// Pick a default keeper from the group's files. Returns the
    /// file's id; the UI uses this to seed its radio selection and
    /// lets the user override per-group.
    public static func chooseDefaultKeeper(
        for group: DuplicateFinder.DuplicateGroup,
        musicFolder: URL
    ) -> Int64? {
        group.files
            .compactMap { file -> (FileRecord, Int64)? in
                guard let identifier = file.id else { return nil }
                return (file, identifier)
            }
            .max { lhs, rhs in
                rank(lhs.0, musicFolder: musicFolder)
                    < rank(rhs.0, musicFolder: musicFolder)
            }?.1
    }

    // MARK: - Ranking (testable)

    /// Total ordering on FileRecord. `lhs < rhs` means "rhs is the
    /// stronger keeper candidate." Implemented as a lexicographic
    /// tuple comparison so all four tiers participate; later tiers
    /// only matter when earlier tiers tie.
    static func rank(_ file: FileRecord, musicFolder: URL) -> RankKey {
        RankKey(
            qualityTier: qualityTier(for: file),
            bitrate: file.bitrateKbps ?? 0,
            bucketMatches: pathMatchesArtistBucket(file: file, musicFolder: musicFolder),
            // Older mtime → higher rank → comes "last" in
            // `.max(by:)` semantics. Negate to invert.
            mtimeRank: -file.mtime,
            invertedPath: file.path // alphabetical earlier = stronger
        )
    }

    /// Format-tier score. Lossless formats rank above lossy ones; all
    /// lossless formats are considered equal (their bitrate field is
    /// meaningless to compare). Unknown extensions rank below lossy.
    static func qualityTier(for file: FileRecord) -> Int {
        let ext = (file.path as NSString).pathExtension.lowercased()
        if losslessExtensions.contains(ext) {
            return 2
        }
        if lossyExtensions.contains(ext) {
            return 1
        }
        return 0
    }

    static let losslessExtensions: Set<String> = [
        "flac", "wav", "wave", "aif", "aiff", "alac",
    ]

    static let lossyExtensions: Set<String> = [
        "mp3", "m4a", "mp4", "aac",
        "ogg", "oga", "opus",
    ]

    /// True when the file lives at `<musicFolder>/<Bucket>/...` and
    /// `<Bucket>` matches the normalized bucket name for the
    /// file's artist (per Invariant 5). Files outside the watched
    /// folder, files in deeper nested subdirectories, and files
    /// with no recoverable artist all return false.
    static func pathMatchesArtistBucket(
        file: FileRecord,
        musicFolder: URL
    ) -> Bool {
        let musicFolderPath = musicFolder.standardized.path
        let path = file.path
        guard path.hasPrefix(musicFolderPath + "/") else { return false }
        let relative = String(path.dropFirst(musicFolderPath.count + 1))
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2,
              let firstComponent = components.first else { return false }
        let bucketFromPath = firstComponent.uppercased()
        let bucketFromArtist = ArtistLetterNormalizer.bucketName(forArtist: file.artist)
        return bucketFromPath == bucketFromArtist
    }
}

/// Comparable tuple used by `DuplicateKeeperPicker.rank`. Conforming
/// to `Comparable` lets `.max(by:)` callers use a single `<`
/// comparison; lexicographic ordering composes the four tiers in
/// priority order.
struct RankKey: Comparable {
    let qualityTier: Int
    let bitrate: Int
    let bucketMatches: Bool
    let mtimeRank: Int64
    let invertedPath: String

    static func < (lhs: RankKey, rhs: RankKey) -> Bool {
        if lhs.qualityTier != rhs.qualityTier {
            return lhs.qualityTier < rhs.qualityTier
        }
        // Bitrate is only meaningful WITHIN the same quality tier
        // — we don't compare a FLAC's bitrate to an MP3's. The
        // earlier check has them in the same tier; safe to compare.
        if lhs.bitrate != rhs.bitrate {
            return lhs.bitrate < rhs.bitrate
        }
        if lhs.bucketMatches != rhs.bucketMatches {
            // false < true, so "matches" sorts higher (better).
            return !lhs.bucketMatches && rhs.bucketMatches
        }
        if lhs.mtimeRank != rhs.mtimeRank {
            return lhs.mtimeRank < rhs.mtimeRank
        }
        // Final: shorter (or alphabetically earlier) path wins.
        // We invert because .max picks the *greatest* element, so
        // the "better" path must sort higher.
        return lhs.invertedPath > rhs.invertedPath
    }
}
