@testable import CrateAgent
import XCTest

final class ReleaseSelectorTests: XCTestCase {
    /// Deliberately out of date order and mixing an unofficial release in
    /// with official ones, so tests that pick "the earliest official" are
    /// discriminating rather than accidentally passing because the input
    /// happened to already be sorted.
    private let releases: [MBRelease] = [
        MBRelease(id: "r-remaster", title: "Illmatic (Remastered)", date: "2004-05-18", status: "Official"),
        MBRelease(id: "r-promo", title: "Illmatic Promo", date: "1994-01-01", status: "Promotion"),
        MBRelease(id: "r-original", title: "Illmatic", date: "1994-04-19", status: "Official"),
        MBRelease(id: "r-undated", title: "Illmatic (Unknown Pressing)", date: nil, status: "Official"),
    ]

    func testPrefersExistingAlbumMatch() {
        let picked = ReleaseSelector.defaultRelease(from: releases, existingAlbum: "illmatic")
        XCTAssertEqual(picked?.title, "Illmatic")
    }

    func testFallsBackToEarliestOfficial() {
        let picked = ReleaseSelector.defaultRelease(from: releases, existingAlbum: nil)
        XCTAssertEqual(picked?.date, "1994-04-19")
    }

    func testFallsBackToEarliestRegardlessOfStatusWhenNoneOfficial() {
        let noOfficialReleases: [MBRelease] = [
            MBRelease(id: "r-b", title: "Bootleg B", date: "1999-06-01", status: "Bootleg"),
            MBRelease(id: "r-a", title: "Bootleg A", date: "1997-03-01", status: "Bootleg"),
        ]

        let picked = ReleaseSelector.defaultRelease(from: noOfficialReleases, existingAlbum: nil)

        XCTAssertEqual(picked?.id, "r-a")
    }

    func testUndatedReleaseNeverWinsOverADatedOne() {
        let undatedFirst: [MBRelease] = [
            MBRelease(id: "r-undated", title: "Mystery Pressing", date: nil, status: "Official"),
            MBRelease(id: "r-dated", title: "Real Pressing", date: "2001-01-01", status: "Official"),
        ]

        let picked = ReleaseSelector.defaultRelease(from: undatedFirst, existingAlbum: nil)

        XCTAssertEqual(picked?.id, "r-dated")
    }

    func testFirstElementWhenNoOfficialAndAllDatesUnparsable() {
        // No releases at all is the only nil case; when releases exist but
        // every disambiguator is exhausted, the first element wins.
        let allUndated: [MBRelease] = [
            MBRelease(id: "r-first", title: "First", date: nil, status: nil),
            MBRelease(id: "r-second", title: "Second", date: nil, status: nil),
        ]

        let picked = ReleaseSelector.defaultRelease(from: allUndated, existingAlbum: nil)

        XCTAssertEqual(picked?.id, "r-first")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ReleaseSelector.defaultRelease(from: [], existingAlbum: "x"))
    }
}
