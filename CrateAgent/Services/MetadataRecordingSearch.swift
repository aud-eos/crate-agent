import Foundation

/// The embedded artist and title an Auto-Tag metadata fallback searches
/// for. Both tags are required; neither is ever inferred from the filename.
struct MetadataSearchQuery: Equatable, Sendable {
    let artist: String
    let title: String

    init?(artist: String?, title: String?) {
        guard let artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty,
              let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        self.artist = artist
        self.title = title
    }

    /// The title without DJ version annotations (`(Intro)`, `[Clean]`,
    /// `- Radio Edit`), which MusicBrainz recordings usually lack.
    var baseTitle: String {
        MetadataMatchRanker.baseTitle(of: title)
    }
}

/// One ranked metadata-search result.
struct MetadataRecordingMatch: Equatable, Sendable {
    let details: MBRecordingDetails
    let textScore: Double
}

/// Ranks MusicBrainz search hits by how closely their artist and title
/// text match the file's embedded tags. Version annotations are context,
/// not proof: they carry a tenth of the score, so a base recording still
/// ranks highly for a DJ edit and a matching annotation only breaks ties.
enum MetadataMatchRanker {
    private static let artistWeight = 0.45
    private static let titleWeight = 0.45
    private static let versionWeight = 0.10
    /// Version agreement when only the file's title is annotated: the base
    /// recording is the usual source of a DJ edit.
    private static let unannotatedRecordingAgreement = 0.5
    /// Version agreement when only the recording's title is annotated.
    private static let unexpectedVersionAgreement = 0.25

    static func rank(_ hits: [MBRecordingDetails], for query: MetadataSearchQuery) -> [MetadataRecordingMatch] {
        hits.map { hit in MetadataRecordingMatch(details: hit, textScore: textScore(of: hit, for: query)) }
            .sorted { first, second in
                if first.textScore != second.textScore {
                    return first.textScore > second.textScore
                }
                return first.details.id < second.details.id
            }
    }

    static func textScore(of hit: MBRecordingDetails, for query: MetadataSearchQuery) -> Double {
        let artist = similarity(tokens(query.artist), tokens(hit.creditedArtistName))
        let title = similarity(tokens(baseTitle(of: query.title)), tokens(baseTitle(of: hit.title)))
        let fileVersion = versionTokens(in: query.title)
        let recordingVersion = versionTokens(in: hit.title).union(tokens(hit.disambiguation ?? ""))
        let version: Double = switch (fileVersion.isEmpty, recordingVersion.isEmpty) {
        case (true, true): 1
        case (false, true): unannotatedRecordingAgreement
        case (true, false): unexpectedVersionAgreement
        case (false, false): Double(fileVersion.intersection(recordingVersion).count) / Double(fileVersion.union(recordingVersion).count)
        }
        return artistWeight * artist + titleWeight * title + versionWeight * version
    }

    static func baseTitle(of title: String) -> String {
        var base = title
        for segment in TitleMatcher.annotationSegments(in: title) {
            for wrapped in ["(\(segment))", "[\(segment)]"] {
                base = base.replacingOccurrences(of: wrapped, with: " ")
            }
        }
        base = base.replacingOccurrences(of: #"\s[-–]\s+.+$"#, with: "", options: .regularExpression)
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    private static func versionTokens(in title: String) -> Set<String> {
        TitleMatcher.annotationSegments(in: title).reduce(into: Set<String>()) { result, segment in
            result.formUnion(tokens(segment))
        }
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(ListSearch.normalized(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { token in !token.isEmpty })
    }

    /// Sørensen–Dice coefficient over word sets.
    private static func similarity(_ first: Set<String>, _ second: Set<String>) -> Double {
        guard !first.isEmpty || !second.isEmpty else { return 0 }
        return 2 * Double(first.intersection(second).count) / Double(first.count + second.count)
    }
}
