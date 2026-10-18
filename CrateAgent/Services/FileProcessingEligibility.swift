import Foundation
import GRDB

public enum FileProcessingEligibility {
    public static let activeSQL = "files.library_membership != '\(LibraryMembership.retired.rawValue)'"
    public static let processableSQL = "files.library_membership = '\(LibraryMembership.active.rawValue)' AND files.file_availability = '\(FileAvailability.available.rawValue)'"

    public static func isProcessable(membership: LibraryMembership, availability: FileAvailability) -> Bool {
        membership == .active && availability == .available
    }

    public static func requireCurrent(_ token: FileMembershipToken, in database: Database) throws {
        _ = try currentFile(token, in: database)
    }

    static func currentFile(_ token: FileMembershipToken, in database: Database) throws -> FileRecord {
        guard let file = try FileRecord.fetchOne(database, key: token.fileId), file.membershipRevision == token.revision else {
            throw FileProcessingEligibilityError.superseded(fileId: token.fileId)
        }
        try requireProcessable(file)
        return file
    }

    public static func requireProcessable(_ file: FileRecord) throws {
        guard isProcessable(membership: file.libraryMembership, availability: file.fileAvailability) else {
            throw FileProcessingEligibilityError.unavailable(fileId: file.id, membership: file.libraryMembership, availability: file.fileAvailability, path: file.path)
        }
    }
}

public extension QueryInterfaceRequest where RowDecoder == FileRecord {
    func activeInLibrary() -> Self {
        filter(sql: FileProcessingEligibility.activeSQL)
    }

    func processableInLibrary() -> Self {
        filter(sql: FileProcessingEligibility.processableSQL)
    }
}

extension TrackMutation {
    var processingFileID: Int64? {
        switch self {
        case .indexNewFile, .observeFileLocation, .observeFileIdentity, .observeFileMetadata, .recordSubsecondModificationTime, .setFileLibraryState, .beginFileImport, .removeFile, .songFamily: nil
        // Records a review of several files, each rechecked in the transaction.
        case .duplicateLabelReview: nil
        // Writes a recording's work, which no file or Serato field mirrors.
        case .recordMusicBrainzWork: nil
        case let .setMetadata(payload): payload.isSeratoAuthoritative == true ? nil : payload.fileId
        case let .renameFile(payload): payload.fileId
        case let .commitMetadataToSerato(payload): payload.fileId
        case let .addTrackToSerato(payload): payload.fileId
        case let .writeFileTags(payload): payload.fileId
        case let .trashFile(payload): payload.fileId
        case let .removeTrackFromSerato(payload): payload.fileId
        case let .removeFileFromCrates(payload): payload.fileId
        case let .applyMusicBrainzMatch(payload): payload.fileID
        case let .revertMusicBrainzMatch(payload): payload.applied.fileID
        case let .discardQueuedSeratoChange(payload): payload.fileId
        }
    }

    var tokenFileID: Int64? {
        if case let .removeFile(payload) = self {
            return payload.fileId
        }
        return processingFileID
    }
}

public enum FileProcessingEligibilityError: LocalizedError {
    case unavailable(fileId: Int64?, membership: LibraryMembership, availability: FileAvailability, path: String? = nil)
    case superseded(fileId: Int64)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(fileId, membership, availability, path):
            let name = path.map { ($0 as NSString).lastPathComponent } ?? "File \(fileId.map(String.init) ?? "unknown")"
            return "\(name) cannot be processed (\(membership.displayTitle), \(availability.displayTitle))."
        case let .superseded(fileId):
            return "File \(fileId) work was superseded by a library membership change."
        }
    }
}
