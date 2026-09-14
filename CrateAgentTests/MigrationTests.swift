@testable import CrateAgent
import GRDB
import XCTest

final class MigrationTests: XCTestCase {
    func testMigration007AddsMusicBrainzColumns() async throws {
        let database = try LibraryDatabase.openInMemory()
        let columnNames: [String] = try await database.writer.read { connection in
            try connection.columns(in: "tracks").map(\.name)
        }
        XCTAssertTrue(columnNames.contains("musicbrainz_release_id"))
        XCTAssertTrue(columnNames.contains("musicbrainz_artist_id"))
        XCTAssertTrue(columnNames.contains("isrc"))
    }
}
