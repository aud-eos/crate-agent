import Foundation

/// The tier a MusicBrainz-proposed title falls into, relative to the DJ's
/// current title. Drives the default resolution the review UI (Task 14)
/// pre-selects, and which the user can override.
public enum TitleTier: Equatable {
    /// Same title once normalized. Default: take MB's title.
    case exact
    /// MB's proposed title is the current title's base with a DJ-added
    /// annotation (version flag, curator credit, ...) trimmed off. `merged`
    /// is MB's base plus that annotation, restored from the current title.
    /// Default: use `merged`.
    case baseMatch(merged: String)
    /// MB's proposal doesn't share a base with the current title, and the
    /// current title carries an annotation MB's proposal doesn't preserve.
    /// Default: keep the current title untouched.
    case annotationNoBase
    /// None of the above — a plain MB correction (typo fix, etc.) with no
    /// DJ-relevant annotation at stake. Default: take MB's title.
    case plain
}

/// Which of the three candidate titles (the DJ's current one, MB's
/// proposal, or a merge of the two) a resolved `TitleTier` should apply.
public enum TitleChoice: Equatable {
    case keep
    case merge
    case take
}

/// A tier plus the choice `TitleMatcher` recommends for it. The review UI
/// pre-selects `defaultChoice`; the user may pick a different `TitleChoice`
/// for the same tier, which `TitleMatcher.value(for:current:proposed:tier:)`
/// then resolves into the actual string.
public struct TitleDecision: Equatable {
    public let tier: TitleTier
    public let defaultChoice: TitleChoice
}

/// Decides how to reconcile a MusicBrainz-proposed title with the DJ's
/// current one. Pure logic, no I/O.
///
/// MusicBrainz recording titles are the "clean" studio title. DJs annotate
/// their titles with version flags MusicBrainz doesn't track — `(Dirty)`,
/// `[Clean]`, `- Radio Edit`, curator credits like `(MM Edit)`. Blindly
/// taking MB's title would silently strip information the DJ relies on to
/// tell tracks apart at a glance; blindly keeping the current title would
/// never absorb MB's actual corrections (typo fixes, etc). `decide` picks
/// the right default per case; `value` resolves whichever `TitleChoice` the
/// user ultimately picks (the default, or an override) into the title
/// string to write.
public enum TitleMatcher {
    /// DJ version-flag vocabulary confirmed against a 32k-track library
    /// scan. Used only as a fallback when a title carries one of these
    /// tokens bare (no surrounding `()`/`[]`/`- ` delimiter) that MB's
    /// proposal doesn't preserve. Matched whole-word, case-insensitive.
    private static let djVersionVocabulary: [String] = [
        "clean", "dirty", "explicit", "radio edit", "radio version", "intro", "outro",
        "acapella", "instrumental", "extended", "extended mix", "club mix", "original mix",
        "main", "edit", "flip", "bootleg", "redrum", "transition", "remix", "dub",
        "short edit", "quick hit", "album version",
    ]

    public static func decide(current: String, proposed: String) -> TitleDecision {
        let normalizedCurrent = normalize(current)
        let normalizedProposed = normalize(proposed)

        if normalizedCurrent == normalizedProposed {
            return TitleDecision(tier: .exact, defaultChoice: .take)
        }

        if normalizedCurrent.hasPrefix(normalizedProposed),
           normalizedCurrent.count > normalizedProposed.count,
           let merged = mergedTitle(current: current, proposed: proposed)
        {
            return TitleDecision(tier: .baseMatch(merged: merged), defaultChoice: .merge)
        }

        if hasDroppedAnnotation(current: current, proposed: proposed) {
            return TitleDecision(tier: .annotationNoBase, defaultChoice: .keep)
        }

        return TitleDecision(tier: .plain, defaultChoice: .take)
    }

    public static func value(for choice: TitleChoice, current: String, proposed: String, tier: TitleTier) -> String {
        switch choice {
        case .keep:
            return current
        case .take:
            return proposed
        case .merge:
            if case let .baseMatch(merged) = tier {
                return merged
            }
            // `.merge` is only well-defined for `.baseMatch`, where `merged`
            // is the located base+remainder split. Forced against another
            // tier (a caller error we shouldn't crash on), there is no
            // remainder to preserve, so fall back to MB's title, same as
            // `.take`.
            return proposed
        }
    }

    /// Every `(...)` group, every `[...]` group, and a trailing `- ...` /
    /// `– ...` (en dash) suffix, as their inner content (delimiters
    /// stripped). Order: parenthesized groups, then bracketed groups, then
    /// the trailing dash suffix, each in left-to-right order of appearance.
    public static func annotationSegments(in title: String) -> [String] {
        var segments = regexCaptures(pattern: #"\(([^()]*)\)"#, in: title)
        segments.append(contentsOf: regexCaptures(pattern: #"\[([^\[\]]*)\]"#, in: title))
        if let dashSegment = trailingDashSegment(in: title) {
            segments.append(dashSegment)
        }
        return segments
    }

    /// True when the current title carries an annotation MB's proposal
    /// doesn't preserve: either a `()`/`[]`/trailing-dash segment whose
    /// (normalized) content is absent from the proposed title, or — as a
    /// fallback for annotations with no surrounding delimiter — a whole-word
    /// DJ version-flag token present in the current title but not the
    /// proposed one.
    public static func hasDroppedAnnotation(current: String, proposed: String) -> Bool {
        let normalizedProposed = normalize(proposed)

        for segment in annotationSegments(in: current) {
            let normalizedSegment = normalize(segment)
            guard !normalizedSegment.isEmpty else { continue }
            if !normalizedProposed.contains(normalizedSegment) {
                return true
            }
        }

        let normalizedCurrent = normalize(current)
        for vocabularyTerm in djVersionVocabulary {
            if containsWholeWord(vocabularyTerm, in: normalizedCurrent),
               !containsWholeWord(vocabularyTerm, in: normalizedProposed)
            {
                return true
            }
        }

        return false
    }

    /// Locates `proposed` at the very start of the original `current`
    /// (case-insensitive) and appends everything after that range from
    /// `current`, preserving its original formatting. Operates on a `Range`
    /// found directly in `current` — never on indices computed against the
    /// normalized string — so it stays index-safe regardless of how
    /// normalization reshapes whitespace or case. Returns `nil` if `proposed`
    /// isn't literally present at the start of `current` (which can happen
    /// even when the normalized forms satisfy the prefix check, e.g. when
    /// non-standard whitespace inside `current` doesn't collapse to match
    /// `proposed`'s spacing); callers treat that as "not actually a
    /// base-match" and fall through to the remaining tiers.
    private static func mergedTitle(current: String, proposed: String) -> String? {
        guard let range = current.range(of: proposed, options: .caseInsensitive),
              range.lowerBound == current.startIndex
        else {
            return nil
        }
        return proposed + current[range.upperBound...]
    }

    /// A trailing `- ...` / `– ...` suffix, as its content with the dash and
    /// surrounding whitespace stripped. Skipped entirely when the title
    /// already ends in `)` or `]` — otherwise a dash that lives *inside* a
    /// trailing bracket/paren group (e.g. "... [remix - radio version]")
    /// would be double-reported as its own segment.
    private static func trailingDashSegment(in title: String) -> String? {
        guard let lastNonWhitespaceCharacter = title.trimmingCharacters(in: .whitespaces).last,
              lastNonWhitespaceCharacter != ")",
              lastNonWhitespaceCharacter != "]"
        else {
            return nil
        }
        guard let regex = try? NSRegularExpression(pattern: #"\s[-–]\s+(.+)$"#) else { return nil }
        let range = NSRange(title.startIndex..., in: title)
        guard let match = regex.firstMatch(in: title, range: range),
              match.numberOfRanges > 1,
              let capturedRange = Range(match.range(at: 1), in: title)
        else {
            return nil
        }
        return String(title[capturedRange])
    }

    private static func regexCaptures(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let capturedRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[capturedRange])
        }
    }

    private static func containsWholeWord(_ token: String, in normalizedText: String) -> Bool {
        let escapedToken = NSRegularExpression.escapedPattern(for: token)
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escapedToken)\\b", options: .caseInsensitive) else {
            return false
        }
        let range = NSRange(normalizedText.startIndex..., in: normalizedText)
        return regex.firstMatch(in: normalizedText, range: range) != nil
    }

    /// Lowercased, internal-whitespace-collapsed, trimmed.
    private static func normalize(_ title: String) -> String {
        let lowercased = title.lowercased()
        let collapsed = lowercased.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespaces)
    }
}
