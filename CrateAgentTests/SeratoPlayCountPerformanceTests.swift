@testable import CrateAgent
import GRDB
import XCTest

/// Production-scale History: 30,000 library files, 5,000 of them renamed
/// once, and 266 sessions holding 43,000 entries, of which 30,500 were
/// played (a quarter of those at a renamed file's earlier path).
final class SeratoPlayCountPerformanceTests: XCTestCase {
    private static let fileCount = 30000
    private static let renamedCount = 5000
    private static let sessionCount = 266
    private static let entryCount = 43000
    private static let playedCount = 30500
    private static let renamedAt: UInt32 = 1_700_500_000

    @MainActor
    func testRefreshParsesAndAttributesALargeHistoryWithinBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlayCountPerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase.openWAL(at: directory.appendingPathComponent("library.sqlite"))
        try await database.writer.write { connection in
            for identifier in 1 ... Self.fileCount {
                var file = FileRecord(path: Self.path(identifier), volumeUuid: "play-count-scale", inode: Int64(identifier), fileSize: 5_000_000, mtime: 0)
                file.libraryMembership = .active
                file.fileAvailability = .available
                try file.insert(connection)
                if identifier <= Self.renamedCount {
                    let previous = Self.path(identifier, renamed: true)
                    _ = try OperationEngine.insertEvent(batchId: "scale-\(identifier)", timestamp: Int64(Self.renamedAt) * 1000, fileId: Int64(identifier),
                                                        eventType: .fileRenamed,
                                                        forwardPayload: RenameFilePayload(fileId: Int64(identifier), newPath: Self.path(identifier), previousPath: previous),
                                                        inversePayload: RenameFilePayload(fileId: Int64(identifier), newPath: previous, previousPath: Self.path(identifier)),
                                                        in: connection)
                }
            }
        }
        let locator = SeratoLibraryLocator(seratoDirectory: directory)
        let entriesPerSession = Self.entryCount / Self.sessionCount + 1
        for session in 0 ..< Self.sessionCount {
            let entries = (0 ..< entriesPerSession).compactMap { offset -> SyntheticSeratoHistory.Entry? in
                let index = session * entriesPerSession + offset
                guard index < Self.entryCount else { return nil }
                let identifier = index % (Self.fileCount / 2) + 1
                let beforeRename = identifier <= Self.renamedCount && index % 2 == 0
                return SyntheticSeratoHistory.Entry(path: Self.path(identifier, renamed: beforeRename),
                                                    startedAt: beforeRename ? Self.renamedAt - 100 : Self.renamedAt + UInt32(index),
                                                    played: index < Self.playedCount)
            }
            try SyntheticSeratoHistory.write(entries, session: "\(session)", seratoDirectory: directory)
        }
        let service = SeratoPlayCountService(database: database, seratoLocator: locator, watchdog: SeratoWatchdog { [] })

        let start = ContinuousClock.now
        await service.refresh()
        let elapsed = start.duration(to: .now)

        guard case let .refreshed(summary) = service.status else {
            return XCTFail("Refresh did not finish: \(service.status)")
        }
        XCTAssertEqual(summary.sessionCount, Self.sessionCount)
        XCTAssertEqual(summary.playCount, Self.playedCount)
        XCTAssertEqual(summary.attributedCount, Self.playedCount, "Every play maps to the file at its path at the time")
        XCTAssertEqual(summary.unplayedCount, Self.entryCount - Self.playedCount)
        XCTAssertLessThan(elapsed, .milliseconds(1500))

        let metrics = "SERATO_PLAY_COUNTS files=\(Self.fileCount) renamed=\(Self.renamedCount) sessions=\(Self.sessionCount) entries=\(Self.entryCount) played=\(Self.playedCount) refresh=\(elapsed)"
        print(metrics)
        let attachment = XCTAttachment(string: metrics)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func path(_ identifier: Int, renamed: Bool = false) -> String {
        String(format: renamed ? "/Music/Old/%05d.mp3" : "/Music/A/%05d.mp3", identifier)
    }
}
