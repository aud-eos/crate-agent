@testable import CrateAgent
import Foundation
import GRDB

@MainActor
final class LibraryStartupPerformanceFixture {
    let directory: URL
    let database: LibraryDatabase
    let locator: SeratoLibraryLocator
    let watchdog: SeratoWatchdog
    let reader: SeratoMembershipSnapshotReader
    let engine: OperationEngine
    let scanner: LibraryScanner
    let reconciler: SeratoMembershipReconciler
    let readiness = LibrarySyncReadiness()

    init(count: Int = 30000) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("startup-performance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try LibraryDatabase.openWAL(at: directory.appendingPathComponent("library.sqlite"))
        locator = SeratoLibraryLocator(seratoDirectory: directory.appendingPathComponent("_Serato_"))
        try FileManager.default.createDirectory(at: locator.seratoDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locator.subcratesDirectoryUrl, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locator.smartCratesDirectoryUrl, withIntermediateDirectories: true)
        watchdog = SeratoWatchdog { [] }
        reader = SeratoMembershipSnapshotReader(locator: locator, watchdog: watchdog)
        engine = OperationEngine(database: database, seratoWatchdog: watchdog, seratoLocator: locator, readiness: readiness)
        scanner = LibraryScanner(operationEngine: engine, database: database, seratoLocator: locator)
        reconciler = SeratoMembershipReconciler(database: database, operationEngine: engine, reader: reader)
        let directory = directory
        let sourceURL = locator.databaseV2Url
        let owner = try locator.supportedLibraryIdentity()
        let sourceAudio = FinalRemovalIntegrationTests.wav()
        let files = try await Task.detached(priority: .utility) {
            var audio = Data(sourceAudio.prefix(108))
            audio.replaceSubrange(4 ..< 8, with: [100, 0, 0, 0])
            audio.replaceSubrange(40 ..< 44, with: [64, 0, 0, 0])
            var records = SeratoTestEncoding.library(paths: [])
            var files: [FileRecord] = []
            files.reserveCapacity(count)
            for index in 0 ..< count {
                let url = directory.appendingPathComponent("track-\(index).wav")
                try audio.write(to: url)
                let identity = try FileMetadataCollector.collectVerified(at: url.path)
                let artist = "Artist \(index % 500)"
                let title = "Track \(index)"
                var payload = SeratoTestEncoding.record("pfil", Data(url.path.utf16.flatMap { codeUnit in [UInt8(codeUnit >> 8), UInt8(codeUnit & 255)] }))
                for (tag, value) in [("tart", artist), ("tsng", title)] {
                    payload += SeratoTestEncoding.record(tag, Data(value.utf16.flatMap { codeUnit in [UInt8(codeUnit >> 8), UInt8(codeUnit & 255)] }))
                }
                records += SeratoTestEncoding.record("otrk", payload)
                var file = FileRecord(path: identity.path, volumeUuid: identity.volumeUuid, inode: identity.inode,
                                      fileSize: identity.fileSize, mtime: identity.mtime, lightweightHash: identity.lightweightHash,
                                      artist: artist, title: title)
                file.libraryMembership = .active
                file.fileAvailability = .available
                file.seratoLibraryId = owner
                files.append(file)
            }
            try records.write(to: sourceURL)
            return files
        }.value
        try await database.writer.write { connection in
            for var file in files {
                try file.insert(connection)
            }
        }
    }

    func makeSession(checkpointed: Bool = false) -> SeratoLibrarySyncSession {
        SeratoLibrarySyncSession(reader: reader, reconciler: reconciler, scanner: scanner,
                                 operationEngine: engine, watchdog: watchdog, readiness: readiness,
                                 checkpointStore: checkpointed ? SyncCheckpointStore(database: database) : nil,
                                 watchRoots: [directory.path])
    }

    func cleanup() throws {
        try FileManager.default.removeItem(at: directory)
    }
}
