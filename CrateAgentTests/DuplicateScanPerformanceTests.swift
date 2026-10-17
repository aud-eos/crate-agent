@testable import CrateAgent
import GRDB
import XCTest

/// 30,000 processable files on a temporary WAL database: every file has
/// a 32-byte lightweight hash, 24,000 have a 4 KB Chromaprint
/// fingerprint, 300 byte-level pairs and 1,650 perceptual pairs (the
/// owner's 3,300 colliding files), each with a cached audio digest.
final class DuplicateScanPerformanceTests: XCTestCase {
    private static let fileCount = 30000
    private static let fingerprintedCount = 24000
    private static let bytePairs = 300
    private static let perceptualPairs = 1650

    private func makeFixture() throws -> (directory: URL, database: LibraryDatabase) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicateScan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try LibraryDatabase.openWAL(at: directory.appendingPathComponent("library.sqlite"))
        try database.writer.write { connection in
            for identifier in 1 ... Self.fileCount {
                let hashSeed = identifier <= Self.bytePairs * 2 ? (identifier + 1) / 2 : identifier
                let fingerprintSeed = identifier <= Self.perceptualPairs * 2 ? (identifier + 1) / 2 : identifier
                let fingerprinted = identifier <= Self.fingerprintedCount
                var file = FileRecord(path: String(format: "/Synthetic/%05d.mp3", identifier), volumeUuid: "duplicate-scan", inode: Int64(identifier),
                                      fileSize: 5_000_000, mtime: 0, lightweightHash: Self.bytes(seed: hashSeed, count: 32),
                                      chromaprintFingerprint: fingerprinted ? Self.bytes(seed: fingerprintSeed, count: 4096) : nil,
                                      fingerprintStatus: fingerprinted ? .done : .pending, bitrateKbps: 320,
                                      artist: "Artist \(identifier % 500)", title: "Track \(identifier)", album: "Collection",
                                      genre: "House", bpm: "124.00", musicalKey: "8A", comment: String(repeating: "c", count: 80))
                file.libraryMembership = .active
                file.fileAvailability = .available
                try file.insert(connection)
                let basis = DigestBasis(fileSize: 5_000_000, mtime: 0, inode: Int64(identifier), modifiedNanoseconds: 0, changedSeconds: 0, changedNanoseconds: 0)
                if identifier <= Self.bytePairs * 2 {
                    try DuplicateDigestStore.save([DigestResult(fileID: Int64(identifier), basis: basis,
                                                                evidence: .content(Self.bytes(seed: hashSeed, count: 32)))],
                                                  kind: .content, in: connection)
                }
                if identifier <= Self.perceptualPairs * 2 {
                    try DuplicateDigestStore.save([DigestResult(
                        fileID: Int64(identifier), basis: basis,
                        evidence: .decoded(.init(format: "mp3/mp3", pcmDigest: Self.bytes(seed: fingerprintSeed, count: 32),
                                                 fullFingerprintDigest: Self.bytes(seed: fingerprintSeed, count: 32), durationSeconds: 240))
                    )], kind: .audio, in: connection)
                }
            }
        }
        return (directory, database)
    }

    private static func bytes(seed: Int, count: Int) -> Data {
        var generator = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15
        return Data((0 ..< count).map { _ in
            generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: generator >> 56)
        })
    }

    func testRescanDecodesOnlyGroupMembersWithinBudget() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let start = ContinuousClock.now
        let scan = try await fixture.database.writer.read { connection in
            try (byteLevel: DuplicateFinder.findDuplicates(in: connection, mode: .byteLevel),
                 perceptual: DuplicateFinder.findDuplicates(in: connection, mode: .perceptual),
                 coverage: DuplicateFinder.fingerprintCoverage(in: connection))
        }
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(scan.byteLevel.count, Self.bytePairs)
        XCTAssertEqual(scan.perceptual.count, Self.perceptualPairs)
        XCTAssertTrue((scan.byteLevel + scan.perceptual).allSatisfy { group in group.check == .confirmed })
        XCTAssertEqual(scan.byteLevel.reduce(0) { total, group in total + group.size }, Self.bytePairs * 2,
                       "Only group members may be decoded")
        XCTAssertEqual(scan.perceptual.reduce(0) { total, group in total + group.size }, Self.perceptualPairs * 2)
        XCTAssertEqual(scan.coverage.done, Self.fingerprintedCount)
        XCTAssertEqual(scan.coverage.total, Self.fileCount)
        XCTAssertLessThan(elapsed, .milliseconds(1000))

        let metrics = "DUPLICATE_SCAN files=\(Self.fileCount) fingerprinted=\(Self.fingerprintedCount) byte_groups=\(scan.byteLevel.count) perceptual_groups=\(scan.perceptual.count) both_modes_and_coverage=\(elapsed)"
        print(metrics)
        let attachment = XCTAttachment(string: metrics)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
