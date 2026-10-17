import AppKit
@testable import CrateAgent
import GRDB
import SwiftUI
import XCTest

final class ListControlsTests: XCTestCase {
    func testMissingSelectionSurvivesFilteringButNeverExpandsOnRescan() {
        let files = (1 ... 2524).map { identifier in
            HygieneFileRow(id: Int64(identifier), path: "/Music/\(identifier).mp3", title: identifier == 1 ? "Björk" : "Track \(identifier)")
        }
        let entries = LibraryHygiene.missingFieldEntries(forField: .artist, in: files)
        var results = ListResultSelection<LibraryHygiene.MissingFieldEntry>()
        results.replace(entries, context: "artist", searchText: { entry in files[Int(entry.fileId) - 1].title ?? "" })
        XCTAssertTrue(results.selectedRows.isEmpty)
        results.selectVisible(true)
        XCTAssertEqual(results.selectedRows.count, 2524)
        results.setSelected(false, id: entries[1].id)
        XCTAssertEqual(results.coverage, .partial)
        results.setQuery("BJÖRK")
        XCTAssertEqual(results.visibleRows.map(\.fileId), [1])
        XCTAssertEqual(results.hiddenSelectionCount, 2522)
        results.selectVisible(false)
        XCTAssertEqual(results.selectedRows.count, 2522)
        results.setQuery("")
        results.replace(entries.reversed(), context: "artist", searchText: { entry in files[Int(entry.fileId) - 1].title ?? "" })
        XCTAssertFalse(results.selectedIDs.contains(entries[0].id))
        XCTAssertFalse(results.selectedIDs.contains(entries[1].id))
        let newFile = HygieneFileRow(id: 2525, path: "/Music/new.mp3")
        results.replace(LibraryHygiene.missingFieldEntries(forField: .artist, in: files + [newFile]), context: "artist", searchText: { $0.path })
        XCTAssertEqual(results.selectedRows.count, 2522)
        results.setQuery("new.mp3")
        XCTAssertEqual(results.coverage, .none)
        results.clearSelection()
        XCTAssertTrue(results.selectedRows.isEmpty)
        results.selectVisible(true)
        results.replace(LibraryHygiene.missingFieldEntries(forField: .album, in: files), context: "album", searchText: { $0.path })
        XCTAssertTrue(results.selectedRows.isEmpty)
    }

    func testRepairBlockedRowsRemainVisibleButCannotJoinCleanupSelection() {
        let files = [HygieneFileRow(id: 1, path: "/Music/conflict.mp3"), HygieneFileRow(id: 2, path: "/Music/independent.mp3")]
        let entries = LibraryHygiene.missingFieldEntries(forField: .artist, in: files)
        var results = ListResultSelection<LibraryHygiene.MissingFieldEntry>()
        results.replace(entries, context: "artist", searchText: { entry in entry.path })
        results.selectVisible(true)
        results.setBlockedIDs([entries[0].id])
        XCTAssertEqual(results.visibleRows.count, 2)
        XCTAssertEqual(results.selectedRows.map(\.fileId), [2])
        results.setSelected(true, id: entries[0].id)
        results.selectVisible(true)
        XCTAssertEqual(results.selectedRows.map(\.fileId), [2])
        XCTAssertEqual(results.coverage, .all)
        results.setQuery("conflict")
        XCTAssertEqual(results.selectableVisibleCount, 0)
        XCTAssertEqual(results.coverage, .none)
        results.setBlockedIDs([])
        XCTAssertEqual(results.selectedRows.map(\.fileId), [2], "Repair must not silently select a previously blocked proposal")
        results.selectVisible(true)
        XCTAssertEqual(Set(results.selectedRows.map(\.fileId)), [1, 2])
    }

    func testChangedReplacementIsDeselectedAndReported() {
        let files = [HygieneFileRow(id: 1, path: "/Music/song.mp3", artist: "Old Artist")]
        var results = ListResultSelection<LibraryHygiene.FindAndReplaceMatch>()
        let original = LibraryHygiene.findAndReplaceMatches(in: files, query: .init(find: "Old", replace: "New", fields: [.artist], caseSensitive: false))
        results.replace(original, context: "replace", searchText: { $0.path })
        results.selectVisible(true)
        let changed = LibraryHygiene.findAndReplaceMatches(in: files, query: .init(find: "Old", replace: "Different", fields: [.artist], caseSensitive: false))
        results.replace(changed, context: "replace", searchText: { $0.path })
        XCTAssertTrue(results.selectedRows.isEmpty)
        XCTAssertEqual(results.droppedSelectionCount, 1)
    }

    func testMissingFillProposalChangesRemovePriorTargets() {
        let files = [HygieneFileRow(id: 1, path: "/Music/song.mp3")]
        let entries = LibraryHygiene.missingFieldEntries(forField: .artist, in: files)
        var results = ListResultSelection<LibraryHygiene.MissingFieldEntry>()
        results.replaceHygiene(entries, files: files, context: "artist", proposalRevision: "First artist", fileID: { $0.fileId })
        results.selectVisible(true)
        results.replaceHygiene(entries, files: files, context: "artist", proposalRevision: "Different artist", fileID: { $0.fileId })
        XCTAssertTrue(results.selectedRows.isEmpty)
        XCTAssertEqual(results.droppedSelectionCount, 1)
    }

    func testCleanupSortUsesRefreshedMetadataWithoutTransferringSelection() {
        var files = [HygieneFileRow(id: 1, path: "/Music/one.mp3", title: "Zed"), HygieneFileRow(id: 2, path: "/Music/two.mp3", title: "Alpha")]
        var results = ListResultSelection<LibraryHygiene.MissingFieldEntry>()
        let entries = LibraryHygiene.missingFieldEntries(forField: .artist, in: files)
        results.replaceHygiene(entries, files: files, context: "artist", fileID: { entry in entry.fileId })
        results.setSelected(true, id: entries[0].id)
        results.sort(column: "title", ascending: true) { first, second in first.fileId > second.fileId }
        XCTAssertEqual(results.visibleRows.map(\.fileId), [2, 1])
        files[0].title = "Aardvark"
        results.replaceHygiene(entries, files: files, context: "artist", fileID: { entry in entry.fileId })
        XCTAssertEqual(results.visibleRows.map(\.fileId), [1, 2])
        XCTAssertEqual(results.selectedRows.map(\.fileId), [1])
    }

    func testLibraryAndAutoTagSearchShareCaseAndDiacriticFoldingAndLiteralMatching() throws {
        let database = try LibraryDatabase.openInMemory()
        try database.writer.write { connection in
            var file = FileRecord(id: 1, path: "/Music/50%.mp3", volumeUuid: "fixture", inode: 1, fileSize: 1, mtime: 0, artist: "Bjo\u{308}rk", title: "Song", album: "DÉBUT")
            try file.insert(connection)
            var other = FileRecord(id: 2, path: "/Music/500.mp3", volumeUuid: "fixture", inode: 2, fileSize: 1, mtime: 0, artist: "Other", title: "Song")
            try other.insert(connection)
        }
        try database.writer.read { connection in
            for query in ["BJÖRK", "bjork", "début", "DEBUT", "50%"] {
                XCTAssertEqual(try LibraryStatusBrowse.fetch(connection, search: query).rows.map(\.id), [1])
                XCTAssertEqual(try AutoTagFileSearch.search(query: query, in: connection).matches.map(\.id), [1])
            }
        }
    }

    @MainActor
    func testNativeCleanupKeyboardTargetsSnapshotBeyondViewport() throws {
        let files = (1 ... 2524).map { identifier in HygieneFileRow(id: Int64(identifier), path: "/Music/\(identifier).mp3", title: "Track \(identifier)") }
        var results = ListResultSelection<LibraryHygiene.MissingFieldEntry>()
        results.replaceHygiene(LibraryHygiene.missingFieldEntries(forField: .artist, in: files), files: files, context: "artist", fileID: { $0.fileId })
        let binding = Binding(get: { results }, set: { results = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: HygieneSelectionTable(results: binding, identities: TrackDisplayIdentity.index(files), enabled: true,
                                                                 path: { $0.path }, field: { $0.field.displayName }, oldValue: { _ in "Not set" }, newValue: { _ in "Artist" }))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 2524)
        XCTAssertLessThan(table.rows(in: table.visibleRect).length, 30)
        table.selectAll(nil)
        XCTAssertEqual(results.selectedRows.count, 2524)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        table.keyDown(with: key)
        XCTAssertEqual(results.selectedRows.count, 2523)
        let checkbox = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSButton)
        XCTAssertTrue(checkbox.isAccessibilityElement())
        XCTAssertTrue(checkbox.accessibilityLabel()?.contains("Artist") == true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/crate-146-cleanup.png"))
    }

    @MainActor
    func testFilteredMissingBatchWritesOnlyExplicitTargetsIncludingHiddenSelection() async throws {
        let database = try LibraryDatabase.openInMemory()
        let engine = OperationEngine(database: database, seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }),
                                     seratoLocator: SeratoLibraryLocator(seratoDirectory: URL(fileURLWithPath: "/dev/null")), fileTagWriter: { _, _ in })
        try await database.writer.write { connection in
            for identifier in 1 ... 3 {
                var file = FileRecord(id: Int64(identifier), path: "/fixture/\(identifier).mp3", volumeUuid: "fixture", inode: Int64(identifier), fileSize: 1, mtime: 1, title: "Keep \(identifier)")
                try file.insert(connection)
            }
        }
        try await markProcessingFixturesAvailable(in: database)
        let files = try await database.writer.read { connection in try HygieneFileRow.fetchAll(connection, sql: HygieneFileRow.hygieneFetchSQL) }
        var results = ListResultSelection<LibraryHygiene.MissingFieldEntry>()
        results.replaceHygiene(LibraryHygiene.missingFieldEntries(forField: .artist, in: files), files: files, context: "artist", fileID: { $0.fileId })
        results.setQuery("1.mp3")
        results.selectVisible(true)
        results.setQuery("3.mp3")
        results.selectVisible(true)
        XCTAssertEqual(results.hiddenSelectionCount, 1)
        _ = try await LibraryHygieneRunner(operationEngine: engine).applyMissingFieldFill(field: .artist, value: "Chosen", fileIds: results.selectedRows.map(\.fileId), files: files)
        let saved = try await database.writer.read { connection in try FileRecord.order(Column("id")).fetchAll(connection) }
        XCTAssertEqual(saved.map { $0.artist ?? "" }, ["Chosen", "", "Chosen"])
        XCTAssertEqual(saved.map { $0.title ?? "" }, ["Keep 1", "Keep 2", "Keep 3"])
    }
}
