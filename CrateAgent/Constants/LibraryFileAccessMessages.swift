enum LibraryFileAccessMessages {
    static let notInLibrary = "it is no longer in the library."
    static let missing = "the file is missing."
    static let replaced = "the file at its path was replaced or changed since crate-agent last checked it. Re-scan file info, then try again."

    static func unknownFile(_ fileID: Int64) -> String {
        "file \(fileID)"
    }

    static func unavailable(_ availability: FileAvailability) -> String {
        availability == .missing ? missing : "the file is unavailable (\(availability.displayTitle))."
    }

    static func unreadable(_ reason: String) -> String {
        "the file could not be read (\(reason))."
    }
}
