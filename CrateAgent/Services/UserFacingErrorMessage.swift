import Foundation

enum UserFacingErrorMessage {
    /// Readable text for an error shown in a row, notice, or History entry.
    /// The generated `CoreError: LocalizedError` conformance reflects the enum
    /// case, so the Rust core's message is unwrapped here instead.
    static func message(for error: Error) -> String {
        guard let coreError = error as? CoreError else { return error.localizedDescription }
        switch coreError {
        case .NotImplemented: return "This operation is not supported yet."
        case let .InvalidInput(reason): return reason
        case let .IoError(message), let .SeratoFormat(message), let .Fingerprint(message), let .Tag(message), let .LandedNotDurable(message):
            return message
        }
    }
}
