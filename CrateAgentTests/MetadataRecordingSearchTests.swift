@testable import CrateAgent
import XCTest

final class MetadataRecordingSearchTests: XCTestCase {
    func testMatchingVersionOutranksBaseRecordingWhichOutranksOtherVersionsAndArtists() throws {
        let query = try XCTUnwrap(MetadataSearchQuery(artist: "A Guy Called Gerald", title: "Voodoo Ray (Intro)"))
        let hits = [
            details("other-artist", title: "Voodoo Ray", artist: "Somebody Else"),
            details("remix", title: "Voodoo Ray (Remix)", artist: "A Guy Called Gerald"),
            details("base", title: "Voodoo Ray", artist: "A Guy Called Gerald"),
            details("intro", title: "Voodoo Ray", artist: "A Guy Called Gerald", disambiguation: "intro"),
        ]

        let ranked = MetadataMatchRanker.rank(hits, for: query)

        XCTAssertEqual(query.baseTitle, "Voodoo Ray")
        XCTAssertEqual(ranked.map(\.details.id), ["intro", "base", "remix", "other-artist"])
        XCTAssertGreaterThan(ranked[1].textScore, 0.9, "A base recording stays a credible source for a DJ edit")
    }

    private func details(_ identifier: String, title: String, artist: String, disambiguation: String? = nil) -> MBRecordingDetails {
        MBRecordingDetails(id: identifier, title: title, creditedArtistName: artist, disambiguation: disambiguation, durationMilliseconds: nil)
    }
}
