@testable import CrateAgent
import Foundation
import GRDB
import XCTest

/// Duplicate candidates share a partial hash or a 120 s fingerprint; cleanup
/// must follow the full contents or decoded audio of real files.
@MainActor
final class DuplicateCheckTests: XCTestCase {
    private static let sharedFingerprint = Data(repeating: 0x5A, count: 64)

    func testOnlyIdenticalDecodedAudioIsOfferedForCleanup() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let clean = try await addFingerprinted(fixture, "song-clean.wav", wav(frequency: 440, title: "Song (Clean)"))
        let copy = try await addFingerprinted(fixture, "song-copy.wav", wav(frequency: 440, title: "Song (Clean) copy"))
        let dirty = try await addFingerprinted(fixture, "song-dirty.wav", wav(frequency: 660, title: "Song (Dirty)"))

        let unchecked = try await groups(fixture)
        XCTAssertEqual(unchecked.map(\.check), [.checking])
        XCTAssertFalse(unchecked.contains(where: \.offersCleanup), "Nothing is offered while a digest is pending")

        try await DuplicateEvidenceVerifier(database: fixture.database).verifyPendingFiles(mode: .perceptual)
        let checked = try await groups(fixture)

        XCTAssertEqual(checked.map(\.check), [.confirmed])
        XCTAssertEqual(checked.first.map { group in Set(group.files.map(\.id)) }, [clean.id, copy.id])
        XCTAssertEqual(checked.first?.preselectsCleanup, true)
        XCTAssertEqual(checked.first?.keptFiles.map(\.file.id), [dirty.id])
        XCTAssertEqual(checked.first?.keptFiles.map(\.reason), [.differs])
    }

    func testByteLevelMatchIsOfferedOnlyOnceTheFullContentsAgree() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let original = Data(repeating: 0x11, count: 3_000_000)
        var editedMiddle = original
        editedMiddle[1_500_000] = 0x22
        let first = try await fixture.add("first.mp3", bytes: original)
        let copy = try await fixture.add("copy.mp3", bytes: original)
        let edited = try await fixture.add("edited.mp3", bytes: editedMiddle)

        let unchecked = try await groups(fixture, mode: .byteLevel)
        XCTAssertEqual(unchecked.map(\.check), [.checking], "Size and first and last megabyte agree for all three")
        XCTAssertFalse(unchecked.contains(where: \.offersCleanup))

        try await DuplicateEvidenceVerifier(database: fixture.database).verifyPendingFiles(mode: .byteLevel)
        let checked = try await groups(fixture, mode: .byteLevel)

        XCTAssertEqual(checked.map(\.check), [.confirmed])
        XCTAssertEqual(checked.first.map { group in Set(group.files.map(\.id)) }, [first.id, copy.id])
        XCTAssertEqual(checked.first?.keptFiles.map(\.file.id), [edited.id])
    }

    func testFingerprintMatchIsNeverPreselectedAndOnlyTheChosenFileIsRemoved() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let sixteenBit = try await addFingerprinted(fixture, "master-16.wav", wav(frequency: 440, bitsPerSample: 16))
        let twentyFourBit = try await addFingerprinted(fixture, "master-24.wav", wav(frequency: 440, bitsPerSample: 24))
        let reencoded = try await addFingerprinted(fixture, "reencode-24.wav", wav(frequency: 440, bitsPerSample: 24, lowBits: 2))
        try fixture.save(paths: [sixteenBit.path, twentyFourBit.path, reencoded.path].map(SeratoLibraryLocator.seratoRelativePath))
        try await DuplicateEvidenceVerifier(database: fixture.database).verifyPendingFiles(mode: .perceptual)

        let groups = try await groups(fixture)
        XCTAssertEqual(groups.map(\.check), [.needsListening], "Another format and another encoding of one format both need listening")
        XCTAssertEqual(groups.first?.preselectsCleanup, false)
        let group = try XCTUnwrap(groups.first)
        let sameFormatKeeper = try XCTUnwrap(group.files.first { file in file.id == twentyFourBit.id })
        let sameFormatTarget = try XCTUnwrap(group.files.first { file in file.id == reencoded.id })
        XCTAssertEqual(group.relation(of: sameFormatTarget, toKeeper: sameFormatKeeper), .fingerprintMatch,
                       "A same-format file whose PCM differs can still be chosen by hand")

        let trash = fixture.directory.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let engine = OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator, fileTrasher: { path in
            try FileManager.default.moveItem(atPath: path, toPath: trash.appendingPathComponent((path as NSString).lastPathComponent).path)
        })
        _ = try await DuplicateResolver(operationEngine: engine, database: fixture.database)
            .resolve(group: group, keeperId: XCTUnwrap(twentyFourBit.id), explicitlySelectedFileIDs: [XCTUnwrap(reencoded.id)])

        XCTAssertFalse(FileManager.default.fileExists(atPath: reencoded.path), "The file the listener chose is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sixteenBit.path), "A fingerprint match nobody chose stays on disk")
    }

    private func addFingerprinted(_ fixture: SeratoRemovalFixture, _ name: String, _ bytes: Data) async throws -> FileRecord {
        let file = try await fixture.add(name, bytes: bytes)
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET chromaprint_fingerprint = ?, fingerprint_status = 'done' WHERE id = ?",
                                   arguments: [Self.sharedFingerprint, file.id])
        }
        return try await fixture.row(file)
    }

    private func groups(_ fixture: SeratoRemovalFixture, mode: DuplicateFinder.Mode = .perceptual) async throws -> [DuplicateFinder.DuplicateGroup<DuplicateFileRow>] {
        try await fixture.database.writer.read { connection in try DuplicateFinder.findDuplicates(in: connection, mode: mode) }
    }

    /// Ten seconds of a mono sine. 24-bit files carry `lowBits` below the
    /// 16-bit range, so their PCM differs from the 16-bit master, and from
    /// each other, while sounding the same.
    /// `title` adds a RIFF INFO tag chunk.
    private func wav(frequency: Double, bitsPerSample: Int = 16, lowBits: Int32 = 1, title: String? = nil) -> Data {
        let sampleRate = 44100
        let bytesPerSample = bitsPerSample / 8
        var samples = Data()
        for index in 0 ..< sampleRate * 10 {
            let value = Int32(sin(2 * Double.pi * frequency * Double(index) / Double(sampleRate)) * 20000)
            let encoded = bitsPerSample == 24 ? (value << 8) | lowBits : value
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
