@testable import CrateAgent
import XCTest

final class FilesystemReplayBoundaryTests: XCTestCase {
    actor Probe {
        var checkpoints: [UInt64] = []
        var paths: [String] = []
        func checkpoint(_ value: UInt64) {
            checkpoints.append(value)
        }

        func handle(_ batch: FilesystemEventBatch) {
            paths += batch.observations.map(\.path)
        }
    }

    func testBoundaryWaitsForOrderedDeliveryAndRetainsLaterEventsUntilSuccess() async throws {
        let probe = Probe()
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { batch in await probe.handle(batch) }, checkpoint: { value in await probe.checkpoint(value) })
        let waiting = Task { try await processor.collectStartupReplay(through: 2) }
        try await processor.enqueue(.init(observations: [], highestEventID: 10, deliverySequence: 2, replayBoundary: true, historyComplete: true))
        try await processor.enqueue(.init(observations: [.init(path: "/first", isFile: true)], highestEventID: 10, deliverySequence: 1))
        let receipt = try await waiting.value
        XCTAssertEqual(receipt.observations.map(\.path), ["/first"])
        XCTAssertEqual(receipt.eventID, 10)
        XCTAssertFalse(receipt.requiresReconciliation)
        try await processor.enqueue(.init(observations: [.init(path: "/later", isFile: true)], highestEventID: 11, deliverySequence: 3))
        let before = await probe.checkpoints
        let handledBefore = await probe.paths
        XCTAssertEqual(before, [])
        XCTAssertEqual(handledBefore, [])
        try await processor.finishStartupReplay(receipt)
        try await processor.retry()
        let after = await probe.checkpoints
        let handledAfter = await probe.paths
        XCTAssertEqual(after, [10, 11])
        XCTAssertEqual(handledAfter, ["/later"])
    }

    func testEmptyBoundaryCancellationAndLostHistory() async throws {
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { _ in }, checkpoint: { _ in })
        let cancelled = Task { try await processor.collectStartupReplay(through: 99) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled replay returned evidence") } catch is CancellationError {}
        try await processor.enqueue(.init(observations: [], highestEventID: 0, deliverySequence: 1, replayBoundary: true, historyComplete: true))
        let empty = try await processor.collectStartupReplay(through: 1)
        XCTAssertEqual(empty.observations, [])
        XCTAssertFalse(empty.requiresReconciliation)
        try await processor.enqueue(.init(observations: [.init(path: "/root", requiresReconciliation: true)], highestEventID: 20, deliverySequence: 2))
        try await processor.enqueue(.init(observations: [], highestEventID: 20, deliverySequence: 3, replayBoundary: true, historyComplete: true))
        let lost = try await processor.collectStartupReplay(through: 3)
        XCTAssertTrue(lost.requiresReconciliation)
    }

    func testNativeBoundaryOrdersDeliveredFileAndSubsequentBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let processor = FilesystemEventProcessor(initiallyPaused: true, handler: { _ in }, checkpoint: { _ in })
        let delivered = expectation(description: "Native file event delivered")
        delivered.assertForOverFulfill = false
        let watcher = FSEventsWatcher(watchedPaths: [directory.path], coalescingLatency: 0.01) { batch in
            if batch.observations.contains(where: { observation in URL(fileURLWithPath: observation.path).lastPathComponent == "written.wav" }) {
                delivered.fulfill()
            }
            Task {
                do { try await processor.enqueue(batch) }
                catch { XCTFail("Replay delivery failed: \(error)") }
            }
        }
        defer {
            watcher.stop()
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Replay fixture cleanup failed: \(error)") }
        }
        try watcher.start()
        let file = directory.appendingPathComponent("written.wav")
        try Data([1, 2, 3]).write(to: file)
        await fulfillment(of: [delivered], timeout: 10)
        let boundary = try await watcher.captureReplayBoundary()
        let receipt = try await processor.collectStartupReplay(through: boundary)
        XCTAssertTrue(receipt.observations.contains { observation in URL(fileURLWithPath: observation.path).lastPathComponent == "written.wav" }, "Delivered: \(receipt.observations); broad: \(receipt.requiresReconciliation)")
        let next = try await watcher.captureReplayBoundary()
        let repeated = try await processor.collectStartupReplay(through: next)
        XCTAssertGreaterThan(next, boundary)
        XCTAssertFalse(repeated.requiresReconciliation)
    }
}
