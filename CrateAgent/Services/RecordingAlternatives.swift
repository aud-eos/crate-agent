import Foundation

struct RecordingAlternative: Equatable, Identifiable, Sendable {
    let recordingID: String
    let acoustID: String
    let score: Double
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
                RecordingAlternative(recordingID: recordingID, acoustID: result.id, score: result.score)
            }
        }.sorted { first, second in
            if first.score != second.score {
                return first.score > second.score
            }
            if first.recordingID != second.recordingID {
                return first.recordingID < second.recordingID
            }
            return first.acoustID < second.acoustID
        }
        var seen: Set<String> = []
        entries = ranked.filter { entry in seen.insert(entry.recordingID).inserted }
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
