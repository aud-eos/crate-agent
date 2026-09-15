import CoreServices
@testable import CrateAgent
import XCTest

private actor BatchProbe {
    enum Failure: Error { case expected }
    var handled: [UInt64] = []
    var checkpoints: [UInt64] = []
    var continuation: CheckedContinuation<Void, Error>?
    var shouldSuspend = true
    func handle(_ batch: FilesystemEventBatch) async throws {
        handled.append(batch.highestEventID)
        if shouldSuspend {
            shouldSuspend = false
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    func fail() {
        continuation?.resume(throwing: Failure.expected); continuation = nil
    }

    func checkpoint(_ identifier: UInt64) {
        checkpoints.append(identifier)
    }

    func snapshot() -> ([UInt64], [UInt64]) {
        (handled, checkpoints)
    }
}

final class FilesystemEventProcessorTests: XCTestCase {
    func testFailedHeadBlocksLaterWorkAndCheckpointUntilRetry() async throws {
        let probe = BatchProbe()
        let processor = FilesystemEventProcessor(handler: { try await probe.handle($0) }, checkpoint: { await probe.checkpoint($0) })
        let first = Task { try await processor.enqueue(.init(observations: [], highestEventID: 10)) }
        for _ in 0 ..< 1000 {
            if await probe.snapshot().0 == [10] {
                break
            }
            await Task.yield()
        }
        try await processor.enqueue(.init(observations: [], highestEventID: 20))
        let suspended = await probe.snapshot()
        XCTAssertEqual(suspended.0, [10])
        XCTAssertEqual(suspended.1, [])
        await probe.fail()
        do { try await first.value; XCTFail("Failure must surface") } catch BatchProbe.Failure.expected {}
        let failed = await probe.snapshot()
        XCTAssertEqual(failed.0, [10])
        XCTAssertEqual(failed.1, [])
        try await processor.retry()
        let completed = await probe.snapshot()
        XCTAssertEqual(completed.0, [10, 10, 20])
        XCTAssertEqual(completed.1, [10, 20])
    }

    func testDroppedEventsAndDirectoryRenameRequestOneReconciliation() {
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped] {
            let observation = FSEventsObservation(path: "/fixture", rawFlags: UInt32(flag))
            XCTAssertTrue(FilesystemEventBatch(observations: [observation], highestEventID: 1).requiresReconciliation)
        }
        let renamed = FSEventsObservation(path: "/fixture", isDirectory: true, wasRenamed: true)
        XCTAssertTrue(FilesystemEventBatch(observations: [renamed, renamed], highestEventID: 2).requiresReconciliation)
    }
}
