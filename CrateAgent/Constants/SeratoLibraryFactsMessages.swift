enum SeratoLibraryFactsMessages {
    static func unreadableRecords(_ count: Int) -> String {
        let records = count == 1 ? "1 Serato record couldn't be read" : "\(count) Serato records couldn't be read"
        return "\(records) from database V2; files without a readable record show no Serato facts."
    }
}
