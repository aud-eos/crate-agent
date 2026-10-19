@testable import CrateAgent
import Foundation
import GRDB
import XCTest

@MainActor
final class SeratoLibraryFactsTests: XCTestCase {
    private var fixture: SeratoRemovalFixture!

    override func setUp() async throws {
        fixture = try SeratoRemovalFixture(fileBacked: true)
    }

    override func tearDown() async throws {
        fixture.cleanup()
    }

    func testFactsRefreshMapsV2FactsAndSubcratesButNotSmartCrates() async throws {
        let first = try await index("a.wav", eventsAt: [1_600_000_000_123])
        let second = try await index("b.wav", eventsAt: [1_600_000_100_000])
        let third = try await index("c.wav", eventsAt: [1_600_000_300_000, 1_600_000_200_999])
        try saveLibrary([
            SeratoTestEncoding.track(path: relative(first), fields: [("bbgl", Data([1])), ("uadd", bigEndian(1_700_000_000))]),
            SeratoTestEncoding.track(path: relative(second)),
        ])
        try saveCrate("Warmup.crate", paths: [relative(first)])
        try SeratoTestEncoding.crate(paths: [relative(second), relative(third)])
            .write(to: fixture.locator.smartCratesDirectoryUrl.appendingPathComponent("Recent.scrate"))
        let service = makeService()

        await service.refresh()

        let facts = try await storedFacts()
        XCTAssertEqual(facts[first.id!], SeratoFileFacts(beatgridLocked: true, addedAt: 1_700_000_000, addedSource: .serato))
        XCTAssertEqual(facts[second.id!], SeratoFileFacts(beatgridLocked: nil, addedAt: 1_600_000_100, addedSource: .indexed),
                       "A V2 record without a date falls back to when the file was first indexed")
        XCTAssertEqual(facts[third.id!], SeratoFileFacts(beatgridLocked: nil, addedAt: 1_600_000_200, addedSource: .indexed),
                       "A file absent from V2 still gets its earliest event time")
        let memberships = try await storedMemberships()
        XCTAssertEqual(memberships, [first.id!: ["Warmup.crate"]], "SmartCrates are not crate membership")
        XCTAssertEqual(service.status, .refreshed(SeratoLibraryFactsSummary(trackFactCount: 2, crateCount: 1, membershipCount: 1, unmatchedPathCount: 0)))
    }

    func testUnchangedSourcesAreNotReadAgainByAFreshService() async throws {
        let file = try await index("a.wav", eventsAt: [1_600_000_000_000])
        try saveLibrary([SeratoTestEncoding.track(path: relative(file), fields: [("bbgl", Data([0]))])])
        try saveCrate("Warmup.crate", paths: [relative(file), "Volumes/Gone/missing.wav"])
        let service = makeService()
        await service.refresh()
        let summary = SeratoLibraryFactsSummary(trackFactCount: 1, crateCount: 1, membershipCount: 1, unmatchedPathCount: 1)
        XCTAssertEqual(service.status, .refreshed(summary))

        let counter = ReadCounter()
        let reopened = makeService(counter: counter)
        await reopened.refresh()
        XCTAssertEqual(counter.counts, ReadCounter.Counts(facts: 0, crates: 0))
        XCTAssertEqual(reopened.status, .refreshed(summary), "A restart reports what the unchanged sources last yielded")

        try saveCrate("Peak.crate", paths: [relative(file)])
        await makeService(counter: counter).refresh()
        XCTAssertEqual(counter.counts, ReadCounter.Counts(facts: 0, crates: 2), "Only the changed source is read")
        let memberships = try await storedMemberships()
        XCTAssertEqual(memberships, [file.id!: ["Peak.crate", "Warmup.crate"]])
    }

    func testFailedReadKeepsPreviousFactsAndReportsTheReason() async throws {
        let file = try await index("a.wav", eventsAt: [1_600_000_000_000])
        try saveLibrary([SeratoTestEncoding.track(path: relative(file), fields: [("bbgl", Data([1]))])])
        try saveCrate("Warmup.crate", paths: [relative(file)])
        await makeService().refresh()
        let previousMemberships = try await storedMemberships()
        let previousFacts = try await storedFacts()

        try saveCrate("Warmup.crate", paths: [])
        let failing = makeService(readCrate: { _ in throw ReaderFailure() })
        await failing.refresh()

        XCTAssertEqual(failing.status, .failed(ReaderFailure.message))
        let memberships = try await storedMemberships()
        let facts = try await storedFacts()
        XCTAssertEqual(memberships, previousMemberships)
        XCTAssertEqual(facts, previousFacts)
        let counter = ReadCounter()
        await makeService(counter: counter).refresh()
        XCTAssertEqual(counter.counts.crates, 1, "The failed source is read again on the next refresh")
    }

    func testMalformedV2RecordsAreReportedAndLeaveFilesWithoutARecordUnknown() async throws {
        let read = try await index("a.wav", eventsAt: [1_600_000_000_000])
        let unread = try await index("b.wav", eventsAt: [1_600_000_000_000])
        let readPath = relative(read)
        let service = makeService(readFacts: { _ in
            SeratoTrackFactsScan(tracks: [SeratoTrackFacts(path: readPath, beatgridLocked: true, addedAt: 1_700_000_000)], malformedRecordCount: 1)
        })

        await service.refresh()

        XCTAssertEqual(service.status, .failed(SeratoLibraryFactsMessages.unreadableRecords(1)))
        let facts = try await storedFacts()
        XCTAssertEqual(facts[read.id!], SeratoFileFacts(beatgridLocked: true, addedAt: 1_700_000_000, addedSource: .serato))
        XCTAssertNil(facts[unread.id!], "Its record may be the unreadable one, so its facts stay unknown")
    }

    func testCrateMembershipMatchesUnicodeFormsAndFollowsRenames() async throws {
        let file = try await index("Caf\u{E9}.wav", eventsAt: [1_600_000_000_000],
                                   bytes: FinalRemovalIntegrationTests.wav())
        // Foundation stores the file's path decomposed; the crate spells it composed.
        let composed = relative(file).precomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.utf8), Array(relative(file).utf8))
        try saveLibrary([SeratoTestEncoding.track(path: relative(file))])
        try saveCrate("Warmup.crate", paths: [composed])
        let service = makeService()
        await service.refresh()
        let before = try await storedMemberships()
        XCTAssertEqual(before, [file.id!: ["Warmup.crate"]])

        let renamed = fixture.directory.appendingPathComponent("renamed.wav").path
        try await fixture.engine.apply(.renameFile(.init(fileId: file.id!, newPath: renamed, previousPath: file.path, physicalMove: true)))
        XCTAssertEqual(try readCratePaths(cratePath: fixture.locator.subcratesDirectoryUrl.appendingPathComponent("Warmup.crate").path).map(SeratoPath.normalized),
                       [renamed])
        await service.refresh()

        let after = try await storedMemberships()
        XCTAssertEqual(after, [file.id!: ["Warmup.crate"]])
        XCTAssertEqual(service.status, .refreshed(SeratoLibraryFactsSummary(trackFactCount: 1, crateCount: 1, membershipCount: 1, unmatchedPathCount: 0)))
    }

    // MARK: - Helpers

    private struct ReaderFailure: LocalizedError {
        static let message = "crate unreadable"
        var errorDescription: String? {
            Self.message
        }
    }

    private final class ReadCounter: @unchecked Sendable {
        struct Counts: Equatable {
            var facts = 0
            var crates = 0
        }

        private let lock = NSLock()
        private var stored = Counts()

        var counts: Counts {
            lock.withLock { stored }
        }

        func record(_ change: (inout Counts) -> Void) {
            lock.withLock { change(&stored) }
        }
    }

    private func makeService(counter: ReadCounter? = nil,
                             readFacts: (@Sendable (String) async throws -> SeratoTrackFactsScan)? = nil,
                             readCrate: (@Sendable (String) async throws -> [String])? = nil) -> SeratoLibraryFactsService
    {
        SeratoLibraryFactsService(database: fixture.database, seratoLocator: fixture.locator, watchdog: fixture.watchdog,
                                  readFacts: { path in
                                      counter?.record { counts in counts.facts += 1 }
                                      return try await readFacts?(path) ?? readDatabaseTrackFacts(databasePath: path)
                                  },
                                  readCrate: { path in
                                      counter?.record { counts in counts.crates += 1 }
                                      return try await readCrate?(path) ?? readCratePaths(cratePath: path)
                                  })
    }

    private func index(_ name: String, eventsAt timestamps: [Int64], bytes: Data = Data([1, 2, 3, 4])) async throws -> FileRecord {
        let file = try await fixture.add(name, bytes: bytes)
        let fileID = try XCTUnwrap(file.id)
        try await fixture.database.writer.write { connection in
            for timestamp in timestamps {
                _ = try OperationEngine.insertEvent(batchId: "index-\(timestamp)", timestamp: timestamp, fileId: fileID, eventType: .fileLibraryStateChanged,
                                                    forwardPayload: ["fixture": "indexed"], inversePayload: ["fixture": "indexed"], in: connection)
            }
        }
        return file
    }

    private func relative(_ file: FileRecord) -> String {
        SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)
    }

    private func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { bytes in Data(bytes) }
    }

    private func saveLibrary(_ tracks: [Data]) throws {
        try SeratoTestEncoding.library(tracks: tracks).write(to: fixture.locator.databaseV2Url)
    }

    private func saveCrate(_ name: String, paths: [String]) throws {
        try SeratoTestEncoding.crate(paths: paths).write(to: fixture.locator.subcratesDirectoryUrl.appendingPathComponent(name))
    }

    private func storedFacts() async throws -> [Int64: SeratoFileFacts] {
        try await fixture.database.writer.read { connection in try SeratoLibraryFacts.facts(in: connection) }
    }

    private func storedMemberships() async throws -> [Int64: Set<String>] {
        try await fixture.database.writer.read { connection in try SeratoLibraryFacts.memberships(in: connection) }
    }
}
