import Darwin
import Foundation
import os

/// UniFFI emits only String/Optional<String> value fields, without Sendable conformance.
extension SeratoTrackRecord: @unchecked Sendable {}

struct SeratoSourceIdentity: Codable, Hashable, Sendable {
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
        return Self(metadata)
    }

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        size = metadata.st_size
        modifiedSeconds = metadata.st_mtimespec.tv_sec
        modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        changedSeconds = metadata.st_ctimespec.tv_sec
        changedNanoseconds = metadata.st_ctimespec.tv_nsec
    }
}

struct SeratoMembershipSnapshot: Sendable {
    let libraryID: String
    let records: [SeratoTrackRecord]
    let source: SeratoSourceIdentity
    let generation: UInt64
}

struct SeratoSnapshotAuthorization: Sendable {
    let check: @Sendable () throws -> Void
}

enum SeratoMembershipSnapshotError: LocalizedError, Equatable {
    case sourceUnavailable
    case malformedSource
    case sourceChanged
    case seratoRunning
    case unsupportedSource

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "Cannot read Serato's saved database V2. Check that the library is available, then retry sync."
        case .malformedSource: "Serato's saved database V2 is incomplete or corrupt. Save the library in Serato, close Serato, then retry sync."
        case .sourceChanged: "Serato's saved library changed during synchronization. Close Serato and retry sync."
        case .seratoRunning: "Waiting for Serato to close before synchronizing its saved library."
        case .unsupportedSource: "This Serato library source cannot be validated. Check the configured library location before retrying sync."
        }
    }
}

@MainActor
final class SeratoMembershipSnapshotReader {
    private let locator: SeratoLibraryLocator
    private let watchdog: SeratoWatchdog
    private let parse: @Sendable (String) throws -> [SeratoTrackRecord]
    private let afterParsing: @Sendable () async throws -> Void
    private var generation: UInt64 = 0
    private var acceptedSnapshot: SeratoMembershipSnapshot?
    private var acceptedWatchdogRevision: UInt64?
    private let currentGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))

    init(
        locator: SeratoLibraryLocator,
        watchdog: SeratoWatchdog,
        afterParsing: @escaping @Sendable () async throws -> Void = {},
        parse: @escaping @Sendable (String) throws -> [SeratoTrackRecord] = { path in try readDatabaseRecordsStrict(databasePath: path) }
    ) {
        self.locator = locator
        self.watchdog = watchdog
        self.afterParsing = afterParsing
        self.parse = parse
    }

    func read() async throws -> SeratoMembershipSnapshot {
        watchdog.refresh()
        guard !watchdog.isSeratoRunning else {
            throw SeratoMembershipSnapshotError.seratoRunning
        }
        let watchdogRevision = watchdog.stateRevision
        generation += 1
        let requestedGeneration = generation
        currentGeneration.withLock { value in value = requestedGeneration }
        let locator = locator
        let afterParsing = afterParsing
        let parse = parse
        let task = Task.detached {
            try Task.checkCancellation()
            let directory = locator.seratoDirectory.resolvingSymlinksInPath().standardizedFileURL
            guard directory.isFileURL else {
                throw SeratoMembershipSnapshotError.unsupportedSource
            }
            let sourceURL = locator.databaseV2Url
            let before = try SeratoSourceIdentity.read(sourceURL)
            let libraryID: String
            do {
                libraryID = try locator.supportedLibraryIdentity()
            } catch SeratoMembershipSnapshotError.unsupportedSource {
                throw SeratoMembershipSnapshotError.unsupportedSource
            } catch {
                throw SeratoMembershipSnapshotError.sourceUnavailable
            }
            let records: [SeratoTrackRecord]
            do {
                records = try parse(sourceURL.path)
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
                libraryID: libraryID,
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
        acceptedSnapshot = snapshot
        acceptedWatchdogRevision = watchdogRevision
        return snapshot
    }

    func authorizeCachedSource(libraryID: String, source: SeratoSourceIdentity) async throws -> SeratoSnapshotAuthorization {
        watchdog.refresh()
        guard !watchdog.isSeratoRunning else { throw SeratoMembershipSnapshotError.seratoRunning }
        let revision = watchdog.stateRevision
        generation += 1
        let requestedGeneration = generation
        currentGeneration.withLock { value in value = requestedGeneration }
        let locator = locator
        try await Task.detached {
            guard try SeratoSourceIdentity.read(locator.databaseV2Url) == source,
                  try locator.supportedLibraryIdentity() == libraryID,
                  try SeratoSourceIdentity.read(locator.databaseV2Url) == source
            else {
                throw SeratoMembershipSnapshotError.sourceChanged
            }
        }.value
        try Task.checkCancellation()
        watchdog.refresh()
        guard watchdog.isClosed(atRevision: revision) else { throw SeratoMembershipSnapshotError.seratoRunning }
        guard generation == requestedGeneration else { throw SeratoMembershipSnapshotError.sourceChanged }
        let snapshot = SeratoMembershipSnapshot(libraryID: libraryID, records: [], source: source, generation: requestedGeneration)
        acceptedSnapshot = snapshot
        acceptedWatchdogRevision = revision
        return try await authorization(for: snapshot)
    }

    func cachedSnapshot(records: [SeratoTrackRecord]) throws -> SeratoMembershipSnapshot {
        guard let acceptedSnapshot, acceptedSnapshot.generation == generation else { throw SeratoMembershipSnapshotError.sourceChanged }
        return SeratoMembershipSnapshot(libraryID: acceptedSnapshot.libraryID, records: records, source: acceptedSnapshot.source, generation: generation)
    }

    func validate(_ snapshot: SeratoMembershipSnapshot) async throws {
        watchdog.refresh()
        guard !watchdog.isSeratoRunning, watchdog.stateRevision == acceptedWatchdogRevision else {
            throw SeratoMembershipSnapshotError.seratoRunning
        }
        guard snapshot.generation == generation,
              acceptedSnapshot?.generation == snapshot.generation,
              acceptedSnapshot?.libraryID == snapshot.libraryID,
              acceptedSnapshot?.source == snapshot.source
        else {
            throw SeratoMembershipSnapshotError.sourceChanged
        }
        let locator = locator
        let current = try await Task.detached { try SeratoSourceIdentity.read(locator.databaseV2Url) }.value
        guard current == snapshot.source, snapshot.generation == generation else {
            throw SeratoMembershipSnapshotError.sourceChanged
        }
        watchdog.refresh()
        guard !watchdog.isSeratoRunning, watchdog.stateRevision == acceptedWatchdogRevision else {
            throw SeratoMembershipSnapshotError.seratoRunning
        }
    }

    func authorization(for snapshot: SeratoMembershipSnapshot) async throws -> SeratoSnapshotAuthorization {
        try await validate(snapshot)
        guard let revision = acceptedWatchdogRevision else { throw SeratoMembershipSnapshotError.sourceChanged }
        let currentGeneration = currentGeneration
        let watchdog = watchdog
        let sourceURL = locator.databaseV2Url
        let locator = locator
        return SeratoSnapshotAuthorization {
            try Task.checkCancellation()
            guard currentGeneration.withLock({ value in value == snapshot.generation }) else {
                throw SeratoMembershipSnapshotError.sourceChanged
            }
            guard watchdog.isClosed(atRevision: revision) else {
                throw SeratoMembershipSnapshotError.seratoRunning
            }
            guard try SeratoSourceIdentity.read(sourceURL) == snapshot.source,
                  try locator.supportedLibraryIdentity() == snapshot.libraryID
            else {
                throw SeratoMembershipSnapshotError.sourceChanged
            }
        }
    }
}
