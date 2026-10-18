enum FileOpenerMessages {
    static let openWith = "Open With"
    static let otherApplication = "Other…"
    static let chooseApplication = "Choose an application to open the file"
    static let reveal = "Reveal in Finder"
    static let defaultApplication = "Default Application"
    static let dismissFailure = "Dismiss file open error"
    static let openVerb = "open"
    static let openAction = "Open"
    static let revealVerb = "reveal"
    static let theFile = "the file"

    static func open(in application: String) -> String {
        "Open in \(application)"
    }

    static func cannot(_ verb: String, _ filename: String, _ detail: String) -> String {
        "Can't \(verb) \(filename): \(detail)"
    }

    static func noApplication(_ filename: String) -> String {
        "No application on this Mac opens \(filename) by default. Use Open With, then Other…, to pick one."
    }

    static func openFailed(_ filename: String, application: String, reason: String) -> String {
        "Couldn't open \(filename) in \(application): \(reason)"
    }
}
