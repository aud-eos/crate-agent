enum SeratoAnalysisMessages {
    static let unsupportedDetailPrefix = "Unsupported format"
    static let malformedDetailPrefix = "Malformed Serato data"
    static let containerDetailPrefix = "Unreadable audio container"
    static let ioDetailPrefix = "Couldn't read the file"

    static func detail(prefix: String, reason: String) -> String {
        "\(prefix): \(reason)"
    }

    static func malformedReason(field: String, reason: String) -> String {
        "\(field): \(reason)"
    }

    static func unknownFailure(_ stored: String) -> String {
        "The library contains an unrecognized Serato analysis failure \"\(stored)\"."
    }

    static func stopped(_ reason: String) -> String {
        "Reading Serato cue points stopped: \(reason)"
    }

    static let title = "Serato cue points and beatgrids"
    static let read = "Read"
    static let pending = "Pending"
    static let failed = "Failed"
    static let unsupported = "Unsupported format"
    static let coverageLoading = "Reading cue-point coverage…"
    static let hideFailures = "Hide files"
    static let explanation = "Reads cue points and beatgrid markers from each file's Serato tags, never writing them. "
        + "Unsupported formats and failed reads show as unknown in Library, never as No cues. Faults are listed before unsupported formats."

    static func coverage(_ coverage: SeratoAnalysisCoverage) -> String {
        let total = coverage.read + coverage.pending + coverage.failed + coverage.unsupported
        return "Cue points read for \(coverage.read.formatted()) of \(total.formatted()) files"
    }

    static func retrying(_ count: Int) -> String {
        count == 1 ? "1 failed read will be tried again." : "\(count.formatted()) failed reads will be tried again."
    }

    static func showFailures(_ count: Int) -> String {
        count == 1 ? "Show 1 file not read" : "Show \(count.formatted()) files not read"
    }

    static func firstFailures(_ limit: Int) -> String {
        "Showing the first \(limit) files."
    }
}
