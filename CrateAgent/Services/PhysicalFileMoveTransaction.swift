import Foundation
import GRDB

/// Compensation stays inside the serialized writer even when COMMIT fails.
final class PhysicalFileMoveTransaction {
    private var moves: [(source: String, destination: String, identity: FileMetadata, retainedSource: FileMetadata?)] = []

    static func write<Result: Sendable>(to writer: any DatabaseWriter, batchId: String,
                                        _ body: @escaping @Sendable (Database, PhysicalFileMoveTransaction) throws -> Result) async throws -> Result
    {
        try await writer.writeWithoutTransaction { database in
            let transaction = PhysicalFileMoveTransaction()
            var result: Result?
            do {
                try database.inTransaction {
                    result = try body(database, transaction)
                    return .commit
                }
            } catch {
                let failure = error
                do { try transaction.compensate() }
                catch {
                    let retainedPaths = transaction.moves.map { $0.retainedSource?.path ?? $0.destination }.joined(separator: ", ")
                    throw MoveError.compensationFailed(original: failure.localizedDescription,
                                                       compensation: "\(error.localizedDescription) Retained audio paths: \(retainedPaths)")
                }
                throw failure
            }
            do { try transaction.finish() }
            catch { throw OperationEngineError.externalSyncIncomplete(batchId: batchId, underlying: error.localizedDescription) }
            return result!
        }
    }

    func move(_ payload: RenameFilePayload, file: FileRecord) throws -> FileMetadata {
        guard file.path == payload.previousPath else { throw FileProcessingEligibilityError.superseded(fileId: payload.fileId) }
        let source = try FileMetadataCollector.collectVerified(at: file.path)
        guard !FileIdentityObservationMutation.isReplacement(file, identity: source),
              source.fileSize == file.fileSize, source.mtime == file.mtime
        else {
            throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
        }
        let destination = URL(fileURLWithPath: payload.newPath)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibraryOrganizer.OrganizerError.destinationAlreadyExists(path: destination.path)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destinationVolume = try destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        guard let destinationVolume else { throw MoveError.changedDestination(destination.path) }
        if destinationVolume == source.volumeUuid {
            try FileManager.default.moveItem(atPath: source.path, toPath: destination.path)
            moves.append((source.path, destination.path, source, nil))
        } else {
            moves.append((source.path, destination.path, source, source))
            try FileManager.default.copyItem(atPath: source.path, toPath: destination.path)
        }
        let moved = try FileMetadataCollector.collectVerified(at: destination.path)
        moves[moves.count - 1].identity = moved
        guard moved.fileSize == source.fileSize, moved.lightweightHash == source.lightweightHash else {
            throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
        }
        if moves.last?.retainedSource != nil {
            guard try FileMetadataCollector.collectVerified(at: source.path) == source else {
                throw FileProcessingEligibilityError.superseded(fileId: payload.fileId)
            }
        }
        return moved
    }

    private func compensate() throws {
        for move in moves.reversed() {
            if let source = move.retainedSource {
                guard try FileMetadataCollector.collectVerified(at: source.path) == source else {
                    throw MoveError.changedDestination(source.path)
                }
            } else {
                guard !FileManager.default.fileExists(atPath: move.source) else {
                    throw MoveError.changedDestination(move.destination)
                }
            }
            if FileManager.default.fileExists(atPath: move.destination) {
                let current = try FileMetadataCollector.collectVerified(at: move.destination)
                guard current.volumeUuid == move.identity.volumeUuid, current.inode == move.identity.inode,
                      current.fileSize == move.identity.fileSize, current.lightweightHash == move.identity.lightweightHash
                else {
                    throw MoveError.changedDestination(move.destination)
                }
                if move.retainedSource != nil {
                    try FileManager.default.removeItem(atPath: move.destination)
                }
            }
            if move.retainedSource == nil {
                try FileManager.default.moveItem(atPath: move.destination, toPath: move.source)
            }
        }
    }

    private func finish() throws {
        for move in moves {
            if let source = move.retainedSource {
                do {
                    let destination = try FileMetadataCollector.collectVerified(at: move.destination)
                    guard destination == move.identity else { throw MoveError.changedDestination(move.destination) }
                    guard try FileMetadataCollector.collectVerified(at: source.path) == source else {
                        throw MoveError.changedDestination(source.path)
                    }
                    try FileManager.default.removeItem(atPath: source.path)
                } catch { throw MoveError.cleanupFailed(source.path, error.localizedDescription) }
            }
        }
    }

    private enum MoveError: LocalizedError {
        case changedDestination(String)
        case compensationFailed(original: String, compensation: String)
        case cleanupFailed(String, String)

        var errorDescription: String? {
            switch self {
            case let .changedDestination(path): "Cannot restore moved audio because its destination changed: \(path)."
            case let .compensationFailed(original, compensation): "Move transaction failed: \(original). Restoring audio also failed: \(compensation)"
            case let .cleanupFailed(path, reason): "Audio move committed, but its retained source could not be removed at \(path): \(reason)"
            }
        }
    }
}
