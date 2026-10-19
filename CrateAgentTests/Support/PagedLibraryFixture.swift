@testable import CrateAgent
import Foundation
import GRDB

final class PagedLibraryFixture {
    let directory: URL
    let database: LibraryDatabase
    let pool: DatabasePool
    let query = LibraryBrowseQuery()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PagedLibrary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try LibraryDatabase.openWAL(at: directory.appendingPathComponent("library.sqlite"))
        guard let pool = database.writer as? DatabasePool else { throw PagingFixtureError.unavailable }
        self.pool = pool
        try pool.write { connection in
            for identifier in 1 ... 30000 {
                var file = Self.file(identifier)
                try file.insert(connection)
            }
        }
    }

    static func file(_ identifier: Int) -> FileRecord {
        var file = FileRecord(id: Int64(identifier), path: String(format: "/Synthetic/%05d.mp3", identifier),
                              volumeUuid: "paging-fixture", inode: Int64(identifier), fileSize: 1, mtime: 0,
                              artist: identifier <= 15000 ? "Artist A" : "Artist B",
                              title: identifier == 30000 ? "Final Needle" : "Track", album: "Collection")
        file.libraryMembership = .active
        file.fileAvailability = .available
        return file
    }

    func reset() throws {
        try pool.write { connection in
            try connection.execute(sql: "DELETE FROM files WHERE id > 30000")
            try connection.execute(sql: "UPDATE files SET track_id = NULL; DELETE FROM tracks; DELETE FROM works")
            try connection.execute(sql: "UPDATE files SET genre = NULL, bpm = NULL, musical_key = NULL, bitrate_kbps = NULL")
            for table in LibraryChecklist.observedTables {
                try connection.execute(sql: "DELETE FROM \(table)")
            }
            for identifier in [1, 2, 3, 4, 15001, 30000] {
                var file = Self.file(identifier)
                try file.save(connection)
            }
        }
    }

    /// Checklist facts for every file: V2 facts for all 30,000, fresh analysis for 24,000,
    /// crate membership for 20,000, play counts for 10,000, 300 confirmed duplicate members,
    /// 500 keeper marks, and 2,000 three-version families. Half the files have full metadata, with
    /// three genres, BPMs from 118 to 130 in two spellings, and keys in musical, Camelot and Open Key notation.
    func seedChecklist() throws {
        try pool.write { connection in
            try connection.execute(sql: """
            UPDATE files SET genre = CASE id % 8 WHEN 0 THEN 'Techno' WHEN 2 THEN 'Disco' ELSE 'House' END,
                             bpm = CASE WHEN id % 6 = 0 THEN printf('%d.000', 118 + id % 13) ELSE CAST(118 + id % 13 AS TEXT) END,
                             musical_key = json_extract('["Am", "8A", "Em", "1m", "C", "F#m", "Abm", "12B", "Unknown", "Dm", "5A", "G"]',
                                                        '$[' || ((id / 2) % 12) || ']'),
                             bitrate_kbps = CASE WHEN id % 4 = 0 THEN 192 ELSE 320 END WHERE id % 2 = 0;
            INSERT INTO serato_track_facts (file_id, beatgrid_locked, added_at, added_source)
                SELECT id, id % 3 != 0, 1700000000 - id, CASE WHEN id % 5 = 0 THEN 'indexed' ELSE 'serato' END FROM files;
            INSERT INTO file_serato_analysis (file_id, file_size, mtime, inode, modified_nanoseconds, changed_seconds, changed_nanoseconds,
                                              cue_count, beatgrid_marker_count, failure)
                SELECT id, file_size, mtime, inode, 0, 0, 0, id % 4, 1, NULL FROM files WHERE id <= 24000;
            INSERT INTO serato_crate_memberships (file_id, crate_name) SELECT id, 'Crate ' || (id % 20) FROM files WHERE id <= 20000;
            INSERT INTO serato_play_counts (file_id, play_count) SELECT id, id % 50 + 1 FROM files WHERE id % 3 = 0;
            INSERT INTO checklist_duplicate_members (file_id, group_key) SELECT id, 'group-' || (id / 200) FROM files WHERE id % 100 = 7;
            INSERT INTO keeper_marks (file_id, marked_revision, marked_at) SELECT id, 0, 1 FROM files WHERE id % 60 = 1;
            """)
            try connection.execute(sql: "INSERT INTO checklist_source_stamps (source, stamp) VALUES (?, '{}')",
                                   arguments: [ChecklistSource.subcrates.rawValue])
            try Self.groupFamilies(connection)
        }
    }

    /// 2,000 three-version families over files 1–3, 11–13, … , 19991–19993.
    static func groupFamilies(_ connection: GRDB.Database) throws {
        for family in 0 ..< 2000 {
            var record = SongFamilyRecord()
            try record.insert(connection)
            for member in 0 ..< 3 {
                let fileID = Int64(family * 10 + member + 1)
                var track = TrackRecord(fingerprintHash: Data("family-\(fileID)".utf8), workId: record.id)
                try track.insert(connection)
                try connection.execute(sql: "UPDATE files SET track_id = ? WHERE id = ?", arguments: [track.id, fileID])
            }
        }
    }

    func close() throws {
        try pool.close()
        try FileManager.default.removeItem(at: directory)
    }
}
