enum FileOpenerMessages {
    static let openWith = "Open With"
    static let reveal = "Reveal in Finder"
    static let defaultApplication = "Default Application"
    static let dismiss = "Dismiss"

    static func open(in application: String) -> String {
        "Open in \(application)"
    }

    static func missing(_ filename: String) -> String {
        "Can't open \(filename): the file is missing."
    }

    static func noApplication(_ filename: String) -> String {
        "No application on this Mac can open \(filename)."
    }

    static func openFailed(_ filename: String, application: String, reason: String) -> String {
        "Couldn't open \(filename) in \(application): \(reason)"
    }
}
