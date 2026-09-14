@testable import CrateAgent
import GRDB
import XCTest

final class AutoTagFileBrowseTests: XCTestCase {
    private func seedFile(
        _ database: LibraryDatabase,
        number: Int,
        artist: String? = "Artist",
        title: String? = "Title",
        album: String? = "Album",
        recordingID: String? = "recording",
        linked: Bool = true
    ) throws -> Int64 {
        try database.writer.write { db in
            var track = TrackRecord(
                fingerprintHash: Data("fingerprint-\(number)".utf8),
                musicbrainzRecordingId: recordingID
            )
            if linked {
                try track.insert(db)
            }
            var file = FileRecord(
                path: "/fixture/\(number).mp3", volumeUuid: "fixture", inode: Int64(number),
                fileSize: 100, mtime: 0, trackId: linked ? track.id : nil,
                artist: artist, title: title, album: album
            )
            try file.insert(db)
            return try XCTUnwrap(file.id)
        }
    }

    private func browse(_ database: LibraryDatabase, filter: AutoTagBrowseFilter = .either, page: Int = 0) throws -> AutoTagFileBrowse.Results {
        try database.writer.read { db in
            try AutoTagFileBrowse.browse(filter: filter, page: page, in: db)
        }
    }

    func testDefaultIsUnionOfMissingMetadataAndUnmatched() throws {
        let database = try LibraryDatabase.openInMemory()
        let missing = try seedFile(database, number: 1, album: nil)
        let unmatched = try seedFile(database, number: 2, recordingID: nil)
        let both = try seedFile(database, number: 3, artist: nil, linked: false)
        _ = try seedFile(database, number: 4)
        let results = try browse(database)
        XCTAssertEqual(Set(results.matches.map(\.id)), [missing, unmatched, both])
        XCTAssertEqual(results.totalMatchCount, 3)
        XCTAssertEqual(try Set(browse(database, filter: .missingMetadata).matches.map(\.id)), [missing, both])
        XCTAssertEqual(try Set(browse(database, filter: .unmatched).matches.map(\.id)), [unmatched, both])
    }

    func testMissingMetadataIncludesEmptyAndUnicodeWhitespaceInEveryRequiredField() throws {
        let database = try LibraryDatabase.openInMemory()
        let empty = try seedFile(database, number: 1, artist: "")
        let tabs = try seedFile(database, number: 2, title: "\t\r\n")
        let unicode = try seedFile(database, number: 3, album: "\u{a0}\u{2003}\u{2028}")
        _ = try seedFile(database, number: 4, title: "\tReal title\n")
        let results = try browse(database, filter: .missingMetadata)
        XCTAssertEqual(Set(results.matches.map(\.id)), [empty, tabs, unicode])
        XCTAssertEqual(results.totalMatchCount, 3)
    }

    func testUnmatchedUsesCurrentLinkAndDoesNotTreatFingerprintAsMatch() throws {
        let database = try LibraryDatabase.openInMemory()
        let noLink = try seedFile(database, number: 1, linked: false)
        let noRecording = try seedFile(database, number: 2, recordingID: nil)
        let blankRecording = try seedFile(database, number: 3, recordingID: " \t")
        let matched = try seedFile(database, number: 4)
        XCTAssertEqual(try Set(browse(database, filter: .unmatched).matches.map(\.id)), [noLink, noRecording, blankRecording])
        try database.writer.write { db in
            try db.execute(sql: "UPDATE files SET track_id = NULL WHERE id = ?", arguments: [matched])
        }
        XCTAssertEqual(try browse(database, filter: .unmatched).totalMatchCount, 4)
    }

    func testPagesAreBoundedAndStableForIdenticalLabels() throws {
        let database = try LibraryDatabase.openInMemory()
        var expectedIDs: [Int64] = []
        for number in 1 ... 405 {
            try expectedIDs.append(seedFile(database, number: number, recordingID: nil))
        }
        let first = try browse(database, page: 0)
        let second = try browse(database, page: 1)
        let third = try browse(database, page: 2)
        XCTAssertEqual(first.matches.count, 200)
        XCTAssertEqual(second.matches.count, 200)
        XCTAssertEqual(third.matches.count, 5)
        XCTAssertEqual(first.totalMatchCount, 405)
        XCTAssertEqual(second.totalMatchCount, 405)
        XCTAssertEqual(third.totalMatchCount, 405)
        XCTAssertEqual((first.matches + second.matches + third.matches).map(\.id), expectedIDs)
        XCTAssertTrue(first.hasNextPage)
        XCTAssertFalse(third.hasNextPage)
        XCTAssertTrue(try browse(database, page: 3).matches.isEmpty)
    }

    func testSiblingFilesUseSharedCurrentRecordingIdentity() throws {
        let database = try LibraryDatabase.openInMemory()
        let first = try seedFile(database, number: 1)
        let sibling = try seedFile(database, number: 2, linked: false)
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE files SET track_id = (SELECT track_id FROM files WHERE id = ?) WHERE id = ?",
                arguments: [first, sibling]
            )
        }
        XCTAssertEqual(try browse(database, filter: .unmatched).totalMatchCount, 0)
        try database.writer.write { db in
            try db.execute(sql: "UPDATE tracks SET musicbrainz_recording_id = NULL")
        }
        let results = try browse(database, filter: .unmatched)
        XCTAssertEqual(results.matches.map(\.id), [first, sibling])
        XCTAssertEqual(results.totalMatchCount, 2)
    }

    func testEmptyLibraryAndInvalidPages() throws {
        let database = try LibraryDatabase.openInMemory()
        let results = try browse(database)
        XCTAssertTrue(results.matches.isEmpty)
        XCTAssertEqual(results.totalMatchCount, 0)
        XCTAssertFalse(results.hasNextPage)
        XCTAssertThrowsError(try browse(database, page: -1))
        XCTAssertThrowsError(try browse(database, page: Int.max))
    }
}
