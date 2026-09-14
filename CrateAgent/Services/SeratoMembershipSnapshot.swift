import Darwin
import Foundation

/// UniFFI emits only String/Optional<String> value fields, without Sendable conformance.
extension SeratoTrackRecord: @unchecked Sendable {}

struct SeratoSourceIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    static func read(_ url: URL) throws -> Self {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw SeratoMembershipSnapshotError.sourceUnavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw SeratoMembershipSnapshotError.unsupportedSource
        }
        return Self(
            device: metadata.st_dev, inode: metadata.st_ino, size: metadata.st_size,
            modifiedSeconds: metadata.st_mtimespec.tv_sec,
            modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
            changedSeconds: metadata.st_ctimespec.tv_sec,
            changedNanoseconds: metadata.st_ctimespec.tv_nsec
        )
    }
}

struct SeratoMembershipSnapshot: Sendable {
    let libraryID: String
    let records: [SeratoTrackRecord]
    let source: SeratoSourceIdentity
    let generation: UInt64
}

enum SeratoMembershipSnapshotError: Error, Equatable {
    case sourceUnavailable
    case malformedSource
    case sourceChanged
    case seratoRunning
    case unsupportedSource
}

@MainActor
final class SeratoMembershipSnapshotReader {
    private let locator: SeratoLibraryLocator
    private let watchdog: SeratoWatchdog
    private let afterParsing: @Sendable () async throws -> Void
    private var generation: UInt64 = 0

    init(
        locator: SeratoLibraryLocator,
        watchdog: SeratoWatchdog,
        afterParsing: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.locator = locator
        self.watchdog = watchdog
        self.afterParsing = afterParsing
    }

    func read() async throws -> SeratoMembershipSnapshot {
        watchdog.refresh()
        guard !watchdog.isSeratoRunning else {
            throw SeratoMembershipSnapshotError.seratoRunning
        }
        let watchdogRevision = watchdog.stateRevision
        generation += 1
        let requestedGeneration = generation
        let locator = locator
        let afterParsing = afterParsing
        let task = Task.detached {
            try Task.checkCancellation()
            let directory = locator.seratoDirectory.resolvingSymlinksInPath().standardizedFileURL
            guard directory.isFileURL else {
                throw SeratoMembershipSnapshotError.unsupportedSource
            }
            let sourceURL = locator.databaseV2Url
            let before = try SeratoSourceIdentity.read(sourceURL)
            let volume: URLResourceValues
            do {
                volume = try directory.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsLocalKey])
            } catch {
                throw SeratoMembershipSnapshotError.sourceUnavailable
            }
            guard volume.volumeIsLocal == true, let volumeID = volume.volumeUUIDString else {
                throw SeratoMembershipSnapshotError.unsupportedSource
            }
            let records: [SeratoTrackRecord]
            do {
                records = try readDatabaseRecordsStrict(databasePath: sourceURL.path)
            } catch CoreError.IoError {
                throw SeratoMembershipSnapshotError.sourceUnavailable
            } catch {
                guard try before == SeratoSourceIdentity.read(sourceURL) else {
                    throw SeratoMembershipSnapshotError.sourceChanged
                }
                throw SeratoMembershipSnapshotError.malformedSource
            }
            try await afterParsing()
            try Task.checkCancellation()
            guard try before == (SeratoSourceIdentity.read(sourceURL)),
                  directory == locator.seratoDirectory.resolvingSymlinksInPath().standardizedFileURL
            else {
                throw SeratoMembershipSnapshotError.sourceChanged
            }
            return SeratoMembershipSnapshot(
                libraryID: "\(volumeID):\(directory.path.precomposedStringWithCanonicalMapping)",
                records: records, source: before, generation: requestedGeneration
            )
        }
        let snapshot = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        watchdog.refresh()
        guard !watchdog.isSeratoRunning, watchdog.stateRevision == watchdogRevision else {
            throw SeratoMembershipSnapshotError.seratoRunning
        }
        guard generation == requestedGeneration else {
            throw SeratoMembershipSnapshotError.sourceChanged
        }
        return snapshot
    }
}
