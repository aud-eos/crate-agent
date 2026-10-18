import Foundation
import GRDB
import os.log

/// Resolves a library row afresh and checks that the file at its path is
/// still that row's recording before it is played, opened or revealed. A
/// path alone is only a label (invariant 4): a Missing row's path can later
/// hold a different file.
struct LibraryFileAccess {
    private static let logger = Logger(subsystem: "com.crateagent.app", category: "LibraryFileAccess")

    private let database: LibraryDatabase
    private let audioEvidence: DuplicateEvidenceVerifier

    init(database: LibraryDatabase, audioEvidence: DuplicateEvidenceVerifier) {
        self.database = database
        self.audioEvidence = audioEvidence
    }

    /// A file whose bytes changed since its row was indexed is still handed
    /// over when it decodes to the same PCM as before, as after Serato writes
    /// tags into it; anything else is refused as replaced until sync records it.
    func verifiedRecord(fileID: Int64) async throws -> FileRecord {
        guard let record = try await database.writer.read({ connection in try FileRecord.fetchOne(connection, key: fileID) }) else {
            throw LibraryFileAccessError.notInLibrary(fileID: fileID)
        }
        let filename = (record.path as NSString).lastPathComponent
        guard record.fileAvailability == .available else {
            throw LibraryFileAccessError.unavailable(filename: filename, availability: record.fileAvailability)
        }
        if try await Task.detached(operation: { try Self.matchesIndexedContent(record, filename: filename) }).value {
            recordIndexedAudio(of: record, fileID: fileID)
        } else if try await !audioEvidence.decodesToIndexedAudio(record) {
            throw LibraryFileAccessError.replaced(filename: filename)
        }
        return record
    }

    private func recordIndexedAudio(of record: FileRecord, fileID: Int64) {
        let audioEvidence = audioEvidence
        Task.detached(priority: .background) {
            do {
                try await audioEvidence.recordIndexedAudio(of: record)
            } catch {
                Self.logger.error("Couldn't record the decoded audio of file \(fileID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func matchesIndexedContent(_ record: FileRecord, filename: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: record.path) else {
            throw LibraryFileAccessError.unavailable(filename: filename, availability: .missing)
        }
        let current: FileMetadata
        do {
            current = try FileMetadataCollector.collectVerified(at: record.path)
        } catch {
            throw LibraryFileAccessError.unreadable(filename: filename, reason: error.localizedDescription)
        }
        return FileIdentityObservationMutation.matchesContent(record, identity: current)
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
