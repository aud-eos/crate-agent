enum SeratoGateMessages {
    static let cleanupApplyBlocked = "Quit Serato before applying — fixes write to Serato library files and would be clobbered on Serato's next save."
    static let duplicateResolveBlocked = "Quit Serato before resolving — Serato can clobber the database V2 changes from its in-memory cache."

    static func quitBefore(_ action: String) -> String {
        "Serato is running — quit it before \(action)."
    }
}
