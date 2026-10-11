import Darwin
import Foundation
import GRDB

/// Compensation stays inside the serialized writer even when COMMIT fails.
final class PhysicalFileMoveTransaction {
    private let afterTransfer: @Sendable (URL) throws -> Void
    private var moves: [(source: String, destination: String, identity: OwnedAudioIdentity?, retainedSource: OwnedAudioIdentity?)] = []

    private init(afterTransfer: @escaping @Sendable (URL) throws -> Void) {
        self.afterTransfer = afterTransfer
    }

    static func write<Result: Sendable>(to writer: any DatabaseWriter, batchId: String,
                                        afterTransfer: @escaping @Sendable (URL) throws -> Void = { _ in },
                                        _ body: @escaping @Sendable (Database, PhysicalFileMoveTransaction) throws -> Result) async throws -> Result
    {
        try await writer.writeWithoutTransaction { database in
            let transaction = PhysicalFileMoveTransaction(afterTransfer: afterTransfer)
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
                    let retainedPaths = transaction.moves.map { $0.retainedSource?.metadata.path ?? $0.destination }.joined(separator: ", ")
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

    func move(_ payload: RenameFilePayload, file: FileRecord, expectedSource: SeratoSourceIdentity? = nil) throws -> FileMetadata {
        guard file.path == payload.previousPath else { throw FileProcessingEligibilityError.superseded(fileId: payload.fileId) }
        let ownedSource = try OwnedAudioIdentity.read(at: file.path)
        if let expectedSource, ownedSource.change != expectedSource {
            throw MoveError.sourceChanged(file.path)
        }
        let source = ownedSource.metadata
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
            moves.append((source.path, destination.path, nil, nil))
            let expected = FileMetadata(path: destination.path, volumeUuid: source.volumeUuid, inode: source.inode,
                                        fileSize: source.fileSize, mtime: source.mtime, lightweightHash: source.lightweightHash)
            let ownedDestination = try OwnedAudioIdentity.read(at: destination.path)
            guard ownedDestination.metadata == expected, ownedDestination.digest == ownedSource.digest else {
                throw MoveError.changedDestination(destination.path)
            }
            moves[moves.count - 1].identity = ownedDestination
            try afterTransfer(destination)
            guard try OwnedAudioIdentity.read(at: destination.path) == ownedDestination else {
                throw MoveError.changedDestination(destination.path)
            }
            return expected
        }
        moves.append((source.path, destination.path, nil, ownedSource))
        let moved = try copyOwnedDestination(source: ownedSource, destination: destination, volume: destinationVolume)
        moves[moves.count - 1].identity = moved
        return moved.metadata
    }

    private func copyOwnedDestination(source ownedSource: OwnedAudioIdentity, destination: URL, volume: String) throws -> OwnedAudioIdentity {
        let source = ownedSource.metadata
        return try withDescriptor(path: source.path, flags: O_RDONLY | O_NOFOLLOW) { sourceDescriptor in
            let sourceStat = try descriptorStat(sourceDescriptor, path: source.path)
            guard Int64(sourceStat.st_ino) == source.inode, sourceStat.st_size == source.fileSize,
                  sourceStat.st_mtimespec.tv_sec == source.mtime
            else {
                throw MoveError.changedDestination(source.path)
            }
            return try withDescriptor(path: destination.path, flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW) { destinationDescriptor in
                let ownedStat = try descriptorStat(destinationDescriptor, path: destination.path)
                guard fcopyfile(sourceDescriptor, destinationDescriptor, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                    throw posixFailure(operation: "Copy audio and metadata", path: destination.path)
                }
                let ownedDestination = try OwnedAudioIdentity.read(at: destination.path)
                guard ownedDestination.change.inode == ownedStat.st_ino,
                      ownedDestination.digest == ownedSource.digest else { throw MoveError.changedDestination(destination.path) }
                try afterTransfer(destination)
                let currentDestination = try OwnedAudioIdentity.read(at: destination.path)
                let copied = currentDestination.metadata
                guard copied.inode == Int64(ownedStat.st_ino), copied.volumeUuid == volume,
                      copied.fileSize == source.fileSize, copied.mtime == source.mtime,
                      copied.lightweightHash == source.lightweightHash,
                      try OwnedAudioIdentity.read(at: source.path) == ownedSource,
                      currentDestination == ownedDestination
                else {
                    throw MoveError.changedDestination(destination.path)
                }
                return ownedDestination
            }
        }
    }

    private func withDescriptor<Value>(path: String, flags: Int32, _ body: (Int32) throws -> Value) throws -> Value {
        let descriptor = Darwin.open(path, flags, mode_t(0o600))
        guard descriptor >= 0 else { throw posixFailure(operation: "Open audio", path: path) }
        let outcome = Result { try body(descriptor) }
        if Darwin.close(descriptor) != 0 {
            let closeFailure = posixFailure(operation: "Close audio", path: path)
            if case let .failure(original) = outcome {
                throw MoveError.descriptorFailure("\(original.localizedDescription); \(closeFailure.localizedDescription)")
            }
            throw closeFailure
        }
        return try outcome.get()
    }

    private func descriptorStat(_ descriptor: Int32, path: String) throws -> stat {
        var identity = stat()
        guard fstat(descriptor, &identity) == 0 else { throw posixFailure(operation: "Inspect audio", path: path) }
        return identity
    }

    private func posixFailure(operation: String, path: String) -> NSError {
        let errorCode = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode), userInfo: [NSLocalizedDescriptionKey: "\(operation) at \(path): \(String(cString: strerror(errorCode)))"])
    }

    private func compensate() throws {
        for move in moves.reversed() {
            if let source = move.retainedSource {
                guard try OwnedAudioIdentity.read(at: source.metadata.path) == source else {
                    throw MoveError.changedDestination(source.metadata.path)
                }
            } else {
                guard !FileManager.default.fileExists(atPath: move.source) else {
                    throw MoveError.changedDestination(move.destination)
                }
            }
            if FileManager.default.fileExists(atPath: move.destination) {
                let current = try OwnedAudioIdentity.read(at: move.destination)
                guard current == move.identity else {
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
                    let destination = try OwnedAudioIdentity.read(at: move.destination)
                    guard destination == move.identity else { throw MoveError.changedDestination(move.destination) }
                    guard try OwnedAudioIdentity.read(at: source.metadata.path) == source else {
                        throw MoveError.changedDestination(source.metadata.path)
                    }
                    try FileManager.default.removeItem(atPath: source.metadata.path)
                } catch { throw MoveError.cleanupFailed(source.metadata.path, error.localizedDescription) }
            }
        }
    }

    private enum MoveError: LocalizedError {
        case sourceChanged(String)
        case changedDestination(String)
        case compensationFailed(original: String, compensation: String)
        case cleanupFailed(String, String)
        case descriptorFailure(String)

        var errorDescription: String? {
            switch self {
            case let .sourceChanged(path): "Audio at \(path) changed since the preview. Re-scan before moving it."
            case let .changedDestination(path): "Cannot restore moved audio because its destination changed: \(path)."
            case let .compensationFailed(original, compensation): "Move transaction failed: \(original). Restoring audio also failed: \(compensation)"
            case let .cleanupFailed(path, reason): "Audio move committed, but its retained source could not be removed at \(path): \(reason)"
            case let .descriptorFailure(reason): reason
            }
        }
    }
}
