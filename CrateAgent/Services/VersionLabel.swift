import Foundation

/// The version labels DJs put in titles, such as "(Clean)" or "- Radio Edit".
/// This is the one vocabulary for title merging (`TitleMatcher`), duplicate
/// label review and song-family suggestions.
public enum VersionLabel: String, CaseIterable, Codable, Sendable {
    case clean
    case dirty
    case instrumental
    case acapella
    case radio
    case extended
    case introOutro
    case remix
    case edit
    case main

    /// Clean and Dirty rate a version's content and exclude each other; every
    /// other label is a variant a version may combine (an extended clean remix).
    public enum Axis: Sendable {
        case content
        case variant
    }

    public var axis: Axis {
        switch self {
        case .clean, .dirty: .content
        case .instrumental, .acapella, .radio, .extended, .introOutro, .remix, .edit, .main: .variant
        }
    }

    public var displayName: String {
        switch self {
        case .clean: "Clean"
        case .dirty: "Dirty"
        case .instrumental: "Instrumental"
        case .acapella: "Acapella"
        case .radio: "Radio"
        case .extended: "Extended"
        case .introOutro: "Intro/Outro"
        case .remix: "Remix"
        case .edit: "Edit"
        case .main: "Main"
        }
    }

    /// Whole-word spellings, lowercased.
    var terms: [String] {
        switch self {
        case .clean: ["clean"]
        case .dirty: ["dirty", "explicit"]
        case .instrumental: ["instrumental"]
        case .acapella: ["acapella", "a cappella"]
        case .radio: ["radio edit", "radio version"]
        case .extended: ["extended", "extended mix"]
        case .introOutro: ["intro", "outro"]
        case .remix: ["remix"]
        case .edit: ["edit", "short edit"]
        case .main: ["main", "original mix", "album version"]
        }
    }

    /// DJ annotations that name no version label.
    private static let otherAnnotationTerms = ["club mix", "flip", "bootleg", "redrum", "transition", "dub", "quick hit"]

    /// Every DJ annotation term, labelled or not, confirmed against a
    /// 32k-track library scan.
    static let annotationTerms: [String] = allCases.flatMap(\.terms) + otherAnnotationTerms

    /// Longest first, so "radio edit" is read as Radio rather than also Edit.
    private static let termsByLength: [(term: String, label: VersionLabel?)] =
        (allCases.flatMap { label in label.terms.map { term in (term, Optional(label)) } }
            + otherAnnotationTerms.map { term in (term, nil) })
        .sorted { lhs, rhs in lhs.0.count > rhs.0.count }

    /// The labels named in `title`'s annotations: its `(...)` and `[...]`
    /// groups and a trailing `- ...` suffix. Words in the base title ("Dirty
    /// Diana") are not labels.
    public static func labels(in title: String) -> Set<VersionLabel> {
        TitleMatcher.annotationSegments(in: title).reduce(into: Set<VersionLabel>()) { labels, segment in
            labels.formUnion(terms(in: segment).compactMap(\.self))
        }
    }

    /// Whether an annotation's content names a version, labelled or not
    /// ("Clean", "DJ Snake Remix", "Club Mix").
    static func namesVersion(_ segment: String) -> Bool {
        !terms(in: segment).isEmpty
    }

    /// Compiled once: Find Versions reads every candidate's labels.
    private static let nonWordRun = try? NSRegularExpression(pattern: #"[^\p{L}\p{N}]+"#)

    /// The annotation terms in `segment`, longest first, each as its label
    /// or nil for an unlabelled DJ annotation.
    private static func terms(in segment: String) -> [VersionLabel?] {
        let lowercased = segment.lowercased()
        let words = nonWordRun?.stringByReplacingMatches(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased), withTemplate: " ")
        var remaining = " \(words ?? lowercased) "
        var found: [VersionLabel?] = []
        for entry in termsByLength {
            let needle = " \(entry.term) "
            guard remaining.contains(needle) else { continue }
            remaining = remaining.replacingOccurrences(of: needle, with: "  ")
            found.append(entry.label)
        }
        return found
    }

    /// `labels` in reading order, content rating first.
    public static func describe(_ labels: Set<VersionLabel>) -> String {
        let ordered = allCases.filter(labels.contains)
        return ordered.isEmpty ? "No version label" : ordered.map(\.displayName).joined(separator: ", ")
    }
}
