import Foundation

enum SeratoConflictMessages {
    static let review = "Review conflicts"
    static let stale = "Showing the last validated conflicts. These details remain protected until a fresh sync verifies the saved library."
    static let repair = "Inspect the listed entries in Serato. Preserve the intended audio, metadata and crate membership; remove only verified unwanted library references without deleting audio. Save and close Serato, then retry sync. Restore access to unknown or inaccessible locations before deciding an entry is stale."
    static func renameCollision(from source: String, to destination: String) -> String {
        "A queued rename moves this file from \(source) to \(destination), but Serato has saved entries at both paths. The entry at \(source) is this file's, including any edits saved in Serato while the rename was queued; the entry at \(destination) is a separate reference. Keep the entries you intend, remove only verified unwanted references without deleting audio, save and close Serato, then retry sync."
    }

    static func blocked(_ path: String) -> String {
        "Path conflict: \(path). Review conflicts and repair the saved entries in Serato before processing this file."
    }
}

struct SeratoPathConflictError: LocalizedError {
    let path: String
    var errorDescription: String? {
        SeratoConflictMessages.blocked(path)
    }
}
