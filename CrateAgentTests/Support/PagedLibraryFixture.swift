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
            for identifier in [1, 2, 3, 4, 15001, 30000] {
                var file = Self.file(identifier)
                try file.save(connection)
            }
        }
    }

    func close() throws {
        try pool.close()
        try FileManager.default.removeItem(at: directory)
    }
}
