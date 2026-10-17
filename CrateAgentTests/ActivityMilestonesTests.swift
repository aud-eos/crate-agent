@testable import CrateAgent
import XCTest

final class ActivityMilestonesTests: XCTestCase {
    func testFingerprintRunsLogStartIntervalsAndPerRunTotalsOnly() {
        var milestones = FingerprintActivityMilestones(fileInterval: 4)
        func entries(done: Int, failed: Int = 0, pending: Int) -> [String] {
            milestones.entries(for: .init(totalDone: done, totalFailed: failed, totalPending: pending, lastFingerprintedPath: nil))
        }

        XCTAssertEqual(entries(done: 2, pending: 8), ["Fingerprinting 10 files"])
        XCTAssertEqual(entries(done: 3, pending: 7), [])
        XCTAssertEqual(entries(done: 5, pending: 5), ["Fingerprinting 5 of 10 files"])
        XCTAssertEqual(entries(done: 6, pending: 4), [])
        XCTAssertEqual(entries(done: 8, failed: 1, pending: 1), ["Fingerprinting 9 of 10 files"])
        XCTAssertEqual(entries(done: 9, failed: 1, pending: 0), ["Fingerprinting finished · 10 files processed, 1 failed"])
        XCTAssertEqual(entries(done: 9, failed: 1, pending: 0), [], "An idle worker must not repeat the finish entry")

        XCTAssertEqual(entries(done: 11, failed: 1, pending: 0), ["Fingerprinting finished · 2 files processed"],
                       "A later run reports its own files, not the worker's lifetime totals")
        XCTAssertEqual(milestones.entries(for: .init(totalDone: 12, totalFailed: 1, totalPending: 3, lastFingerprintedPath: nil, error: "Fingerprint processing stopped: disk")),
                       ["Fingerprint processing stopped: disk"])
    }

    func testScanLogsStartIntervalsAndSummaryWhenProgressClears() {
        var milestones = ScanActivityMilestones(fileInterval: 100)
        func progress(_ completed: Int, indexed: Int, updated: Int) -> LibraryScanner.ScanProgress {
            .init(completedFileCount: completed, seratoReferenceCount: 250, filesIndexed: indexed, filesMetadataUpdated: updated,
                  filesSkipped: 0, lastChangedPath: nil)
        }

        XCTAssertEqual(milestones.entries(for: nil), [])
        XCTAssertEqual(milestones.entries(for: progress(50, indexed: 10, updated: 5)), ["Scanning 250 Serato references"])
        XCTAssertEqual(milestones.entries(for: progress(100, indexed: 20, updated: 6)),
                       ["Scanning 100 of 250 Serato references — 20 new, 6 metadata-updated"])
        XCTAssertEqual(milestones.entries(for: progress(150, indexed: 30, updated: 7)), [])
        XCTAssertEqual(milestones.entries(for: progress(250, indexed: 40, updated: 8)), [])
        XCTAssertEqual(milestones.entries(for: nil), ["Library scan finished · 250 of 250 Serato references — 40 new, 8 metadata-updated"])

        XCTAssertEqual(milestones.entries(for: progress(50, indexed: 1, updated: 0)), ["Scanning 250 Serato references"])
        XCTAssertEqual(milestones.entries(for: nil), ["Library scan stopped · 50 of 250 Serato references — 1 new, 0 metadata-updated"])
    }
}
