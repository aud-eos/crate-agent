import AppKit
@testable import CrateAgent
import GRDB
import os
import SwiftUI
import XCTest

final class FingerprintResponsivenessTests: XCTestCase {
    func testStopAndImmediateRestartNeverOverlapDecodersAndResumePendingFiles() async throws {
        let database = try LibraryDatabase.openInMemory()
        try await database.writer.write { connection in
            for identifier in 1 ... 4 {
                var file = PagedLibraryFixture.file(identifier)
                try file.insert(connection)
            }
        }
        let entered = expectation(description: "first decoder entered")
        let overlap = expectation(description: "decoder pool exceeded its limit")
        overlap.isInverted = true
        overlap.assertForOverFulfill = false
        let resumed = expectation(description: "replacement run completed pending rows")
        let release = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: (calls: 0, active: 0, peak: 0, reported: false))
        let worker = FingerprintWorker(database: database, concurrency: 1, fingerprintFunction: { _ in
            let ordinal = state.withLock { state in
                state.calls += 1; state.active += 1
                state.peak = max(state.peak, state.active)
                if state.active > 1 {
                    overlap.fulfill()
                }
                return state.calls
            }
            defer { state.withLock { state in state.active -= 1 } }
            if ordinal == 1 {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
            }
            return [42, 43]
        }, pollIntervalSeconds: 0.01, batchCooldownMillis: 0)
        await worker.start()
        await fulfillment(of: [entered], timeout: 5)
        await worker.stop()
        await worker.start { progress in
            if progress.totalDone >= 4, state.withLock({ state in
                guard !state.reported else { return false }
                state.reported = true; return true
            }) {
                resumed.fulfill()
            }
        }
        await fulfillment(of: [overlap], timeout: 0.15)
        release.signal()
        await fulfillment(of: [resumed], timeout: 5)
        await worker.stop()
        await worker.waitUntilStopped()
        XCTAssertEqual(state.withLock { state in state.peak }, 1)
        let rows = try await database.writer.read { connection in try FileRecord.fetchAll(connection) }
        XCTAssertTrue(rows.allSatisfy { file in file.fingerprintStatus == .done && FingerprintEncoder.deserialize(file.chromaprintFingerprint ?? Data()) == [42, 43] })
        let failure = await worker.lastError
        XCTAssertNil(failure)
    }

    @MainActor
    func testThirtyThousandPendingFilesRemainBrowsableDuringRealDecoding() async throws {
        LibraryNavigationFixture.prepareWindowChrome()
        let fixture = try await Task.detached(priority: .background) { try FingerprintBacklogFixture() }.value
        defer {
            do { try fixture.close() }
            catch { XCTFail("Fingerprint fixture cleanup: \(error)") }
        }
        let decoded = OSAllocatedUnfairLock(initialState: 0)
        let firstDecode = expectation(description: "native audio decoding started")
        let worker = FingerprintWorker(database: fixture.library.database, fingerprintFunction: { path in
            let ordinal = decoded.withLock { count in count += 1; return count }
            if ordinal == 1 {
                firstDecode.fulfill()
            }
            return try fingerprintAudioFile(filePath: path)
        })
        let progress = OSAllocatedUnfairLock(initialState: FingerprintWorker.Progress?.none)
        await worker.start { update in progress.withLock { current in current = update } }
        do {
            // Liveness bound, not a latency budget: the decoder runs at background QoS and a
            // loaded machine may delay its start, but the measured windows open only after it runs.
            await fulfillment(of: [firstDecode], timeout: 120)
            let model = try LibraryBrowserModel(database: fixture.library.database)
            let selection = LibraryNavigationSelection()
            let gate = LibrarySyncReadiness()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            defer { model.stop(); window.close() }
            var maximumMainGap = Duration.zero
            let heartbeat = Task { @MainActor in
                var previous = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                    maximumMainGap = max(maximumMainGap, previous.duration(to: .now))
                    previous = .now
                }
            }
            defer { heartbeat.cancel() }
            let renderStart = ContinuousClock.now
            await model.start()
            let host = NSHostingView(rootView: LibraryNavigationFixture(selection: selection, model: model, readiness: gate))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await pagingEventually { model.results.totalCount == 30000 && model.results.row(at: 0) != nil }
            let rendering = renderStart.duration(to: .now)
            func tables(in view: NSView) -> [NSTableView] {
                (view as? NSTableView).map { table in [table] } ?? view.subviews.flatMap { child in tables(in: child) }
            }
            let libraryTable = try XCTUnwrap(tables(in: host).first { table in table is PagedNSTableView })
            let sidebar = try XCTUnwrap(tables(in: host).first { table in !(table is PagedNSTableView) && table.numberOfRows == MainWindowView.Section.allCases.count - 1 })
            var maximumScroll = Duration.zero
            var maximumNavigation = Duration.zero
            for iteration in 0 ..< 10 {
                let row = iteration.isMultiple(of: 2) ? 29999 : 0
                let scrollStart = ContinuousClock.now
                libraryTable.scrollRowToVisible(row)
                host.layoutSubtreeIfNeeded()
                await pagingEventually { model.results.row(at: row) != nil }
                window.displayIfNeeded()
                maximumScroll = max(maximumScroll, scrollStart.duration(to: .now))
                let navigationStart = ContinuousClock.now
                let section: MainWindowView.Section = iteration.isMultiple(of: 2) ? .history : .library
                sidebar.selectRowIndexes(IndexSet(integer: iteration.isMultiple(of: 2) ? 4 : 0), byExtendingSelection: false)
                await pagingEventually { selection.section == section }
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                maximumNavigation = max(maximumNavigation, navigationStart.duration(to: .now))
            }
            // Stopping lets in-flight decodes finish and flush, so the drain itself proves progress
            // without a wall-clock deadline on background work.
            await worker.stop()
            await worker.waitUntilStopped()
            heartbeat.cancel()
            await heartbeat.value
            let final = try XCTUnwrap(progress.withLock { current in current })
            XCTAssertGreaterThan(final.totalDone, 0)
            XCTAssertGreaterThan(final.totalPending, 29000)
            XCTAssertEqual(final.totalFailed, 0)
            XCTAssertNil(final.error)
            XCTAssertLessThan(rendering, .milliseconds(500))
            XCTAssertLessThan(maximumScroll, .milliseconds(500))
            XCTAssertLessThan(maximumNavigation, .milliseconds(500))
            XCTAssertLessThan(maximumMainGap, .milliseconds(500))
            let result = "FINGERPRINT_RESPONSIVENESS pending=30000 native_audio=true linked_120s_wav=true decode_calls=\(decoded.withLock { count in count }) done=\(final.totalDone) render=\(rendering) scroll_max=\(maximumScroll) navigation_max=\(maximumNavigation) main_gap_max=\(maximumMainGap)"
            print(result)
            let attachment = XCTAttachment(string: result)
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            await worker.stop()
            await worker.waitUntilStopped()
            throw error
        }
    }
}

private final class FingerprintBacklogFixture: @unchecked Sendable {
    let library: PagedLibraryFixture
    init() throws {
        library = try PagedLibraryFixture()
        let audio = library.directory.appendingPathComponent("source.wav")
        let sampleRate = 44100
        let sampleCount = sampleRate * 120
        var bytes = Data()
        func append(_ value: some FixedWidthInteger) {
            var encoded = value.littleEndian
            withUnsafeBytes(of: &encoded) { raw in bytes.append(contentsOf: raw) }
        }
        bytes.append(contentsOf: "RIFF".utf8); append(UInt32(36 + sampleCount * 2))
        bytes.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        bytes.append(contentsOf: "data".utf8); append(UInt32(sampleCount * 2))
        var second = Data()
        for sample in 0 ..< sampleRate {
            var value = Int16(sin(Double(sample) * 2 * .pi * 440 / Double(sampleRate)) * 12000).littleEndian
            withUnsafeBytes(of: &value) { raw in second.append(contentsOf: raw) }
        }
        for _ in 0 ..< 120 {
            bytes.append(second)
        }
        try bytes.write(to: audio)
        try library.pool.write { connection in
            for identifier in 1 ... 30000 {
                let link = library.directory.appendingPathComponent("track-\(identifier).wav")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: audio)
                try connection.execute(sql: "UPDATE files SET path = ?, file_size = ? WHERE id = ?", arguments: [link.path, bytes.count, identifier])
            }
        }
    }

    func close() throws {
        try library.close()
    }
}
