@testable import CrateAgent
import GRDB
import XCTest

/// Genre, BPM-range and compatible-key filters over a real WAL database, with keys stored in mixed notation.
final class LibraryFacetTests: XCTestCase {
    private var directory: URL!
    private var pool: DatabasePool!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryFacets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try LibraryDatabase.openWAL(at: directory.appendingPathComponent("library.sqlite"))
        pool = try XCTUnwrap(database.writer as? DatabasePool)
        try await pool.write { connection in try Self.seed(connection) }
    }

    override func tearDown() async throws {
        try pool.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testCamelotParsingAndCompatibilityAcrossNotations() {
        XCTAssertEqual(CamelotKey(parsing: "Am"), CamelotKey(parsing: "8A"))
        XCTAssertEqual(CamelotKey(parsing: "1m"), CamelotKey(parsing: "8A"))
        XCTAssertEqual(CamelotKey(parsing: "C")?.label, "8B")
        XCTAssertEqual(CamelotKey(parsing: "Abm")?.label, "1A")
        XCTAssertEqual(CamelotKey(parsing: "8A")?.compatibleKeys.map(\.label).sorted(), ["7A", "8A", "8B", "9A"])
        XCTAssertEqual(CamelotKey(parsing: "12B")?.compatibleKeys.map(\.label).sorted(), ["11B", "12A", "12B", "1B"])
        for garbage in ["", "Unknown", "o", "H#m", "13A", "ßm"] {
            XCTAssertNil(CamelotKey(parsing: garbage), garbage)
        }
    }

    func testBPMRangeFieldsParseOpenEndsRejectBadInputAndRoundTrip() throws {
        let valid: [(lower: String, upper: String, range: ClosedRange<Double>?)] = [
            ("124", "128", 124 ... 128), (" 124.5 ", "128", 124.5 ... 128), ("", "", nil),
            ("124", "", 124 ... LibraryFacets.openUpperBPM), ("", "128", LibraryFacets.openLowerBPM ... 128), ("126", "126", 126 ... 126),
        ]
        for input in valid {
            let range = try LibraryFacets.bpmRange(lower: input.lower, upper: input.upper)
            XCTAssertEqual(range, input.range, "\(input)")
            let text = LibraryFacets.bpmText(range)
            XCTAssertEqual(try LibraryFacets.bpmRange(lower: text.lower, upper: text.upper), range, "round trip of \(input)")
        }
        XCTAssertEqual(LibraryFacets.bpmText(124.5 ... 128).lower, "124.5")
        XCTAssertEqual(LibraryFacets.bpmText(124 ... LibraryFacets.openUpperBPM).upper, "")
        let rejected: [(lower: String, upper: String, error: BPMRangeError)] = [
            ("abc", "", .notANumber), ("", "12x", .notANumber), ("inf", "", .notANumber), ("", "nan", .notANumber),
            ("-5", "128", .negative), ("130", "120", .reversed),
        ]
        for input in rejected {
            XCTAssertThrowsError(try LibraryFacets.bpmRange(lower: input.lower, upper: input.upper), "\(input)") { error in
                XCTAssertEqual(error as? BPMRangeError, input.error, "\(input)")
            }
        }
    }

    func testFacetsCombineWithChipAndSearch() async throws {
        let options = try await pool.read { connection in try LibraryFacetOptions.load(in: connection, filter: .active) }
        let house = try XCTUnwrap(options.genres.first { option in option.value == "House" })
        XCTAssertEqual(house.storedValues, ["House", "house "])
        var facets = LibraryFacets(genres: house.storedValues, bpmRange: 126 ... 128, compatibleKey: CamelotKey(parsing: "8A"))
        facets.keyValues = try options.keyValues(compatibleWith: XCTUnwrap(facets.compatibleKey))
        XCTAssertEqual(facets.keyValues, ["Am", "8A", "Em"])
        let found = try await titles(.init(search: "Artist", chip: .needsWork, facets: facets))
        XCTAssertEqual(found, ["House 128.000 Am", "House 126.5 Em", "house 127 8A"])
        // Facet-only query on a family whose alternate is the only House Alt file: the alternate is revealed beneath its main row.
        let roles = try await visibleRoles(.init(facets: LibraryFacets(genres: ["House Alt"])))
        XCTAssertEqual(roles, [.main, .alternate])
    }

    // MARK: - Helpers

    private func rows(_ query: LibraryBrowseQuery) async throws -> [BrowserRow] {
        let snapshot = try await LibraryPagedSnapshot.open(pool: pool, query: query)
        return try await snapshot.rows(in: 0 ..< snapshot.count())
    }

    private func titles(_ query: LibraryBrowseQuery) async throws -> [String] {
        try await rows(query).map { row in row.title ?? row.path }
    }

    private func visibleRoles(_ query: LibraryBrowseQuery) async throws -> [LibraryFamilyRole?] {
        try await rows(query).map(\.familyRole)
    }

    /// Every "Artist" file but the kept one needs work: no crate stamp leaves In crate unknown.
    private static func seed(_ connection: GRDB.Database) throws {
        var inode: Int64 = 0
        @discardableResult
        func add(_ title: String, artist: String = "Artist", genre: String, bpm: String, key: String, trackID: Int64? = nil) throws -> Int64 {
            inode += 1
            var file = FileRecord(path: String(format: "/Music/%02d.mp3", inode), volumeUuid: "volume", inode: inode, fileSize: 10, mtime: 5, trackId: trackID,
                                  bitrateKbps: 320, artist: artist, title: title, genre: genre, bpm: bpm, musicalKey: key)
            file.libraryMembership = .active
            file.fileAvailability = .available
            try file.insert(connection)
            return try XCTUnwrap(file.id)
        }
        try add("House 128.000 Am", genre: "House", bpm: "128.000", key: "Am")
        try add("House 126.5 Em", genre: "House", bpm: "126.5", key: "Em")
        let kept = try add("House 128 8A Kept", genre: "House", bpm: "128", key: "8A")
        try connection.execute(sql: "INSERT INTO keeper_marks (file_id, marked_revision, marked_at) VALUES (?, 0, 1)", arguments: [kept])
        try add("House No BPM", genre: "House", bpm: "", key: "Am")
        try add("House Zero BPM", genre: "House", bpm: "0", key: "Am")
        try add("House 131 Am", genre: "House", bpm: "131", key: "Am")
        try add("House 127 Unknown", genre: "House", bpm: "127", key: "Unknown")
        try add("Techno 128 Am", genre: "Techno", bpm: "128", key: "Am")
        try add("House 128 Unsearched", artist: "Someone", genre: "House", bpm: "128", key: "Am")
        try add("house 127 8A", genre: "house ", bpm: "127", key: "8A")

        var family = SongFamilyRecord()
        try family.insert(connection)
        var mainTrack = TrackRecord(fingerprintHash: Data("main".utf8), workId: family.id)
        try mainTrack.insert(connection)
        var alternateTrack = TrackRecord(fingerprintHash: Data("alternate".utf8), workId: family.id)
        try alternateTrack.insert(connection)
        try add("Family Main", artist: "Someone", genre: "Techno", bpm: "125", key: "Em", trackID: mainTrack.id)
        try add("Family Alternate", artist: "Someone", genre: "House Alt", bpm: "125", key: "Em", trackID: alternateTrack.id)
        try connection.execute(sql: "UPDATE works SET representative_track_id = ? WHERE id = ?", arguments: [mainTrack.id, family.id])
    }
}
