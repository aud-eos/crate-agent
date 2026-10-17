@testable import CrateAgent
import Foundation
import GRDB
import XCTest

/// Undoing or redoing a MusicBrainz match rewrites the audio file's tags, so
/// it is guarded by what the file holds, not by the Serato-mirrored `files`
/// columns that an owned tag write deliberately leaves alone (#111).
@MainActor
final class MatchUndoFileTagGuardTests: XCTestCase {
    func testUndoRefusesOnlyWhenALaterTagWriteTouchedAFieldTheMatchWrote() async throws {
        for (edit, blockedFields) in [(SeratoMetadata(title: "Later title"), ["title"]), (SeratoMetadata(album: "Later album"), [])] {
            let fixture = try SeratoRemovalFixture()
            defer { fixture.cleanup() }
            let file = try await matched(fixture)
            try await fixture.engine.apply(.writeFileTags(.init(fileId: XCTUnwrap(file.id), metadata: edit)), batchId: "later-tags")

            do {
                _ = try await fixture.engine.undoBatch("match")
                XCTAssertEqual(blockedFields, [], "Undo overwrote the later \(blockedFields) edit")
            } catch let OperationEngineError.undoWouldOverwriteFileTags(_, fields) {
                XCTAssertEqual(fields, blockedFields)
            }

            let tags = try readAudioTags(filePath: file.path)
            if blockedFields.isEmpty {
                XCTAssertEqual(tags.title ?? "", "", "Undo restores the fields the match wrote")
                XCTAssertEqual(tags.album, "Later album")
            } else {
                XCTAssertEqual(tags.title, "Later title")
            }
        }
    }

    func testRedoRefusesToOverwriteAnExternalTagEditMadeAfterUndo() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await matched(fixture, year: 1999)
        let undo = try await fixture.engine.undoBatch("match")
        try writeAudioTags(filePath: file.path, update: yearUpdate(2005))

        do {
            _ = try await fixture.engine.undoBatch(undo)
            XCTFail("Redo overwrote the external year edit")
        } catch let OperationEngineError.undoWouldOverwriteFileTags(_, fields) {
            XCTAssertEqual(fields, ["year"])
        }
        XCTAssertEqual(try readAudioTags(filePath: file.path).year, 2005)
    }

    func testUndoRefusesWhenTheFileChangesAfterItsTagsWereChecked() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await matched(fixture)
        let eventsBefore = try await fixture.events()
        let guardQueries = GuardQueryCounter()
        try await fixture.database.writer.write { connection in
            connection.trace { event in
                let statement = event.expandedDescription
                guard statement.hasPrefix("SELECT"), statement.contains(EventType.musicBrainzMatchApplied.rawValue),
                      guardQueries.next() == 2 else { return }
                do { try writeAudioTags(filePath: file.path, update: self.yearUpdate(2005)) }
                catch { XCTFail("Concurrent tag edit failed: \(error)") }
            }
        }

        do {
            _ = try await fixture.engine.undoBatch("match")
            XCTFail("Undo committed against tags it never checked")
        } catch OperationEngineError.undoFileChangedWhileChecking {}
        try await fixture.database.writer.write { connection in connection.trace(nil) }

        let eventsAfter = try await fixture.events()
        XCTAssertEqual(eventsAfter, eventsBefore)
        XCTAssertEqual(try readAudioTags(filePath: file.path).title, "Matched title")
    }

    func testUndoOfAMissingFileNamesTheFile() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await matched(fixture)
        try FileManager.default.removeItem(atPath: file.path)

        do {
            _ = try await fixture.engine.undoBatch("match")
            XCTFail("Undo ran without the file it restores")
        } catch let OperationEngineError.undoFileUnavailable(fileID, path) {
            XCTAssertEqual(fileID, file.id)
            XCTAssertEqual(path, file.path)
        }
    }

    private func matched(_ fixture: SeratoRemovalFixture, year: Int? = nil) async throws -> FileRecord {
        let file = try await fixture.add("track.wav", bytes: FinalRemovalIntegrationTests.wav())
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        let fileID = try XCTUnwrap(file.id)
        let fingerprint = Data([11, 22, 33, 44])
        try await fixture.database.writer.write { database in
            var track = TrackRecord(fingerprintHash: fingerprint, artist: "Before match")
            try track.insert(database)
            var current = try XCTUnwrap(FileRecord.fetchOne(database, key: fileID))
            current.trackId = track.id
            current.chromaprintFingerprint = Data([5, 6, 7, 8])
            current.fingerprintStatus = .done
            current.fingerprintedSize = current.fileSize
            current.fingerprintedMtime = current.mtime
            try current.update(database)
        }
        try await fixture.engine.apply(.applyMusicBrainzMatch(.init(fileID: fileID, acoustID: "acoustid", recordingMBID: "recording", releaseMBID: nil,
                                                                    artistMBID: nil, isrc: nil, fingerprintHash: fingerprint,
                                                                    expectedFileSize: file.fileSize, expectedMtime: file.mtime,
                                                                    artist: "Matched artist", title: "Matched title", album: nil, year: year)),
                                       batchId: "match")
        XCTAssertEqual(try readAudioTags(filePath: file.path).title, "Matched title")
        return file
    }

    private nonisolated func yearUpdate(_ year: UInt32) -> AudioTagUpdate {
        AudioTagUpdate(artist: nil, title: nil, album: nil, genre: nil, bpm: nil, musicalKey: nil, comment: nil, label: nil, year: year, clearYear: false)
    }
}

private final class GuardQueryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
