import Foundation

public struct FileMembershipToken: Codable, Sendable, Equatable, Hashable {
    public let fileId: Int64
    public let revision: Int64

    public init(fileId: Int64, revision: Int64) {
        self.fileId = fileId
        self.revision = revision
    }
}

struct GuardedSeratoWrite: Sendable, Equatable {
    let token: FileMembershipToken
    let write: SeratoPendingWrite
    let eventId: Int64
}

enum SeratoWriteEligibility {
    static func permits(_ write: GuardedSeratoWrite, file: FileRecord?) -> Bool {
        guard let file, file.id == write.token.fileId,
              file.membershipRevision == write.token.revision else { return false }
        return permits(write.write, file: file)
    }

    static func permits(_ write: SeratoPendingWrite, file: FileRecord) -> Bool {
        if case .addTrack = write {
            return file.libraryMembership == .pendingImport && file.fileAvailability == .available
        }
        return file.libraryMembership == .active && file.fileAvailability == .available
    }

    struct ProjectionHeader: Decodable {
        let membershipRevision: Int64?
    }

    static func replayToken(event: EventRecord, file: FileRecord) throws -> FileMembershipToken? {
        let header = try JSONDecoder().decode(ProjectionHeader.self, from: Data(event.payloadJson.utf8))
        guard let fileId = file.id else { return nil }
        if let revision = header.membershipRevision {
            guard revision == file.membershipRevision else { return nil }
            return FileMembershipToken(fileId: fileId, revision: revision)
        }
        guard file.lastRetirementRevision == nil else { return nil }
        return FileMembershipToken(fileId: fileId, revision: file.membershipRevision)
    }
}
