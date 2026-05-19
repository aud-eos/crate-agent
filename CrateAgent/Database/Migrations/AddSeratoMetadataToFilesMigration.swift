import Foundation
import GRDB

/// Adds Serato-sourced metadata columns to the `files` table. The
/// `tracks` table already has canonical fields like artist/title/bpm,
/// but those are intended for *track-level* identity (keyed by
/// Chromaprint fingerprint) and are populated only after the
/// fingerprinting pipeline lands. For SP-1's Serato-mirror flow we
/// need metadata-per-file (Serato's view of each path on disk)
/// available immediately, without waiting for fingerprints.
///
/// Storing as TEXT (even for numeric-ish fields like BPM and length)
/// mirrors how Serato itself stores them — "128.000", "03:24" — and
/// keeps the round-trip lossless. Swift parses to typed values at the
/// display layer.
///
/// All columns nullable: a file row pre-dating this migration carries
/// no Serato metadata yet, and the next library scan + Serato-exit
/// reload populate them.
enum AddSeratoMetadataToFilesMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("003_add_serato_metadata_to_files") { db in
            try db.alter(table: "files") { table in
                table.add(column: "artist", .text)
                table.add(column: "title", .text)
                table.add(column: "album", .text)
                table.add(column: "genre", .text)
                table.add(column: "bpm", .text)
                table.add(column: "musical_key", .text)
                table.add(column: "comment", .text)
                table.add(column: "length", .text)
                table.add(column: "label", .text)
            }
        }
    }
}
