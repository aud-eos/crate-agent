import Foundation

/// Copy for popularity lookups: the Library columns, the sources sheet, Settings and the Workers card.
enum PopularityMessages {
    static let title = "Popularity"
    static let hotTitle = "Hot"
    static let off = "off"
    static let offStatus = "Popularity is off. Turn on a source to look tracks up."
    static let sheetTitle = "Look up how popular your tracks are?"
    static let sheetBody = "Popularity looks each track up on the services you turn on, in the background. Only the artist, title, ISRC and MusicBrainz recording ID are sent. Nothing is sent until you turn a source on."
    static let enable = "Turn on"
    static let notNow = "Not now"
    static let settingsFooter = "All-time popularity is each source's listener or rank figure, normalized to 0 to 100. Hot is growth since an earlier lookup at least a week old, filled from the Deezer chart until then."
    static let refreshNow = "Refresh now"
    static let notRefreshed = "Not looked up yet"
    static let waitingForSync = "Waiting for the library sync to finish."
    static let refreshed = "Up to date"
    static let offline = "Offline. Scores shown are from the last lookup."

    static func name(_ source: PopularitySource) -> String {
        switch source {
        case .listenBrainz: "ListenBrainz"
        case .deezer: "Deezer"
        }
    }

    static func receives(_ source: PopularitySource) -> String {
        switch source {
        case .listenBrainz: "Receives MusicBrainz recording IDs. Returns how many times each recording was listened to."
        case .deezer: "Receives the ISRC, or the artist and title, and returns the track's Deezer rank. Also seeds Hot from the Deezer chart."
        }
    }

    static func detail(_ source: PopularitySource, value: Double) -> String {
        let figure = Int(value.rounded()).formatted()
        return switch source {
        case .listenBrainz: "ListenBrainz \(figure) listens"
        case .deezer: "Deezer rank \(figure)"
        }
    }

    static func refreshing(done: Int, total: Int) -> String {
        "Looking up \(done.formatted()) of \(total.formatted()) recordings"
    }

    static func refreshedCount(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "recording" : "recordings") looked up"
    }

    static func failed(_ message: String) -> String {
        "Lookup stopped: \(message)"
    }
}
