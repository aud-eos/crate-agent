@testable import CrateAgent
import Foundation
import GRDB

/// Real files on disk with library rows whose identity matches them, for
/// code that verifies a row's file before handing it to the system.
@MainActor
final class LibraryFileFixture {
    let directory: URL
    let database: LibraryDatabase
    var access: LibraryFileAccess {
        LibraryFileAccess(database: database)
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryFileFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try LibraryDatabase.openWAL(at: directory.appendingPathComponent("library.sqlite"))
    }

    func remove() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func writeAudio(_ name: String, byte: UInt8 = 0) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: byte, count: 64).write(to: url)
        return url.path
    }

    /// Writes `name` and indexes it as an available Active row.
    @discardableResult
    func addFile(_ name: String, id: Int64, title: String? = nil, availability: FileAvailability = .available) async throws -> String {
        let path = try writeAudio(name)
        let identity = try FileMetadataCollector.collectVerified(at: path)
        try await database.writer.write { connection in
            var file = FileRecord(id: id, path: path, volumeUuid: identity.volumeUuid, inode: identity.inode, fileSize: identity.fileSize,
                                  mtime: identity.mtime, lightweightHash: identity.lightweightHash, title: title)
            file.libraryMembership = .active
            file.fileAvailability = availability
            try file.insert(connection)
        }
        return path
    }
}
