import Foundation

/// Maps an artist name to a single alphabetical bucket letter for the
/// folder layout `<MusicFolder>/<Letter>/<filename>.ext` (Invariant 5).
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
///       - digit → spelled-out-form's first letter (`2` → `T` for "Two")
///       - common leetspeak symbol → visual-equivalent letter
///         (`$uicideboy$` → `S`)
///       - anything else: skip non-alphanumeric leaders until a letter
///         appears
///   4. Uppercase whatever letter we landed on
///   5. Fallback bucket: `#` (used for tracks where no letter survives —
///      tilde-prefixed, pure-symbol, or empty artist strings)
public enum ArtistLetterNormalizer {

    /// Bucket used when no letter can be derived.
    public static let unknownBucket: Character = "#"

    /// Articles stripped from the start of the artist name. Trailing
    /// space is part of the match so "Anthrax" doesn't lose its "An ".
    private static let leadingArticles: [String] = ["the ", "a ", "an "]

    /// Spelled-out first letter for each decimal digit. Matches the
    /// design plan example "2Pac → T" (Two → T).
    private static let digitToLetter: [Character: Character] = [
        "0": "Z",  // Zero
        "1": "O",  // One
        "2": "T",  // Two
        "3": "T",  // Three
        "4": "F",  // Four
        "5": "F",  // Five
        "6": "S",  // Six
        "7": "S",  // Seven
        "8": "E",  // Eight
        "9": "N",  // Nine
    ]

    /// Visual-substitution symbols → letter. Captures the conventions
    /// stylized artist names use (e.g. Suicideboys writing `$uicideboy$`,
    /// Ke$ha, Sw!sh). Extend as edge cases surface; falling through
    /// the table is fine — the next non-symbol/letter handler runs.
    private static let symbolToLetter: [Character: Character] = [
        "$": "S",
        "5": "S",   // also covered by digitToLetter, kept for clarity
        "@": "A",
        "4": "A",
        "1": "I",   // overrides digit "One" when intentional, but we
                    // prefer digit-spelling first; this map is only
                    // consulted for symbols that ARE NOT digits
        "!": "I",
        "3": "E",
        "0": "O",
        "7": "T",
    ]

    public static func bucketLetter(forArtist rawArtist: String?) -> Character {
        let artist = (rawArtist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return unknownBucket }

        let withoutArticle = stripLeadingArticle(from: artist)
        return firstBucketLetter(in: withoutArticle) ?? unknownBucket
    }

    // MARK: - Internals (testable)

    static func stripLeadingArticle(from artist: String) -> String {
        let lowered = artist.lowercased()
        for article in leadingArticles where lowered.hasPrefix(article) {
            return String(artist.dropFirst(article.count))
        }
        return artist
    }

    static func firstBucketLetter(in string: String) -> Character? {
        for scalar in string.unicodeScalars {
            let character = Character(scalar)

            // Digit: spell it out, take first letter.
            if let mapped = digitToLetter[character] {
                return mapped
            }

            // Letter: uppercase and return. Handle Unicode by asking
            // the scalar's uppercase form for its first ASCII letter.
            if scalar.properties.isAlphabetic {
                let uppercased = String(character).uppercased()
                if let firstScalar = uppercased.unicodeScalars.first,
                   firstScalar.isASCII,
                   firstScalar.value >= UInt32(UnicodeScalar("A").value),
                   firstScalar.value <= UInt32(UnicodeScalar("Z").value) {
                    return Character(firstScalar)
                }
                // Non-ASCII letter (e.g., "Ümlaut"): fall back to the
                // raw uppercased character. Latin-1 supplement letters
                // sort outside A–Z but keep them in their natural
                // bucket rather than dumping in #.
                return uppercased.first
            }

            // Non-alphanumeric symbol: leetspeak substitution if known,
            // else skip and keep scanning.
            if let mapped = symbolToLetter[character] {
                return mapped
            }
        }
        return nil
    }
}
