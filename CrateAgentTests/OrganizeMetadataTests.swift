import AppKit
@testable import CrateAgent
import GRDB
import SwiftUI
import XCTest

@MainActor
final class OrganizeMetadataTests: XCTestCase {
    func testPlannerExcludesBlankRequiredMetadataAndHonorsTemplateFields() {
        let root = URL(fileURLWithPath: "/Music")
        let template = "$artist - $title.$ext"
        let blanks: [String?] = [nil, "", " \t\n", "\u{00A0}"]
        for blank in blanks {
            let files = [
                HygieneFileRow(id: 1, path: "/Downloads/artist.mp3", artist: blank, title: "Title"),
                HygieneFileRow(id: 2, path: "/Downloads/title.mp3", artist: "Artist", title: blank),
                HygieneFileRow(id: 3, path: "/Downloads/both.mp3", artist: blank, title: blank),
                HygieneFileRow(id: 4, path: "/Downloads/valid.mp3", artist: "Artist", title: "Title"),
            ]
            let plans = LibraryOrganizer.findMoves(in: files, musicFolder: root, template: template)
            XCTAssertEqual(plans.map(\.id), [4])
            XCTAssertEqual(plans.last?.destinationPath, "/Music/A/Artist - Title.mp3")
        }
        let file = HygieneFileRow(id: 1, path: "/Downloads/valid.mp3", artist: "Artist", title: "Title")
        for requiredTemplate in ["$artist - $title ($album).$ext", "$genre.$ext", "$bpm.$ext", "$key.$ext", "$comment.$ext", "$label.$ext", "$length.$ext"] {
            XCTAssertTrue(LibraryOrganizer.findMoves(in: [file], musicFolder: root, template: requiredTemplate).isEmpty, requiredTemplate)
        }
        XCTAssertEqual(LibraryOrganizer.findMoves(in: [file], musicFolder: root, template: "$$album - $title.$ext").first?.destinationPath, "/Music/A/$album - Title.mp3")
        let noTitle = HygieneFileRow(id: 2, path: "/Downloads/no-title.mp3", artist: "Artist")
        XCTAssertTrue(LibraryOrganizer.findMoves(in: [noTitle], musicFolder: root, template: "$artist.$ext").isEmpty)
    }

    func testBlockedSelectionAndApplyRevalidation() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        var file = try await fixture.add("song.mp3")
        file.artist = "Artist"
        file.title = "Title"
        file.album = "Album"
        let validFile = file
        try await fixture.database.writer.write { connection in try validFile.update(connection) }
        try fixture.save(paths: [file.path])
        let root = fixture.directory.appendingPathComponent("Music")
        let plans = LibraryOrganizer.findMoves(in: [file], musicFolder: root, template: "$artist - $title ($album).$ext")
        XCTAssertEqual(plans.count, 1)
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET album = '  ' WHERE id = ?", arguments: [validFile.id])
        }
        let outcome = try await LibraryOrganizer(operationEngine: fixture.engine).organize(plans)
        XCTAssertEqual(outcome.movedCount, 0)
        XCTAssertEqual(outcome.failureCount, 1)
        XCTAssertTrue(outcome.errors.first?.contains("Album") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let current = try await fixture.row(file)
        let events = try await fixture.events()
        XCTAssertEqual(current.path, file.path)
        XCTAssertEqual(events, 0)

        let missingArtist = try await fixture.add("missing-artist.mp3")
        let missingTitle = try await fixture.add("missing-title.mp3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missingBoth = try await fixture.add("Music/missing-both.mp3")
        let ready = try await fixture.add("ready.mp3")
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET title = 'Title', album = 'Album' WHERE id = ?", arguments: [missingArtist.id])
            try connection.execute(sql: "UPDATE files SET artist = 'Artist', album = 'Album' WHERE id = ?", arguments: [missingTitle.id])
            try connection.execute(sql: "UPDATE files SET album = 'Album' WHERE id = ?", arguments: [missingBoth.id])
            try connection.execute(sql: "UPDATE files SET artist = 'Artist', title = 'Ready', album = 'Album' WHERE id = ?", arguments: [ready.id])
        }
        let template = "$artist - $title ($album).$ext"
        let model = OrganizePreviewModel()
        await model.rescan(database: fixture.database, musicFolder: root, template: template)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.visibleCount, 4)
        XCTAssertEqual(model.visibleBlockedCount, 3)
        XCTAssertEqual(model.snapshot.blockedCount, 4)
        XCTAssertEqual(model.selection.count, 0)
        let requiredByID = try [XCTUnwrap(file.id): [SeratoMetadataField.album],
                                XCTUnwrap(missingArtist.id): [.artist],
                                XCTUnwrap(missingTitle.id): [.title],
                                XCTUnwrap(missingBoth.id): [.artist, .title]]
        for row in model.snapshot.rows where row.id != ready.id {
            guard case let .needsMetadata(fields) = row.disposition else {
                XCTFail("Blank tags must produce a blocked row instead of a move proposal")
                continue
            }
            XCTAssertEqual(fields, requiredByID[row.id])
            XCTAssertNil(row.plan)
            model.setSelected(true, identifier: row.id)
        }
        XCTAssertEqual(model.selection.count, 0)
        model.setFilter(.all)
        XCTAssertEqual(model.visibleCount, 5)
        XCTAssertEqual(model.scope.count, 1)
        try verifyBlockedRendering(model, eligibleID: XCTUnwrap(ready.id))
        model.selectScope(true)
        XCTAssertEqual(model.selection.coverage(in: model.scope), .all)
        let batch = await model.beginApply()
        XCTAssertEqual(batch.map(\.id), [ready.id])
        model.finishApply()
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET artist = NULL WHERE id = ?", arguments: [ready.id])
        }
        await model.rescan(database: fixture.database, musicFolder: root, template: template)
        XCTAssertEqual(model.selection.count, 0, "Newly blocked selections are removed; repaired rows are not automatically selected")
        XCTAssertNotNil(model.notice)
        XCTAssertTrue(model.scope.isEmpty)
        model.selectScope(true)
        let blockedBatch = await model.beginApply()
        XCTAssertTrue(blockedBatch.isEmpty)
        XCTAssertFalse(model.isApplying)
        try await fixture.database.writer.write { connection in
            try connection.execute(sql: "UPDATE files SET album = 'Album' WHERE id = ?", arguments: [validFile.id])
        }
        await model.rescan(database: fixture.database, musicFolder: root, template: template)
        XCTAssertEqual(model.selection.count, 0)
        XCTAssertEqual(model.scope.count, 1)
        model.selectScope(true)
        let repairedBatch = await model.beginApply()
        XCTAssertEqual(repairedBatch.map(\.id), [file.id])
        let repaired = try await LibraryOrganizer(operationEngine: fixture.engine).organize(repairedBatch, batchId: "repaired")
        XCTAssertEqual(repaired.movedCount, 1)
        XCTAssertEqual(repaired.failureCount, 0)
        _ = try await fixture.engine.undoBatch("repaired")
        let restored = try await fixture.row(file)
        XCTAssertEqual(restored.path, file.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    private func verifyBlockedRendering(_ model: OrganizePreviewModel, eligibleID: Int64) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: OrganizePreviewTable(preview: model, density: .comfortable))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { child in descendants(child) }
        }
        let table = try XCTUnwrap(descendants(host).compactMap { view in view as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 5)
        for index in model.snapshot.rows.indices {
            let checkbox = try XCTUnwrap(table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSButton)
            if model.snapshot.rows[index].id == eligibleID {
                XCTAssertFalse(checkbox.isHidden)
                XCTAssertTrue(checkbox.isEnabled)
            } else {
                XCTAssertTrue(checkbox.isHidden)
                XCTAssertFalse(checkbox.isEnabled)
                XCTAssertFalse(checkbox.isAccessibilityElement())
                checkbox.performClick(nil)
            }
        }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        table.keyDown(with: key)
        XCTAssertEqual(model.selection.count, 0)
        table.selectAll(nil)
        XCTAssertEqual(model.selection.count, 1)
        XCTAssertTrue(model.isSelected(eligibleID))
        model.clearSelection()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/crate-131-preview.png"))
    }
}
