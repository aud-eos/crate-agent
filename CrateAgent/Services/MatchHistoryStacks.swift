import Foundation

/// Each file's MusicBrainz match history read as a stack: an apply pushes and
/// a revert pops, so what remains is the file's live matches, newest last.
/// Undo is LIFO per file, which is what makes this reading exact.
enum MatchHistoryStacks {
    /// `history` in event order; `fileOf` names the file each event belongs to.
    static func liveApplies<Key: Hashable>(in history: [EventRecord], fileOf: (EventRecord) throws -> Key?) rethrows -> [Key: [Int64]] {
        var stacks: [Key: [Int64]] = [:]
        for event in history {
            guard let eventID = event.eventId, let key = try fileOf(event) else { continue }
            switch event.eventType {
            case .musicBrainzMatchApplied:
                stacks[key, default: []].append(eventID)
            case .musicBrainzMatchReverted:
                _ = stacks[key]?.popLast()
            default:
                continue
            }
        }
        return stacks
    }
}
