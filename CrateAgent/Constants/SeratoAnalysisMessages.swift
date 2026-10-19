enum SeratoAnalysisMessages {
    /// The Rust core's `AnalysisError` messages begin with these.
    static let unsupportedFormatPrefix = "unsupported format: "
    static let malformedPrefix = "malformed "
    static let unreadableFilePrefix = "unreadable file: "

    static let unsupportedDetailPrefix = "Unsupported format"
    static let malformedDetailPrefix = "Malformed Serato data"
    static let unreadableDetailPrefix = "Unreadable file"

    static func detail(prefix: String, reason: String) -> String {
        "\(prefix): \(reason)"
    }

    static func unknownFailure(_ stored: String) -> String {
        "The library contains an unrecognized Serato analysis failure \"\(stored)\"."
    }

    static func stopped(_ reason: String) -> String {
        "Reading Serato cue points stopped: \(reason)"
    }
}
