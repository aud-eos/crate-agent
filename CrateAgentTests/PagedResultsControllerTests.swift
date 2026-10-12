@testable import CrateAgent
import XCTest

@MainActor
final class PagedResultsControllerTests: XCTestCase {
    func testDistantJumpsAndOversizedViewportRemainBounded() async {
        let source = PagedQueryFixture(rowCount: 30000, signature: "first")
        let controller = PagedResultsController<PagedQueryFixture>()
        await controller.open(source)
        controller.setViewport(0 ..< 40)
        await pagingEventually { controller.row(at: 0) != nil }
        controller.setViewport(29950 ..< 30000)
        await pagingEventually { controller.row(at: 29999) != nil }
        XCTAssertEqual(controller.totalCount, 30000)
        XCTAssertNil(controller.row(at: 0))
        XCTAssertLessThanOrEqual(controller.peakCachedRowCount, 1000)
        controller.setViewport(1001 ..< 2402)
        await pagingEventually { controller.row(at: 1001) != nil && controller.row(at: 2401) != nil }
        XCTAssertLessThanOrEqual(controller.cachedRowCount, controller.cacheLimit)
        XCTAssertGreaterThan(controller.effectivePageSize, 200)
        controller.stop()
        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(controller.cachedRowCount, 0)
    }

    func testLateRowsAndErrorsCannotPublishAcrossGeneration() async {
        let first = PagedQueryFixture(rowCount: 30000, signature: "old")
        await first.holdPages()
        await first.failNextPage()
        let controller = PagedResultsController<PagedQueryFixture>()
        await controller.open(first)
        controller.setViewport(0 ..< 40)
        await pagingEventually { await first.requestedRanges().count == 2 }
        let second = PagedQueryFixture(rowCount: 10, signature: "new")
        await controller.open(second)
        controller.setViewport(0 ..< 10)
        await first.releaseAll()
        await pagingEventually { controller.row(at: 0)?.name == "new-0" }
        XCTAssertEqual(controller.totalCount, 10)
        XCTAssertNil(controller.error)
    }

    func testCountAndPageFailuresStayVisibleUntilRetry() async {
        let source = PagedQueryFixture(rowCount: 12, signature: "retry")
        let controller = PagedResultsController<PagedQueryFixture>()
        await source.setCountFailure(true)
        await controller.open(source)
        XCTAssertNotNil(controller.error)
        await source.setCountFailure(false)
        await source.failNextPage()
        controller.retry()
        await pagingEventually { controller.totalCount == 12 }
        controller.setViewport(0 ..< 12)
        await pagingEventually { controller.error != nil }
        XCTAssertNil(controller.row(at: 0))
        XCTAssertEqual(controller.totalCount, 12)
        controller.retry()
        await pagingEventually { controller.row(at: 0) != nil }
        XCTAssertNil(controller.error)
    }

    func testFailedCapturePreservesSelectionAndClearWinsOverLateCapture() async {
        let source = PagedQueryFixture(rowCount: 10, signature: "selection")
        let provider = FixtureSelectionProvider()
        let controller = PagedSelectionController(provider: provider)
        controller.updateScope(source, visibleIdentities: [.init(id: 1, revision: 0)])
        await pagingEventually { !controller.isBusy }
        controller.set([.init(id: 1, revision: 0)], selected: true)
        await pagingEventually { controller.summary?.total == 1 }
        await provider.failCapture(true)
        controller.setScope(source, selected: true)
        await pagingEventually { controller.error != nil }
        XCTAssertEqual(controller.summary?.total, 1)
        await provider.failCapture(false)
        await provider.holdCapture()
        controller.retry()
        await pagingEventually { await provider.isCapturing() }
        controller.clear()
        await provider.releaseCapture()
        await pagingEventually { !controller.isBusy && controller.summary?.total == 0 }
        XCTAssertTrue(controller.visibleSelectedIDs.isEmpty)
        controller.stop()
    }
}

@MainActor
func pagingEventually(file: StaticString = #filePath, line: UInt = #line, _ predicate: () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if await predicate() {
            return
        }
        await Task.yield()
    }
    XCTFail("Paging did not reach the expected state", file: file, line: line)
}
