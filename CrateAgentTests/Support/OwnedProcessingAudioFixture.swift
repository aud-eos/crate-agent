@testable import CrateAgent
import Foundation
import GRDB

final class OwnedProcessingAudioFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-processing-audio-\(UUID().uuidString)")

    func path(_ logicalPath: String) -> String {
        root.appendingPathComponent(logicalPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).path
    }

    func prepare(in database: LibraryDatabase) async throws {
        try await database.writer.write { connection in
            for var file in try FileRecord.fetchAll(connection) {
                guard file.path.hasPrefix(self.root.path + "/") else { continue }
                try self.prepare(&file)
                try file.update(connection)
            }
        }
    }

    func prepare(_ file: inout FileRecord) throws {
        precondition(file.path.hasPrefix(root.path + "/"))
        let url = URL(fileURLWithPath: file.path)
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 37, count: Int(file.fileSize)).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(file.mtime))], ofItemAtPath: file.path)
        }
        let identity = try FileMetadataCollector.collectVerified(at: file.path)
        file.volumeUuid = identity.volumeUuid
        file.inode = identity.inode
        file.fileSize = identity.fileSize
        file.mtime = identity.mtime
        file.lightweightHash = identity.lightweightHash
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }
}
