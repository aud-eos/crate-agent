import AppKit
@testable import CrateAgent
import GRDB
import os
import SwiftUI
import XCTest

@MainActor
final class OrganizePreviewTests: XCTestCase {
    func testLargePreviewRemainsResponsiveAndPreservesExplicitTargets() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let database = fixture.database
        let root = fixture.directory.appendingPathComponent("Library")
        let template = "$artist - $title.$ext"
        try await database.writer.write { connection in
            for identifier in 1 ... 50000 {
                let folder = identifier.isMultiple(of: 2) ? root.path : fixture.directory.appendingPathComponent("Downloads").path
                try connection.execute(sql: "INSERT INTO files (path, volume_uuid, inode, file_size, mtime, artist, title, library_membership, file_availability, fingerprint_status) VALUES (?, 'fixture', ?, 1, 1, 'Artist', ?, 'active', 'available', 'done')",
                                       arguments: ["\(folder)/\(identifier).mp3", identifier, identifier <= 1500 ? "Same title" : "Track \(identifier)"])
            }
        }
        let model = OrganizePreviewModel()
        try await measureScan(model, database: database, root: root, template: template, label: "idle")
        XCTAssertEqual(model.snapshot.rows.count, 50000)
        XCTAssertEqual(Set(model.snapshot.rows.map { row in row.plan.destinationPath }).count, 50000)
        XCTAssertEqual(model.visibleCount, 25000)
        XCTAssertEqual(model.selection.count, 0)
        let initialEvents = try await fixture.events()
        XCTAssertEqual(initialEvents, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Loading must never create move destinations")

        model.setSelected(true, identifier: 49999)
        XCTAssertEqual(model.selection.coverage(in: model.scope), .partial)
        model.selectScope(true)
        XCTAssertEqual(model.selection.count, 25000)
        XCTAssertEqual(model.selection.coverage(in: model.scope), .all)
        model.setSelected(false, identifier: 1)
        model.setFilter(.all)
        model.setSelected(true, identifier: 2)
        model.setFilter(.outsideOnly)
        XCTAssertEqual(model.hiddenSelectionCount, 1)
        model.selectScope(false)
        XCTAssertEqual(model.selection.count, 1, "Deselecting a scope must preserve hidden intentional selection")
        model.clearSelection()
        XCTAssertEqual(model.selection.count, 0)
        model.setSelected(true, identifier: 49999)
        model.setFilter(.all)
        model.setSelected(true, identifier: 2)
        model.setFilter(.outsideOnly)
        let exactBatch = await model.beginApply()
        XCTAssertEqual(Set(exactBatch.map(\.id)), [2, 49999])
        model.clearSelection()
        model.setFilter(.all)
        XCTAssertEqual(model.selection.count, 2, "Batch controls freeze while applying")
        XCTAssertEqual(model.filter, .outsideOnly)
        model.finishApply()

        let retained = try XCTUnwrap(model.snapshot.rows.first { row in row.id == 2 }?.plan)
        try await database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET title = 'Changed proposal' WHERE id = 49999")
            try connection.execute(sql: "INSERT INTO files (path, volume_uuid, inode, file_size, mtime, artist, title, library_membership, file_availability, fingerprint_status) VALUES (?, 'fixture', 50001, 1, 1, 'Artist', 'New match', 'active', 'available', 'done')", arguments: [fixture.directory.appendingPathComponent("new.mp3").path])
        }
        await model.rescan(database: database, musicFolder: root, template: template)
        XCTAssertTrue(model.isSelected(2))
        XCTAssertFalse(model.isSelected(49999))
        XCTAssertFalse(model.isSelected(50001), "New matches must not become selected")
        XCTAssertNotNil(model.notice)
        XCTAssertEqual(try model.snapshot.rows[XCTUnwrap(model.snapshot.indexesByID[2])].plan, retained)

        try await verifyCancelledAndSupersededScan(model, database: database, root: root, template: template)
        try verifyVirtualizedRendering(model)
        verifyReusableTableAndKeyboard()

        for identifier in 1 ... 32 {
            _ = try await fixture.add("fingerprint-\(identifier).wav", bytes: FinalRemovalIntegrationTests.wav(sample: UInt8(identifier), durationSeconds: 30))
        }
        let activeDecoders = OSAllocatedUnfairLock(initialState: 0)
        let worker = FingerprintWorker(database: database, concurrency: 2, fingerprintFunction: { path in
            activeDecoders.withLock { count in count += 1 }
            defer { activeDecoders.withLock { count in count -= 1 } }
            return try fingerprintAudioFile(filePath: path)
        })
        async let fingerprinting = worker.processAllPendingOnce()
        try await measureScan(model, database: database, root: root, template: template, label: "fingerprinting", isFingerprinting: { activeDecoders.withLock { count in count > 0 } })
        let progress = try await fingerprinting
        XCTAssertEqual(progress.totalDone, 32)
        XCTAssertEqual(progress.totalFailed, 0)
        let finalEvents = try await fixture.events()
        XCTAssertEqual(finalEvents, 0, "Preview and fingerprint reads must not journal file moves")
    }

    private func measureScan(_ model: OrganizePreviewModel, database: LibraryDatabase, root: URL, template: String, label: String, isFingerprinting: @escaping @Sendable () -> Bool = { false }) async throws {
        let pulse = MainActorPulse(isFingerprinting: isFingerprinting)
        let heartbeat = Task { await pulse.run() }
        await Task.yield()
        let start = ContinuousClock.now
        await model.rescan(database: database, musicFolder: root, template: template)
        let elapsed = start.duration(to: .now)
        heartbeat.cancel()
        await heartbeat.value
        XCTAssertNil(model.error)
        XCTAssertGreaterThan(pulse.samples, 5)
        XCTAssertLessThan(pulse.maximumGap, .milliseconds(250), "Main actor blocked during \(label) scan")
        if label == "fingerprinting" {
            XCTAssertGreaterThan(pulse.fingerprintingSamples, 0, "Real audio decoding must overlap the preview scan")
        }
        print("ORGANIZE_PERF \(label) decoding_samples=\(pulse.fingerprintingSamples) rows=\(model.snapshot.rows.count) load=\(elapsed) max_main_gap=\(pulse.maximumGap)")
    }

    private func verifyCancelledAndSupersededScan(_ model: OrganizePreviewModel, database: LibraryDatabase, root: URL, template: String) async throws {
        let entered = expectation(description: "Old scan reached database reader")
        let release = DispatchSemaphore(value: 0)
        let intercepted = OSAllocatedUnfairLock(initialState: false)
        try await database.writer.write { connection in
            connection.trace { event in
                guard event.expandedDescription.contains("ORDER BY id"), event.expandedDescription.contains("membership_revision") else { return }
                let intercept = intercepted.withLock { intercepted in
                    guard !intercepted else { return false }
                    intercepted = true
                    return true
                }
                guard intercept else { return }
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
            }
        }
        let previousGeneration = model.snapshot.generation
        let oldScan = Task { await model.rescan(database: database, musicFolder: root, template: template) }
        await fulfillment(of: [entered], timeout: 5)
        let cancelStart = ContinuousClock.now
        model.cancelScan()
        XCTAssertLessThan(cancelStart.duration(to: .now), .milliseconds(50))
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.snapshot.generation, previousGeneration)
        let newScan = Task { await model.rescan(database: database, musicFolder: root, template: "$title.$ext") }
        await Task.yield()
        release.signal()
        await oldScan.value
        await newScan.value
        try await database.writer.write { connection in connection.trace(nil) }
        XCTAssertFalse(model.isScanning)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.selection.count, 0, "Changed proposals must lose selection")
        XCTAssertTrue(model.snapshot.rows.last!.plan.destinationPath.hasSuffix("/A/New match.mp3"))
    }

    private func verifyVirtualizedRendering(_ model: OrganizePreviewModel) throws {
        model.setFilter(.all)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: OrganizePreviewTable(preview: model, density: .comfortable))
        window.contentView = host
        let start = ContinuousClock.now
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let table = try XCTUnwrap(descendants(host).compactMap { view in view as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 50001)
        let initial = start.duration(to: .now)
        let jumpStart = ContinuousClock.now
        table.scrollRowToVisible(50000)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let title = try XCTUnwrap(table.view(atColumn: 2, row: 50000, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(title.textField?.stringValue, "New match")
        let jump = jumpStart.duration(to: .now)
        var availableRows = 0
        table.enumerateAvailableRowViews { _, _ in availableRows += 1 }
        XCTAssertLessThan(availableRows, 100, "Only viewport rows may have views")
        XCTAssertLessThan(initial, .seconds(1))
        XCTAssertLessThan(jump, .milliseconds(250))
        print("ORGANIZE_PERF render=\(initial) distant_jump=\(jump) available_rows=\(availableRows)")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/crate-120-preview.png"))
        }
    }

    private func verifyReusableTableAndKeyboard() {
        struct ExampleRow: Identifiable { let id: Int; let name: String }
        let rows = [ExampleRow(id: 10, name: "First"), ExampleRow(id: 20, name: "Second")]
        var selected = Set<Int>()
        let configuration = VirtualizedPreviewTable(dataID: "examples", accessibilityLabel: "Example preview", rowCount: rows.count, row: { index in rows[index] },
                                                    columns: [PreviewTableColumn(identifier: "name", title: "Name", width: 200, text: { row in row.name })],
                                                    accessibilityName: { row in row.name }, isSelected: { identifier in selected.contains(identifier) },
                                                    setSelected: {
                                                        identifier, included in if included {
                                                            selected.insert(identifier)
                                                        } else {
                                                            selected.remove(identifier)
                                                        }
                                                    },
                                                    selectAll: { selected = [10, 20] }, enabled: true, density: .compact)
        let coordinator = configuration.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = scroll.documentView as! PreviewNSTableView
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        table.keyDown(with: key)
        XCTAssertEqual(selected, [20])
        let checkbox = table.view(atColumn: 0, row: 1, makeIfNecessary: true) as! NSButton
        XCTAssertEqual(checkbox.accessibilityLabel(), "Select Second")
        checkbox.performClick(nil)
        XCTAssertTrue(selected.isEmpty)
        table.selectAll(nil)
        XCTAssertEqual(selected, [10, 20])
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { child in descendants(child) }
    }
}

@MainActor
private final class MainActorPulse {
    var maximumGap = Duration.zero
    var samples = 0
    var fingerprintingSamples = 0
    let isFingerprinting: @Sendable () -> Bool

    init(isFingerprinting: @escaping @Sendable () -> Bool) {
        self.isFingerprinting = isFingerprinting
    }

    func run() async {
        while !Task.isCancelled {
            let start = ContinuousClock.now
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            maximumGap = max(maximumGap, start.duration(to: .now))
            samples += 1
            if isFingerprinting() {
                fingerprintingSamples += 1
            }
        }
    }
}
