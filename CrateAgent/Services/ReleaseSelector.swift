import Foundation

/// Picks the release to default a `MatchCandidate`'s album field to,
/// among a recording's releases. Pure logic, no I/O.
///
/// This is an ALBUM-selection heuristic only — the YEAR shown to the user
/// comes from `MBRecording.releaseGroup.firstReleaseDate` (the earliest
/// release-group across all releases), which is fixed independent of
/// which release is chosen here. Task 13 seeds a candidate's
/// `chosenRelease` with this pick; the review UI lets the user override
/// it to any of `availableReleases`.
///
/// Selection order:
/// 1. A release whose `title` case-insensitively matches `existingAlbum`
///    (the tag already on the file) — respects what the user already had.
/// 2. Else the earliest release with `status == "Official"` — prefer a
///    real retail release over promos/bootlegs.
/// 3. Else the earliest release regardless of status.
/// 4. Else the first element, when nothing above disambiguates.
///
/// Returns `nil` only when `releases` is empty.
public enum ReleaseSelector {
    public static func defaultRelease(from releases: [MBRelease], existingAlbum: String?) -> MBRelease? {
        guard !releases.isEmpty else { return nil }

        if let existingAlbum,
           let matchingRelease = releases.first(where: { $0.title.caseInsensitiveCompare(existingAlbum) == .orderedSame })
        {
            return matchingRelease
        }

        let officialReleases = releases.filter { $0.status == "Official" }
        if let earliestOfficial = earliestByDate(officialReleases) {
            return earliestOfficial
        }

        return earliestByDate(releases) ?? releases.first
    }

    /// The earliest release by `date`, tolerant of partial dates (see
    /// `parsedMusicBrainzDateValue`). A release with a missing or
    /// unparsable date sorts last, so it never wins over a dated one.
    /// `nil` when `releases` is empty.
    private static func earliestByDate(_ releases: [MBRelease]) -> MBRelease? {
        releases.min { lhs, rhs in
            sortableDate(lhs) < sortableDate(rhs)
        }
    }

    private static func sortableDate(_ release: MBRelease) -> Int {
        release.date.flatMap(parsedMusicBrainzDateValue) ?? .max
    }
}
