import Foundation
import GRDB

/// First database schema migration.
///
/// Sets up the four tables that anchor the design:
///
///   `works`   user-curated track groupings (Pillar C; empty at SP-1)
///   `tracks`  canonical recording identity, keyed by Chromaprint hash
///   `files`   filesystem-level identity (path, volume, inode, hash)
///   `events`  append-only event log; powers undo and per-file history
///
/// Table creation order matters: a child table's REFERENCES clause is
/// validated at CREATE TABLE time on modern SQLite builds, so parents
/// must exist first. Order is works → tracks → files → events.
enum InitialSchemaMigration {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("001_initial") { db in
            try db.create(table: "works") { table in
                table.autoIncrementedPrimaryKey("id")
                // Populated by Pillar C (track groupings: radio mix,
                // extended mix, instrumental, a cappella, etc.). The
                // table exists in SP-1 only as a FK target so tracks
                // can be associated with works incrementally.
            }

            try db.create(table: "tracks") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("fingerprint_hash", .blob).notNull().unique()
                table.column("acoustid_id", .text)
                table.column("musicbrainz_recording_id", .text)
                table.column("artist", .text)
                table.column("title", .text)
                table.column("album", .text)
                table.column("album_artist", .text)
                table.column("genre", .text)
                table.column("year", .integer)
                table.column("bpm", .double)
                table.column("work_id", .integer)
                    .references("works", onDelete: .setNull)
                table.column("is_placeholder", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "files") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("path", .text).notNull().unique()
                table.column("volume_uuid", .text).notNull()
                table.column("inode", .integer).notNull()
                table.column("file_size", .integer).notNull()
                table.column("mtime", .integer).notNull()
                table.column("lightweight_hash", .blob)
                table.column("chromaprint_fingerprint", .blob)
                table.column("fingerprint_status", .text)
                    .notNull()
                    .defaults(to: "pending")
                table.column("track_id", .integer)
                    .references("tracks", onDelete: .setNull)
            }
            try db.create(
                index: "files_track_id",
                on: "files",
                columns: ["track_id"]
            )
            try db.create(
                index: "files_fingerprint_status",
                on: "files",
                columns: ["fingerprint_status"]
            )

            try db.create(table: "events") { table in
                table.autoIncrementedPrimaryKey("event_id")
                table.column("batch_id", .text).notNull()
                table.column("timestamp", .integer).notNull()
                table.column("file_id", .integer)
                    .references("files", onDelete: .setNull)
                table.column("track_id", .integer)
                    .references("tracks", onDelete: .setNull)
                table.column("event_type", .text).notNull()
                table.column("payload_json", .text).notNull()
                table.column("inverse_payload_json", .text).notNull()
            }
            try db.create(
                index: "events_batch_id",
                on: "events",
                columns: ["batch_id"]
            )
            try db.create(
                index: "events_file_id",
                on: "events",
                columns: ["file_id"]
            )
            try db.create(
                index: "events_track_id",
                on: "events",
                columns: ["track_id"]
            )
            try db.create(
                index: "events_timestamp",
                on: "events",
                columns: ["timestamp"]
            )
        }
    }
}
