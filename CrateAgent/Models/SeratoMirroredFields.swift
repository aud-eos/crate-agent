import Foundation

/// One Serato-mirrored metadata field: its stable journal name and its
/// `database V2` tag.
struct SeratoMirroredField: Sendable {
    let name: String
    let databaseTag: String
    let keyPath: WritableKeyPath<SeratoMetadata, String?> & Sendable
}

extension SeratoMetadata {
    /// Every field `files` mirrors from `database V2`, in tag order.
    static let fields: [SeratoMirroredField] = [
        SeratoMirroredField(name: "artist", databaseTag: "tart", keyPath: \.artist),
        SeratoMirroredField(name: "title", databaseTag: "tsng", keyPath: \.title),
        SeratoMirroredField(name: "album", databaseTag: "talb", keyPath: \.album),
        SeratoMirroredField(name: "genre", databaseTag: "tgen", keyPath: \.genre),
        SeratoMirroredField(name: "bpm", databaseTag: "tbpm", keyPath: \.bpm),
        SeratoMirroredField(name: "key", databaseTag: "tkey", keyPath: \.musicalKey),
        SeratoMirroredField(name: "comment", databaseTag: "tcom", keyPath: \.comment),
        SeratoMirroredField(name: "length", databaseTag: "tlen", keyPath: \.length),
        SeratoMirroredField(name: "label", databaseTag: "tlbl", keyPath: \.label),
        SeratoMirroredField(name: "year", databaseTag: "ttyr", keyPath: \.year),
    ]

    init(_ record: SeratoTrackRecord) {
        self.init(artist: record.artist, title: record.title, album: record.album, genre: record.genre, bpm: record.bpm,
                  musicalKey: record.key, comment: record.comment, length: record.length, label: record.label, year: record.year)
    }

    /// The `database V2` values `file` mirrors.
    init(mirroredBy file: some HygieneFileSource) {
        self.init(artist: file.artist, title: file.title, album: file.album, genre: file.genre, bpm: file.bpm,
                  musicalKey: file.musicalKey, comment: file.comment, length: file.length, label: file.label, year: file.seratoYear)
    }

    /// The same fields as a writer patch: nil leaves a field unchanged.
    var databaseUpdate: SeratoMetadataUpdate {
        SeratoMetadataUpdate(artist: artist, title: title, album: album, genre: genre, bpm: bpm, key: musicalKey,
                             comment: comment, length: length, label: label, year: year)
    }

    func record(path: String) -> SeratoTrackRecord {
        SeratoTrackRecord(path: path, artist: artist, title: title, album: album, genre: genre, bpm: bpm, key: musicalKey,
                          comment: comment, length: length, label: label, year: year)
    }
}

extension FileRecord {
    /// Replaces every mirrored `database V2` value, including absent ones.
    mutating func mirror(_ metadata: SeratoMetadata) {
        artist = metadata.artist
        title = metadata.title
        album = metadata.album
        genre = metadata.genre
        bpm = metadata.bpm
        musicalKey = metadata.musicalKey
        comment = metadata.comment
        length = metadata.length
        label = metadata.label
        seratoYear = metadata.year
    }
}
