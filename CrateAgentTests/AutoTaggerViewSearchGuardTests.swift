@testable import CrateAgent
import XCTest

/// Covers the selection search's query-bound presentation and stale-completion guard.
final class AutoTaggerViewSearchGuardTests: XCTestCase {
    func testReturningToPreviousQueryDoesNotReviveOldError() {
        var state = AutoTagSearchState()
        state.query = "first"
        state.publish(.failure(NSError(domain: "search-test", code: 1)), for: "first")
        XCTAssertNotNil(state.error)
        state.query = "second"
        state.query = "first"
        XCTAssertNil(state.error)
        XCTAssertTrue(state.isSearching)
    }

    func testReturningToPreviousQueryDoesNotReviveOldRows() {
        for interveningQuery in ["", "second"] {
            var state = AutoTagSearchState()
            state.query = "first"
            state.publish(.success(AutoTagFileSearch.Results(matches: [
                BrowserRow(id: 1, path: "/first.mp3", artist: "First"),
            ], totalMatchCount: 1)), for: "first")
            XCTAssertEqual(state.results.matches.map(\.id), [1])
            state.query = interveningQuery
            state.query = "first"
            XCTAssertTrue(state.results.matches.isEmpty)
            XCTAssertEqual(state.results.totalMatchCount, 0)
            XCTAssertTrue(state.isSearching)
        }
    }

    func testChangingQueryImmediatelyHidesPreviouslyPublishedRowsAndCount() {
        var state = AutoTagSearchState()
        state.query = "first"
        state.publish(.success(AutoTagFileSearch.Results(matches: [
            BrowserRow(id: 1, path: "/first.mp3", artist: "First", title: "Song", album: nil, bpm: nil, musicalKey: nil),
        ], totalMatchCount: 300)), for: "first")
        XCTAssertEqual(state.results.matches.map(\.id), [1])
        XCTAssertFalse(state.isSearching)
        state.query = "second"
        XCTAssertTrue(state.results.matches.isEmpty)
        XCTAssertEqual(state.results.totalMatchCount, 0)
        XCTAssertTrue(state.isSearching)
        state.publish(.success(.empty), for: "first")
        XCTAssertTrue(state.isSearching)
        state.publish(.success(.empty), for: "second")
        XCTAssertFalse(state.isSearching)
    }

    func testChangingQueryHidesPreviousErrorAndEmptyQueryNeverLoads() {
        var state = AutoTagSearchState()
        state.query = "first"
        state.publish(.failure(NSError(domain: "search-test", code: 1)), for: "first")
        XCTAssertNotNil(state.error)
        state.query = "second"
        XCTAssertNil(state.error)
        XCTAssertTrue(state.isSearching)
        state.query = "   "
        XCTAssertFalse(state.isSearching)
        XCTAssertTrue(state.results.matches.isEmpty)
    }

    func testPublishesWhenNotCancelledAndQueryStillMatches() {
        XCTAssertTrue(AutoTaggerView.shouldPublishSearchResult(
            queryTaskRanFor: "voodoo",
            currentQuery: "voodoo",
            isCancelled: false
        ))
    }

    func testDropsResultWhenTaskWasCancelled() {
        XCTAssertFalse(AutoTaggerView.shouldPublishSearchResult(
            queryTaskRanFor: "voodoo",
            currentQuery: "voodoo",
            isCancelled: true
        ))
    }

    /// The race this guard exists for: an older, slower query's read
    /// finishes after a newer query has already taken over the search
    /// box. Cancellation alone can't be relied on to have caught this
    /// (cooperative cancellation can lose the race), so a query mismatch
    /// must independently block publishing.
    func testDropsResultWhenAnUncancelledOlderQueryLosesTheRaceToANewerOne() {
        XCTAssertFalse(AutoTaggerView.shouldPublishSearchResult(
            queryTaskRanFor: "voodoo",
            currentQuery: "voodoo ray",
            isCancelled: false
        ))
    }

    func testComparesAgainstTheTrimmedCurrentQuery() {
        XCTAssertTrue(AutoTaggerView.shouldPublishSearchResult(
            queryTaskRanFor: "voodoo",
            currentQuery: "  voodoo  ",
            isCancelled: false
        ))
    }
}
