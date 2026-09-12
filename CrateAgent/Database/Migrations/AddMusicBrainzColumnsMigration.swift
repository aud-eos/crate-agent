import Foundation
import GRDB

/// Adds MusicBrainz identity columns to `tracks`: the release and
/// artist MBIDs and the ISRC, populated by the SP-2 auto-tagger once
/// a track is matched against the MusicBrainz database. Nullable
/// because unmatched tracks carry no MusicBrainz identity yet.
enum AddMusicBrainzColumnsMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("007_add_musicbrainz_columns") { db in
            try db.alter(table: "tracks") { table in
                table.add(column: "musicbrainz_release_id", .text)
                table.add(column: "musicbrainz_artist_id", .text)
                table.add(column: "isrc", .text)
            }
        }
    }
}
