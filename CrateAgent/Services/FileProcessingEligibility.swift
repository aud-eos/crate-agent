import Foundation

public enum FileProcessingEligibility {
    public static func requireProcessable(_ file: FileRecord) throws {
        guard file.libraryMembership == .active, file.fileAvailability == .available else {
            throw FileProcessingEligibilityError.unavailable(fileId: file.id, membership: file.libraryMembership, availability: file.fileAvailability)
        }
    }
}

extension TrackMutation {
    var processingFileID: Int64? {
        switch self {
        case .indexNewFile, .observeFileLocation, .setFileLibraryState, .beginFileImport, .removeFile: return nil
        case let .setMetadata(payload): return payload.isSeratoAuthoritative == true ? nil : payload.fileId
        case let .renameFile(payload): return payload.fileId
        case let .commitMetadataToSerato(payload): return payload.fileId
        case let .addTrackToSerato(payload): return payload.fileId
        case let .writeFileTags(payload): return payload.fileId
        case let .trashFile(payload): return payload.fileId
        case let .removeTrackFromSerato(payload): return payload.fileId
        case let .removeFileFromCrates(payload): return payload.fileId
        case let .applyMusicBrainzMatch(payload): return payload.fileID
        case let .revertMusicBrainzMatch(payload): return payload.applied.fileID
        }
    }
}

public enum FileProcessingEligibilityError: LocalizedError {
    case unavailable(fileId: Int64?, membership: LibraryMembership, availability: FileAvailability)
    case superseded(fileId: Int64)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(fileId, membership, availability):
            return "File \(fileId.map(String.init) ?? "unknown") cannot be processed (\(membership.rawValue), \(availability.rawValue))."
        case let .superseded(fileId):
            return "File \(fileId) work was superseded by a library membership change."
        }
    }
}
