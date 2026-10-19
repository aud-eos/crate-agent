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
}
