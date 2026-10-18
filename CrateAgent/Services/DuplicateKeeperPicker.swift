import Foundation

/// Ranks the files in a `DuplicateFinder.DuplicateGroup` and picks
/// the one we'd default to keeping if the user resolves the group.
/// Pure logic, no I/O — all inputs are `DuplicateFileSource` columns.
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
/// 3. **Most plays** — the copy Serato History shows was played most
///    is the one the DJ actually uses (`SeratoPlayCountService`).
/// 4. **Oldest mtime** — interpreting "the original copy" as the
///    one that's been on disk the longest. If you'd rather prefer
///    the most-recently-edited copy, flip the comparator.
/// 5. **Lexicographic path** — deterministic last-resort tiebreaker.
public enum DuplicateKeeperPicker {
    /// Pick a default keeper from the group's files. Returns the
    /// file's id; the UI uses this to seed its radio selection and
    /// lets the user override per-group.
    public static func chooseDefaultKeeper(
        for group: DuplicateFinder.DuplicateGroup<some DuplicateFileSource>,
        musicFolder: URL
    ) -> Int64? {
        group.files
            .compactMap { file in
                file.id.map { identifier in (file, identifier) }
            }
            .max { lhs, rhs in
                rank(lhs.0, musicFolder: musicFolder)
                    < rank(rhs.0, musicFolder: musicFolder)
            }?.1
    }

    // MARK: - Ranking (testable)

    /// Total ordering on duplicate candidates. `lhs < rhs` means "rhs is the
    /// stronger keeper candidate." Implemented as a lexicographic
    /// tuple comparison so all five tiers participate; later tiers
    /// only matter when earlier tiers tie.
    static func rank(_ file: some DuplicateFileSource, musicFolder: URL) -> RankKey {
        RankKey(
            qualityTier: qualityTier(for: file),
            bitrate: file.bitrateKbps ?? 0,
            bucketMatches: pathMatchesArtistBucket(file: file, musicFolder: musicFolder),
            playCount: file.seratoPlayCount,
            // Older mtime → higher rank → comes "last" in
            // `.max(by:)` semantics. Negate to invert.
            mtimeRank: -file.mtime,
            invertedPath: file.path // alphabetical earlier = stronger
        )
    }

    /// Format-tier score. Lossless formats rank above lossy ones; all
    /// lossless formats are considered equal (their bitrate field is
    /// meaningless to compare). Unknown extensions rank below lossy.
    static func qualityTier(for file: some DuplicateFileSource) -> Int {
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
        file: some DuplicateFileSource,
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
/// comparison; lexicographic ordering composes the five tiers in
/// priority order.
struct RankKey: Comparable {
    let qualityTier: Int
    let bitrate: Int
    let bucketMatches: Bool
    let playCount: Int
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
        if lhs.playCount != rhs.playCount {
            return lhs.playCount < rhs.playCount
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
