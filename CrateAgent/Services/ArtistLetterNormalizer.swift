import Foundation

/// Maps an artist name to the hardcoded folder bucket (Invariant 5).
///
/// The mapping is the single source of truth — every consumer asks the
/// normalizer rather than reimplementing the rules — so adding edge
/// cases (Unicode, hieroglyphic artist names, etc.) means extending
/// this enum, not escaping the bucketing scheme.
///
/// Rules (in order):
///   1. Trim whitespace
///   2. Strip a single leading article ("The ", "A ", "An ") — case-
///      insensitive
///   3. Examine the first remaining character:
///       - ASCII digit → the shared numeric bucket
///       - common leetspeak symbol → visual-equivalent letter
///         (`$uicideboy$` → `S`)
///       - anything else: skip non-alphanumeric leaders until a letter
///         or ASCII digit appears
///   4. Uppercase whatever letter we landed on
///   5. Fallback bucket: `#` (used for tracks where no letter survives —
///      tilde-prefixed, pure-symbol, or empty artist strings)
public enum ArtistLetterNormalizer {
    public static let unknownBucket = "#"
    public static let numericBucket = "_0123456789"

    /// Articles stripped from the start of the artist name. Trailing
    /// space is part of the match so "Anthrax" doesn't lose its "An ".
    private static let leadingArticles: [String] = ["the ", "a ", "an "]

    /// Visual-substitution symbols → letter. Captures the conventions
    /// stylized artist names use (e.g. Suicideboys writing `$uicideboy$`,
    /// Ke$ha, Sw!sh). Extend as edge cases surface; falling through
    /// the table is fine — the next non-symbol/letter handler runs.
    private static let symbolToLetter: [Character: Character] = [
        "$": "S",
        "@": "A",
        "!": "I",
    ]

    public static func bucketName(forArtist rawArtist: String?) -> String {
        let artist = (rawArtist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return unknownBucket }

        let withoutArticle = stripLeadingArticle(from: artist)
        return firstBucketName(in: withoutArticle) ?? unknownBucket
    }

    // MARK: - Internals (testable)

    static func stripLeadingArticle(from artist: String) -> String {
        let lowered = artist.lowercased()
        for article in leadingArticles where lowered.hasPrefix(article) {
            return String(artist.dropFirst(article.count))
        }
        return artist
    }

    static func firstBucketName(in string: String) -> String? {
        for scalar in string.unicodeScalars {
            let character = Character(scalar)

            if scalar.isASCII, CharacterSet.decimalDigits.contains(scalar) {
                return numericBucket
            }

            // Letter: uppercase and return. Handle Unicode by asking
            // the scalar's uppercase form for its first ASCII letter.
            if scalar.properties.isAlphabetic {
                let uppercased = String(character).uppercased()
                if let firstScalar = uppercased.unicodeScalars.first,
                   firstScalar.isASCII,
                   firstScalar.value >= UInt32(UnicodeScalar("A").value),
                   firstScalar.value <= UInt32(UnicodeScalar("Z").value)
                {
                    return String(firstScalar)
                }
                // Non-ASCII letter (e.g., "Ümlaut"): fall back to the
                // raw uppercased character. Latin-1 supplement letters
                // sort outside A–Z but keep them in their natural
                // bucket rather than dumping in #.
                return uppercased.first.map(String.init)
            }

            // Non-alphanumeric symbol: leetspeak substitution if known,
            // else skip and keep scanning.
            if let mapped = symbolToLetter[character] {
                return String(mapped)
            }
        }
        return nil
    }
}
