@testable import CrateAgent
import Foundation
import GRDB
import XCTest

/// Perceptual duplicates share a 120 s fingerprint; cleanup must follow the
/// decoded audio of real files, not the fingerprint.
@MainActor
final class DuplicateAudioCheckTests: XCTestCase {
    private static let sharedFingerprint = Data(repeating: 0x5A, count: 64)

    func testOnlyIdenticalDecodedAudioIsOfferedForCleanup() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let clean = try await addFingerprinted(fixture, "song-clean.wav", wav(frequency: 440, title: "Song (Clean)"))
        let copy = try await addFingerprinted(fixture, "song-copy.wav", wav(frequency: 440, title: "Song (Clean) copy"))
        let dirty = try await addFingerprinted(fixture, "song-dirty.wav", wav(frequency: 660, title: "Song (Dirty)"))

        let unchecked = try await perceptualGroups(fixture)
        XCTAssertEqual(unchecked.map(\.audioCheck), [.checking])
        XCTAssertFalse(unchecked.contains(where: \.offersCleanup), "Nothing is offered while a digest is pending")

        try await DuplicateAudioVerifier(database: fixture.database).verifyPendingFiles()
        let checked = try await perceptualGroups(fixture)

        XCTAssertEqual(checked.map(\.audioCheck), [.confirmed])
        XCTAssertEqual(checked.first.map { group in Set(group.files.map(\.id)) }, [clean.id, copy.id])
        XCTAssertEqual(checked.first?.preselectsCleanup, true)
        XCTAssertEqual(checked.first?.keptFiles.map(\.file.id), [dirty.id])
        XCTAssertEqual(checked.first?.keptFiles.map(\.reason), [.audioDiffers])
    }

    func testCrossFormatMatchIsNeverPreselectedAndNeedsAnExplicitChoiceAtTheBoundary() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let sixteenBit = try await addFingerprinted(fixture, "master-16.wav", wav(frequency: 440, bitsPerSample: 16))
        let twentyFourBit = try await addFingerprinted(fixture, "master-24.wav", wav(frequency: 440, bitsPerSample: 24))
        try fixture.save(paths: [sixteenBit.path, twentyFourBit.path].map(SeratoLibraryLocator.seratoRelativePath))
        try await DuplicateAudioVerifier(database: fixture.database).verifyPendingFiles()

        let groups = try await perceptualGroups(fixture)
        XCTAssertEqual(groups.map(\.audioCheck), [.crossFormat])
        XCTAssertEqual(groups.first?.preselectsCleanup, false)

        let trash = fixture.directory.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let engine = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator, fileTrasher: { path in
            try FileManager.default.moveItem(atPath: path, toPath: trash.appendingPathComponent((path as NSString).lastPathComponent).path)
        })
        let unselected = try await engine.resolveDuplicate(target: fixture.row(twentyFourBit), keeper: fixture.row(sixteenBit),
                                                           batchID: "cross-format-unselected", audioRequirement: .identical)
        guard case .failed = unselected else { return XCTFail("Expected the boundary to refuse, got \(unselected)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: twentyFourBit.path))
    }

    private func addFingerprinted(_ fixture: SeratoRemovalFixture, _ name: String, _ bytes: Data) async throws -> FileRecord {
        let file = try await fixture.add(name, bytes: bytes)
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET chromaprint_fingerprint = ?, fingerprint_status = 'done' WHERE id = ?",
                                   arguments: [Self.sharedFingerprint, file.id])
        }
        return try await fixture.row(file)
    }

    private func perceptualGroups(_ fixture: SeratoRemovalFixture) async throws -> [DuplicateFinder.DuplicateGroup<DuplicateFileRow>] {
        try await fixture.database.writer.read { connection in try DuplicateFinder.findDuplicates(in: connection, mode: .perceptual) }
    }

    /// Ten seconds of a mono sine. 24-bit files carry one extra low bit, so
    /// their PCM differs from the 16-bit master while sounding the same.
    /// `title` adds a RIFF INFO tag chunk.
    private func wav(frequency: Double, bitsPerSample: Int = 16, title: String? = nil) -> Data {
        let sampleRate = 44100
        let bytesPerSample = bitsPerSample / 8
        var samples = Data()
        for index in 0 ..< sampleRate * 10 {
            let value = Int32(sin(2 * Double.pi * frequency * Double(index) / Double(sampleRate)) * 20000)
            let encoded = bitsPerSample == 24 ? (value << 8) | 1 : value
            samples += little(encoded).prefix(bytesPerSample)
        }
        var info = Data()
        if let title {
            var value = Data(title.utf8) + Data([0])
            if value.count.isMultiple(of: 2) == false {
                value += Data([0])
            }
            info = Data("LIST".utf8) + little(UInt32(12 + value.count)) + Data("INFOINAM".utf8) + little(UInt32(value.count)) + value
        }
        var bytes = Data("RIFF".utf8) + little(UInt32(36 + info.count + samples.count)) + Data("WAVEfmt ".utf8)
        bytes += little(UInt32(16)) + little(UInt16(1)) + little(UInt16(1)) + little(UInt32(sampleRate))
        bytes += little(UInt32(sampleRate * bytesPerSample)) + little(UInt16(bytesPerSample)) + little(UInt16(bitsPerSample))
        return bytes + info + Data("data".utf8) + little(UInt32(samples.count)) + samples
    }

    private func little(_ value: some FixedWidthInteger) -> Data {
        var encoded = value.littleEndian
        return withUnsafeBytes(of: &encoded) { buffer in Data(buffer) }
    }
}
