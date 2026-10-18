import Foundation
import GRDB

/// Resolves a library row afresh and checks that the file at its path is
/// still that row's recording before it is played, opened or revealed. A
/// path alone is only a label (invariant 4): a Missing row's path can later
/// hold a different file.
struct LibraryFileAccess {
    private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
    }

    func verifiedRecord(fileID: Int64) async throws -> FileRecord {
        guard let record = try await database.writer.read({ connection in try FileRecord.fetchOne(connection, key: fileID) }) else {
            throw LibraryFileAccessError.notInLibrary(fileID: fileID)
        }
        let filename = (record.path as NSString).lastPathComponent
        guard record.fileAvailability == .available else {
            throw LibraryFileAccessError.unavailable(filename: filename, availability: record.fileAvailability)
        }
        try await Task.detached { try Self.verifyOnDisk(record, filename: filename) }.value
        return record
    }

    private static func verifyOnDisk(_ record: FileRecord, filename: String) throws {
        guard FileManager.default.fileExists(atPath: record.path) else {
            throw LibraryFileAccessError.unavailable(filename: filename, availability: .missing)
        }
        let current: FileMetadata
        do {
            current = try FileMetadataCollector.collectVerified(at: record.path)
        } catch {
            throw LibraryFileAccessError.unreadable(filename: filename, reason: error.localizedDescription)
        }
        guard FileIdentityObservationMutation.matchesContent(record, identity: current) else {
            throw LibraryFileAccessError.replaced(filename: filename)
        }
    }
}

enum LibraryFileAccessError: LocalizedError, Equatable {
    case notInLibrary(fileID: Int64)
    case unavailable(filename: String, availability: FileAvailability)
    case unreadable(filename: String, reason: String)
    case replaced(filename: String)

    var filename: String {
        switch self {
        case let .notInLibrary(fileID): LibraryFileAccessMessages.unknownFile(fileID)
        case let .unavailable(filename, _), let .unreadable(filename, _), let .replaced(filename): filename
        }
    }

    /// Why the file was not used, to follow "Can't <verb> <filename>: ".
    var detail: String {
        switch self {
        case .notInLibrary: LibraryFileAccessMessages.notInLibrary
        case let .unavailable(_, availability): LibraryFileAccessMessages.unavailable(availability)
        case let .unreadable(_, reason): LibraryFileAccessMessages.unreadable(reason)
        case .replaced: LibraryFileAccessMessages.replaced
        }
    }

    var errorDescription: String? {
        "\(filename): \(detail)"
    }
}
