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

    // MARK: - E-I: the exact-title subset is ranked, not first-array-element

    /// Three releases all share the on-file album's exact title —
    /// official, bootleg, and a later reissue — deliberately out of date
    /// order and with the official one NOT first in the array. The
    /// official/earliest pressing must win, not `releases.first`.
    func testExactTitleSubsetIsRankedOfficialThenEarliestNotFirstElement() {
        let exactTitleReleases: [MBRelease] = [
            MBRelease(id: "r-bootleg", title: "Illmatic", date: "1993-12-01", status: "Bootleg"),
            MBRelease(id: "r-reissue", title: "Illmatic", date: "2004-05-18", status: "Official"),
            MBRelease(id: "r-official", title: "Illmatic", date: "1994-04-19", status: "Official"),
        ]

        let picked = ReleaseSelector.defaultRelease(from: exactTitleReleases, existingAlbum: "illmatic")

        XCTAssertEqual(picked?.id, "r-official", "the earliest OFFICIAL exact-title release must win, not the first array element")
    }

    /// Within the exact-title subset, when none are official the
    /// earliest by date still wins over array order.
    func testExactTitleSubsetFallsBackToEarliestWhenNoneOfficial() {
        let exactTitleReleases: [MBRelease] = [
            MBRelease(id: "r-later", title: "Illmatic", date: "1999-01-01", status: "Bootleg"),
            MBRelease(id: "r-earlier", title: "Illmatic", date: "1994-04-19", status: "Bootleg"),
        ]

        let picked = ReleaseSelector.defaultRelease(from: exactTitleReleases, existingAlbum: "illmatic")

        XCTAssertEqual(picked?.id, "r-earlier")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ReleaseSelector.defaultRelease(from: [], existingAlbum: "x"))
    }
}
