import Foundation
import GRDB

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
    var write: SeratoPendingWrite
    let eventId: Int64
    let originalIdentity: FileMetadata
    var originalReferencePaths: [String] = []
    var externalBaseline: SeratoMetadata?
    var requiredKeeper: FileActionAuthority?
    var cleanupReceipt: DuplicateCleanupReceipt?
}

enum SeratoWriteEligibility {
    static func resolved(_ guarded: GuardedSeratoWrite, file: FileRecord) -> GuardedSeratoWrite {
        var result = guarded
        for path in guarded.write.referencePaths where !result.originalReferencePaths.contains(path) {
            result.originalReferencePaths.append(path)
        }
        switch guarded.write {
        case let .fileTagWrite(write):
            result.write = .fileTagWrite(.init(absolutePath: file.path, metadata: write.metadata, year: write.year, clearYear: write.clearYear))
        case .trashFile:
            result.write = .trashFile(.init(absolutePath: file.path))
        case let .addTrack(write):
            result.write = .addTrack(.init(absolutePath: file.path, metadata: write.metadata))
        case let .metadataUpdate(write):
            result.write = .metadataUpdate(.init(absolutePath: referencePath(write.absolutePath, file: file), metadata: write.metadata))
        case let .removeFromDatabase(write):
            result.write = .removeFromDatabase(.init(absolutePath: referencePath(write.absolutePath, file: file)))
        case let .removeFromCrates(write):
            result.write = .removeFromCrates(.init(absolutePath: referencePath(write.absolutePath, file: file)))
        case .rename: break
        }
        return result
    }

    private static func referencePath(_ original: String, file: FileRecord) -> String {
        if original == file.path || !FileManager.default.fileExists(atPath: original) {
            return original
        }
        return file.path
    }

    static func requirePhysicalTarget(_ guarded: GuardedSeratoWrite, file: FileRecord, in database: Database) throws {
        try guarded.requiredKeeper?.validate(in: database)
        let current: FileMetadata
        do { current = try FileMetadataCollector.collectVerified(at: file.path) }
        catch { throw FileProcessingEligibilityError.superseded(fileId: guarded.token.fileId) }
        guard !FileIdentityObservationMutation.isReplacement(file, identity: current) else {
            throw FileProcessingEligibilityError.superseded(fileId: guarded.token.fileId)
        }
        var original = guarded.originalIdentity
        let observations = try EventRecord.filter(Column("file_id") == guarded.token.fileId && Column("event_type") == EventType.fileIdentityObserved.rawValue && Column("event_id") > guarded.eventId).order(Column("event_id")).fetchAll(database)
        for event in observations {
            let payload = try JSONDecoder().decode(ObserveFileIdentityPayload.self, from: Data(event.payloadJson.utf8))
            if payload.ownedTagWriteEventID != nil, payload.expectedRevision == guarded.token.revision,
               sameContent(original, payload.previousIdentity)
            {
                original = payload.identity
            }
        }
        guard sameContent(original, current) else { throw FileProcessingEligibilityError.superseded(fileId: guarded.token.fileId) }
        switch guarded.write {
        case let .fileTagWrite(write): try requirePath(write.absolutePath, file: file)
        case let .trashFile(write): try requirePath(write.absolutePath, file: file)
        case let .addTrack(write): try requirePath(write.absolutePath, file: file)
        case let .metadataUpdate(write): try requireReference(write.absolutePath, file: file)
        case let .removeFromDatabase(write): try requireReference(write.absolutePath, file: file)
        case let .removeFromCrates(write): try requireReference(write.absolutePath, file: file)
        case let .rename(write):
            try requireReference(write.oldAbsolutePath, file: file)
            if write.newAbsolutePath != file.path, FileManager.default.fileExists(atPath: write.newAbsolutePath) {
                throw FileProcessingEligibilityError.superseded(fileId: guarded.token.fileId)
            }
        }
        guard (try? FileMetadataCollector.collectVerified(at: file.path)) == current else {
            throw FileProcessingEligibilityError.superseded(fileId: guarded.token.fileId)
        }
    }

    private static func requirePath(_ path: String, file: FileRecord) throws {
        guard path == file.path else { throw FileProcessingEligibilityError.superseded(fileId: file.id!) }
    }

    private static func requireReference(_ path: String, file: FileRecord) throws {
        guard path == file.path || !FileManager.default.fileExists(atPath: path) else {
            throw FileProcessingEligibilityError.superseded(fileId: file.id!)
        }
    }

    private static func sameContent(_ original: FileMetadata, _ current: FileMetadata) -> Bool {
        original.fileSize == current.fileSize && original.mtime == current.mtime
            && (original.lightweightHash == nil || original.lightweightHash == current.lightweightHash)
    }

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
        guard file.lastProjectionInvalidationRevision == nil else { return nil }
        return FileMembershipToken(fileId: fileId, revision: file.membershipRevision)
    }
}
