@testable import CrateAgent

extension AudioTags {
    static let none = AudioTags(bitrateKbps: nil, title: nil, artist: nil, album: nil, albumArtist: nil, genre: nil,
                                year: nil, trackNumber: nil, totalTracks: nil, bpm: nil, comment: nil, durationSeconds: nil)

    /// The tags a file would read back after `updates` were written over
    /// these, for tests that fake the tag writer: an empty string clears a
    /// field and an absent one leaves it alone, as `writeAudioTags` does.
    func applying(_ updates: [AudioTagUpdate]) -> AudioTags {
        updates.reduce(self) { tags, update in
            var next = tags
            func fold(_ value: String?, into field: inout String?) {
                guard let value else { return }
                field = value.isEmpty ? nil : value
            }
            fold(update.artist, into: &next.artist)
            fold(update.title, into: &next.title)
            fold(update.album, into: &next.album)
            fold(update.genre, into: &next.genre)
            fold(update.comment, into: &next.comment)
            if update.clearYear {
                next.year = nil
            } else if let year = update.year {
                next.year = year
            }
            return next
        }
    }
}
