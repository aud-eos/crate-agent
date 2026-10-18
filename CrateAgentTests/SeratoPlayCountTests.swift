@testable import CrateAgent
import GRDB
import XCTest

@MainActor
final class SeratoPlayCountTests: XCTestCase {
    private let sharedHash = Data([0xAB, 0xCD])
    private let base: UInt32 = 1_700_000_000
    private var serato: SeratoRunningFlag!
    private var locator: SeratoLibraryLocator!
    private var database: LibraryDatabase!
    private var watchdog: SeratoWatchdog!
    private var service: SeratoPlayCountService!

    final class SeratoRunningFlag {
        var running = false
    }

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlayCounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let serato = SeratoRunningFlag()
        self.serato = serato
        locator = SeratoLibraryLocator(seratoDirectory: directory)
        database = try LibraryDatabase.openInMemory()
        watchdog = SeratoWatchdog { serato.running ? ["com.serato.dj"] : [] }
        service = SeratoPlayCountService(database: database, seratoLocator: locator, watchdog: watchdog)
    }

    private nonisolated func insertFile(_ path: String, mtime: Int64 = 1, in connection: Database) throws -> Int64 {
        var file = try FileRecord(path: path, volumeUuid: "play-count-fixture", inode: Int64(FileRecord.fetchCount(connection)) + 1,
                                  fileSize: 4096, mtime: mtime, lightweightHash: sharedHash, bitrateKbps: 320)
        file.libraryMembership = .active
        file.fileAvailability = .available
        try file.insert(connection)
        return try XCTUnwrap(file.id)
    }

    private func play(_ path: String, at offset: UInt32, played: Bool = true) -> SyntheticSeratoHistory.Entry {
        SyntheticSeratoHistory.Entry(path: path, startedAt: base + offset, played: played)
    }

    private nonisolated func milliseconds(_ offset: UInt32) -> Int64 {
        Int64(base + offset) * 1000
    }

    private func playCounts() async throws -> [Int64: Int] {
        let groups = try await database.writer.read { connection in
            try DuplicateFinder.findDuplicates(in: connection, mode: .byteLevel)
        }
        return Dictionary(uniqueKeysWithValues: groups.flatMap(\.files).compactMap { file in
            file.id.map { identifier in (identifier, file.seratoPlayCount) }
        })
    }

    func testTheMostPlayedCopyIsTheDefaultKeeperWhenQualityAndBucketTie() async throws {
        let (older, newer) = try await database.writer.write { connection in
            try (self.insertFile("/Music/Z/older.mp3", mtime: 100, in: connection),
                 self.insertFile("/Music/Z/newer.mp3", mtime: 200, in: connection))
        }
        try SyntheticSeratoHistory.write([
            play("/Music/Z/newer.mp3", at: 10), play("/Music/Z/newer.mp3", at: 20), play("/Music/Z/older.mp3", at: 30),
        ], session: "1", seratoDirectory: locator.seratoDirectory)

        await service.refresh()

        let groups = try await database.writer.read { connection in
            try DuplicateFinder.findDuplicates(in: connection, mode: .byteLevel)
        }
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(DuplicateKeeperPicker.chooseDefaultKeeper(for: group, musicFolder: URL(fileURLWithPath: "/Music")), newer,
                       "Plays outrank the older-mtime tiebreak")
        let counts = try await playCounts()
        XCTAssertEqual(counts[newer], 2)
        XCTAssertEqual(counts[older], 1)
    }

    func testPlaysFollowEachFileThroughItsPriorPathsAndAmbiguousPlaysStayUnattributed() async throws {
        let ids = try await database.writer.write { connection in
            let renamed = try self.insertFile("/Music/A/new.mp3", in: connection)
            let movedIn = try self.insertFile("/Music/A/old.mp3", in: connection)
            let resident = try self.insertFile("/Music/C/c.mp3", in: connection)
            let departed = try self.insertFile("/Music/D/d.mp3", in: connection)
            let composed = try self.insertFile("/Music/E/Café.mp3", in: connection)
            _ = try OperationEngine.insertEvent(batchId: "rename", timestamp: self.milliseconds(100), fileId: renamed, eventType: .fileRenamed,
                                                forwardPayload: RenameFilePayload(fileId: renamed, newPath: "/Music/A/new.mp3", previousPath: "/Music/A/old.mp3"),
                                                inversePayload: RenameFilePayload(fileId: renamed, newPath: "/Music/A/old.mp3", previousPath: "/Music/A/new.mp3"),
                                                in: connection)
            _ = try OperationEngine.insertEvent(batchId: "observe", timestamp: self.milliseconds(200), fileId: movedIn, eventType: .fileLocationObserved,
                                                forwardPayload: ObserveFileLocationPayload(fileId: movedIn, expectedRevision: 0, path: "/Music/A/old.mp3",
                                                                                           volumeUuid: "play-count-fixture", inode: 2),
                                                inversePayload: ObserveFileLocationPayload(fileId: movedIn, expectedRevision: 1, path: "/Music/Elsewhere/b.mp3",
                                                                                           volumeUuid: "play-count-fixture", inode: 2),
                                                in: connection)
            _ = try OperationEngine.insertEvent(batchId: "depart", timestamp: self.milliseconds(300), fileId: departed, eventType: .fileRenamed,
                                                forwardPayload: RenameFilePayload(fileId: departed, newPath: "/Music/D/d.mp3", previousPath: "/Music/C/c.mp3"),
                                                inversePayload: RenameFilePayload(fileId: departed, newPath: "/Music/C/c.mp3", previousPath: "/Music/D/d.mp3"),
                                                in: connection)
            return (renamed: renamed, movedIn: movedIn, resident: resident, departed: departed, composed: composed)
        }
        try SyntheticSeratoHistory.write([
            play("/Music/A/old.mp3", at: 50),
            play("/Music/Elsewhere/b.mp3", at: 60),
            play("/Music/A/new.mp3", at: 150),
            play("/Music/A/old.mp3", at: 150),
            play("/Music/A/old.mp3", at: 250),
            play("/Music/A/old.mp3", at: 260, played: false),
            play("_783160.beatsource", at: 270),
        ], session: "1", seratoDirectory: locator.seratoDirectory)
        try SyntheticSeratoHistory.write([
            play("/Music/C/c.mp3", at: 250),
            play("/Music/C/c.mp3", at: 350),
            play("/Music/E/Cafe\u{301}.mp3", at: 360),
            play("/Volumes/Gone/unknown.mp3", at: 370),
        ], session: "2", seratoDirectory: locator.seratoDirectory)

        await service.refresh()

        let counts = try await playCounts()
        XCTAssertEqual(counts[ids.renamed], 2, "Before and after its rename")
        XCTAssertEqual(counts[ids.movedIn], 2, "At its prior path, and at the reused path only after it moved in")
        XCTAssertEqual(counts[ids.resident], 1, "Only after the other claimant left the shared path")
        XCTAssertEqual(counts[ids.departed], 0, "While two files claimed the path, neither is credited")
        XCTAssertEqual(counts[ids.composed], 1, "History paths match by NFC form")
        XCTAssertEqual(service.status, .refreshed(SeratoPlayCountSummary(sessionCount: 2, playCount: 9, attributedCount: 6, unattributedCount: 3,
                                                                         unplayedCount: 1, nonFileCount: 1)))
    }

    func testARefreshKeepsThePreviousCountsWhileSeratoRunsOrWhenASessionIsCorrupt() async throws {
        let file = try await database.writer.write { connection in
            _ = try self.insertFile("/Music/F/other.mp3", in: connection)
            return try self.insertFile("/Music/F/track.mp3", in: connection)
        }
        try SyntheticSeratoHistory.write([play("/Music/F/track.mp3", at: 10)], session: "1", seratoDirectory: locator.seratoDirectory)
        await service.refresh()
        let first = try await playCounts()
        XCTAssertEqual(first[file], 1)

        try SyntheticSeratoHistory.write([play("/Music/F/track.mp3", at: 20)], session: "2", seratoDirectory: locator.seratoDirectory)
        serato.running = true
        watchdog.refresh()
        await service.refresh()
        XCTAssertEqual(service.status, .skippedWhileSeratoRunning)
        let whileRunning = try await playCounts()
        XCTAssertEqual(whileRunning[file], 1, "History is not read while Serato may be writing it")

        serato.running = false
        watchdog.refresh()
        try SyntheticSeratoHistory.writeCorrupt(session: "3", seratoDirectory: locator.seratoDirectory)
        await service.refresh()
        guard case let .failed(message) = service.status else {
            return XCTFail("A corrupt session must surface as a failure, got \(service.status)")
        }
        XCTAssertTrue(message.contains("3.session"), message)
        let afterFailure = try await playCounts()
        XCTAssertEqual(afterFailure[file], 1, "The previous table survives a failed parse")
    }

    private actor ReadCounter {
        private(set) var reads = 0

        func record() {
            reads += 1
        }
    }

    private final class TableWriteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var writes: Int {
            lock.withLock { count }
        }

        func record() {
            lock.withLock { count += 1 }
        }
    }

    private func observeTableWrites(in database: LibraryDatabase, counter: TableWriteCounter) -> AnyDatabaseCancellable {
        DatabaseRegionObservation(tracking: Table(SeratoPlayCounts.table))
            .start(in: database.writer, onError: { error in XCTFail("Play-count observation failed: \(error)") }) { _ in counter.record() }
    }

    func testHistoryIsReadAgainOnlyWhenItOrTheLibraryPathsChangedAndUnchangedCountsAreNotRewritten() async throws {
        let file = try await database.writer.write { connection in
            _ = try self.insertFile("/Music/H/other.mp3", in: connection)
            return try self.insertFile("/Music/H/track.mp3", in: connection)
        }
        try SyntheticSeratoHistory.write([play("/Music/H/track.mp3", at: 10)], session: "1", seratoDirectory: locator.seratoDirectory)
        let counter = ReadCounter()
        service = SeratoPlayCountService(database: database, seratoLocator: locator, watchdog: watchdog) { directory in
            await counter.record()
            return try readSeratoHistory(historyDirectory: directory)
        }
        let tableWrites = TableWriteCounter()
        let observation = observeTableWrites(in: database, counter: tableWrites)
        defer { observation.cancel() }

        await service.refresh()
        await service.refresh()
        var reads = await counter.reads
        XCTAssertEqual(reads, 1, "Nothing changed, so History is not parsed again")
        XCTAssertEqual(tableWrites.writes, 1)
        guard case .refreshed = service.status else { return XCTFail("Unchanged inputs keep the last outcome, got \(service.status)") }

        _ = try await database.writer.write { connection in try self.insertFile("/Music/H/unplayed.mp3", in: connection) }
        await service.refresh()
        reads = await counter.reads
        XCTAssertEqual(reads, 2, "A new library file can claim a played path")
        XCTAssertEqual(tableWrites.writes, 1, "Equal counts leave the table, and every observer of it, untouched")

        try SyntheticSeratoHistory.write([play("/Music/H/track.mp3", at: 20)], session: "2", seratoDirectory: locator.seratoDirectory)
        await service.refresh()
        reads = await counter.reads
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(tableWrites.writes, 2)
        let counts = try await playCounts()
        XCTAssertEqual(counts[file], 2)
    }

    func testAReadDuringWhichSeratoStartedIsDiscarded() async throws {
        let file = try await database.writer.write { connection in
            _ = try self.insertFile("/Music/J/other.mp3", in: connection)
            return try self.insertFile("/Music/J/track.mp3", in: connection)
        }
        try SyntheticSeratoHistory.write([play("/Music/J/track.mp3", at: 10)], session: "1", seratoDirectory: locator.seratoDirectory)
        await service.refresh()
        try SyntheticSeratoHistory.write([play("/Music/J/track.mp3", at: 20)], session: "2", seratoDirectory: locator.seratoDirectory)
        let serato = serato!
        let watchdog = watchdog!
        service = SeratoPlayCountService(database: database, seratoLocator: locator, watchdog: watchdog) { directory in
            let scan = try readSeratoHistory(historyDirectory: directory)
            await MainActor.run {
                serato.running = true
                watchdog.refresh()
            }
            return scan
        }

        await service.refresh()

        XCTAssertEqual(service.status, .skippedWhileSeratoRunning)
        let counts = try await playCounts()
        XCTAssertEqual(counts[file], 1, "History read while Serato may have been appending to it is not trusted")
    }

    func testPlaysBeforeAnObservedIdentityChangeCountAtThePreviousPath() async throws {
        let file = try await database.writer.write { connection in
            _ = try self.insertFile("/Music/K/other.mp3", in: connection)
            let moved = try self.insertFile("/Music/K/new.mp3", in: connection)
            let previous = FileMetadata(path: "/Music/K/old.mp3", volumeUuid: "play-count-fixture", inode: 2, fileSize: 4096, mtime: 1)
            let current = FileMetadata(path: "/Music/K/new.mp3", volumeUuid: "play-count-fixture", inode: 2, fileSize: 4096, mtime: 1)
            for (offset, before, after) in [(UInt32(100), previous, current), (UInt32(200), current, current)] {
                _ = try OperationEngine.insertEvent(batchId: "identity-\(offset)", timestamp: self.milliseconds(offset), fileId: moved,
                                                    eventType: .fileIdentityObserved,
                                                    forwardPayload: ObserveFileIdentityPayload(fileId: moved, expectedRevision: 0, previousIdentity: before, identity: after),
                                                    inversePayload: ObserveFileIdentityPayload(fileId: moved, expectedRevision: 1, previousIdentity: after, identity: before),
                                                    in: connection)
            }
            return moved
        }
        try SyntheticSeratoHistory.write([
            play("/Music/K/old.mp3", at: 50),
            play("/Music/K/old.mp3", at: 150),
            play("/Music/K/new.mp3", at: 250),
        ], session: "1", seratoDirectory: locator.seratoDirectory)

        await service.refresh()

        let counts = try await playCounts()
        XCTAssertEqual(counts[file], 2, "Before the move at its old path, and after it at the new one; a tag-only observation keeps the path")
    }
}
