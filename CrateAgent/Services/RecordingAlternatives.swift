import Foundation

/// How a recording candidate was found. Fingerprint evidence carries the
/// AcoustID confidence; metadata evidence carries only the app's own
/// artist/title text similarity, which is never an audio score.
enum MatchEvidence: Equatable, Sendable {
    case fingerprint(acoustID: String, score: Double)
    case metadataSearch(textScore: Double)

    /// Orders candidates found the same way; never compare across kinds.
    var rankingScore: Double {
        switch self {
        case let .fingerprint(_, score): score
        case let .metadataSearch(textScore): textScore
        }
    }

    var acoustID: String? {
        switch self {
        case let .fingerprint(acoustID, _): acoustID
        case .metadataSearch: nil
        }
    }

    var isMetadataSearch: Bool {
        if case .metadataSearch = self {
            return true
        }
        return false
    }
}

struct RecordingAlternative: Equatable, Identifiable, Sendable {
    let recordingID: String
    let evidence: MatchEvidence
    var score: Double {
        evidence.rankingScore
    }

    var acoustID: String? {
        evidence.acoustID
    }

    var id: String {
        recordingID
    }
}

struct RecordingMatchAssessment: Equatable, Sendable {
    static let strongScoreThreshold = 0.9
    static let competingScoreMargin = 0.05
    let score: Double
    let plausibleRecordingCount: Int
    var isBelowStrongThreshold: Bool {
        score < Self.strongScoreThreshold
    }

    var hasMultiplePlausibleRecordings: Bool {
        plausibleRecordingCount > 1
    }

    var isBulkApprovalEligible: Bool {
        !isBelowStrongThreshold && !hasMultiplePlausibleRecordings
    }
}

struct RecordingAlternatives: Equatable, Sendable {
    let entries: [RecordingAlternative]

    init(results: [AcoustIDResult]) {
        let ranked = results.flatMap { result in
            result.recordingIDs.map { recordingID in
                RecordingAlternative(recordingID: recordingID, evidence: .fingerprint(acoustID: result.id, score: result.score))
            }
        }.sorted { first, second in
            if first.score != second.score {
                return first.score > second.score
            }
            if first.recordingID != second.recordingID {
                return first.recordingID < second.recordingID
            }
            return (first.acoustID ?? "") < (second.acoustID ?? "")
        }
        var seen: Set<String> = []
        entries = ranked.filter { entry in seen.insert(entry.recordingID).inserted }
    }

    /// Candidates from a MusicBrainz artist/title search, already ranked
    /// by `MetadataMatchRanker`.
    init(metadataMatches: [MetadataRecordingMatch]) {
        var seen: Set<String> = []
        entries = metadataMatches
            .filter { match in seen.insert(match.details.id).inserted }
            .map { match in RecordingAlternative(recordingID: match.details.id, evidence: .metadataSearch(textScore: match.textScore)) }
    }

    var isMetadataSearch: Bool {
        entries.first?.evidence.isMetadataSearch ?? false
    }

    func collapsed(using details: [String: MBRecordingDetails]) -> [RecordingAlternative] {
        var seen: Set<String> = []
        return entries.filter { entry in seen.insert(canonicalID(for: entry.recordingID, details: details)).inserted }
    }

    func alternative(for recordingID: String, details: [String: MBRecordingDetails] = [:]) -> RecordingAlternative? {
        let canonical = canonicalID(for: recordingID, details: details)
        return entries.first { entry in canonicalID(for: entry.recordingID, details: details) == canonical }
    }

    func canonicalID(for recordingID: String, details: [String: MBRecordingDetails]) -> String {
        var canonical = recordingID
        var visited: Set<String> = []
        while visited.insert(canonical).inserted, let next = details[canonical]?.id, next != canonical {
            canonical = next
        }
        return canonical
    }

    func assessment(for alternative: RecordingAlternative, details: [String: MBRecordingDetails] = [:]) -> RecordingMatchAssessment {
        let plausible = collapsed(using: details).filter(isPlausible)
        return RecordingMatchAssessment(score: alternative.score, plausibleRecordingCount: plausible.count)
    }

    func isPlausible(_ alternative: RecordingAlternative) -> Bool {
        let topScore = entries.first?.score ?? alternative.score
        return alternative.score >= RecordingMatchAssessment.strongScoreThreshold
            || alternative.score >= topScore - RecordingMatchAssessment.competingScoreMargin
    }
}

struct RecordingAlternativeDetailResult: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case loaded(MBRecordingDetails)
        case failed(String)
    }

    let alternative: RecordingAlternative
    let state: State
}
