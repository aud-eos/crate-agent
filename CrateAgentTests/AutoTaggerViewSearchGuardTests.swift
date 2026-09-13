@testable import CrateAgent
import XCTest

/// Covers `AutoTaggerView.shouldPublishSearchResult`, the pure guard
/// extracted from the selection-stage search `.task` so the "discard a
/// stale/superseded search result" rule is unit-testable without the
/// SwiftUI/`Task` machinery around it (see `performSearch`).
final class AutoTaggerViewSearchGuardTests: XCTestCase {
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
