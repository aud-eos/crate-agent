enum SeratoLibraryFactsMessages {
    static func unreadableRecords(_ count: Int) -> String {
        let records = count == 1 ? "1 Serato record couldn't be read" : "\(count) Serato records couldn't be read"
        return "\(records) from database V2; files without a readable record show no Serato facts."
    }

    static let title = "Serato crates and beatgrid locks"
    static let notRefreshed = "Not read yet; reads Serato's database and crates after the library sync."
    static let refreshing = "Reading Serato's database and crates…"
    static let skippedWhileSeratoRunning = "Waiting for Serato to close; showing the last crates and beatgrid locks."
    static let explanation = "Crate membership, beatgrid locks and date added come from Serato's database V2 and Subcrates, "
        + "read only while Serato is closed and never written. SmartCrates don't count as crates."

    static func failed(_ reason: String) -> String {
        "Could not read every Serato fact; keeping what was read. \(reason)"
    }

    static func refreshed(_ summary: SeratoLibraryFactsSummary) -> String {
        "\(summary.trackFactCount.formatted()) tracks read from database V2 · \(summary.membershipCount.formatted()) crate entries across "
            + "\(summary.crateCount.formatted()) crates."
    }

    static func unmatched(_ count: Int) -> String {
        count == 1 ? "1 Serato path matched no single library file." : "\(count.formatted()) Serato paths matched no single library file."
    }
}
