extension CoreError {
    /// The Rust core's own message, without the generated type-name wrapper;
    /// nil for `NotImplemented`, whose meaning depends on the caller.
    var message: String? {
        switch self {
        case .NotImplemented: nil
        case let .InvalidInput(reason): reason
        case let .IoError(message), let .SeratoFormat(message), let .Fingerprint(message), let .Tag(message), let .LandedNotDurable(message): message
        }
    }
}
