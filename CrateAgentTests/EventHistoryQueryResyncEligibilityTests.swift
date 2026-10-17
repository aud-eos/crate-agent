@testable import CrateAgent
import XCTest

/// Unit tests for `EventHistoryQuery`'s Re-sync eligibility derivations
/// (findings #3999114447 / #3999974013).
final class EventHistoryQueryResyncEligibilityTests: XCTestCase {
    // MARK: - canResyncBatch: any replayable-Serato-projection event type

    func testCanResyncTrueForAutoTagOnlyBatch() {
        XCTAssertTrue(
            EventHistoryQuery.canResyncBatch(typeList: [EventType.musicBrainzMatchApplied.rawValue]),
            "an Auto-Tag-only batch is re-syncable, not just rename batches"
        )
    }

    func testCanResyncTrueForRevertBatch() {
        XCTAssertTrue(
            EventHistoryQuery.canResyncBatch(typeList: [EventType.musicBrainzMatchReverted.rawValue]),
            "an undo batch's reverted events are replayable (restore-write recovery)"
        )
    }

    func testCanResyncFalseForNonProjectingBatch() {
        XCTAssertFalse(
            EventHistoryQuery.canResyncBatch(typeList: [EventType.trackImported.rawValue]),
            "a batch with no Serato-projecting events is not re-syncable"
        )
    }

    // MARK: - batchHasBeenUndone: an undo:<id>:<uuid> batch exists

    func testBatchHasBeenUndoneWhenAnUndoBatchExists() {
        let original = "auto-tag-ABC"
        let all: Set<String> = [original, "undo:\(original):DEF"]
        XCTAssertTrue(EventHistoryQuery.batchHasBeenUndone(original, allBatchIds: all))
    }

    func testBatchNotUndoneWithoutAMatchingUndoBatch() {
        let original = "auto-tag-ABC"
        // An unrelated undo of a DIFFERENT batch must not count.
        let all: Set<String> = [original, "undo:auto-tag-XYZ:DEF"]
        XCTAssertFalse(EventHistoryQuery.batchHasBeenUndone(original, allBatchIds: all))
    }

    func testUndoBatchItselfIsNotConsideredUndone() {
        // The undo batch stays re-syncable so a failed restore write mid-undo
        // is recoverable — it's only "undone" if it in turn has been redone.
        let undoBatch = "undo:auto-tag-ABC:DEF"
        let all: Set<String> = ["auto-tag-ABC", undoBatch]
        XCTAssertFalse(EventHistoryQuery.batchHasBeenUndone(undoBatch, allBatchIds: all))
    }
}
