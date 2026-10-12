import AppKit
@testable import CrateAgent
import SwiftUI
import XCTest

@MainActor
final class SeratoConflictPresentationTests: XCTestCase {
    func testReviewShowsRawEvidenceRoutesExplicitActionsAndRetainsStaleDetails() async throws {
        let gate = LibrarySyncReadiness()
        let fixture = try SeratoRemovalFixture(readiness: gate)
        defer { fixture.cleanup() }
        let file = try await fixture.add("Café.mp3")
        let paths = [file.path.precomposedStringWithCanonicalMapping, file.path.decomposedStringWithCanonicalMapping]
        XCTAssertNotEqual(Data(paths[0].utf8), Data(paths[1].utf8))
        func textRecord(_ tag: String, _ value: String) -> Data {
            SeratoTestEncoding.record(tag, value.data(using: .utf16BigEndian)!)
        }
        var library = textRecord("vrsn", "2.0/Serato Scratch LIVE Database")
        for (index, path) in paths.enumerated() {
            library += SeratoTestEncoding.record("otrk", textRecord("pfil", path) + textRecord("tart", index == 0 ? "First artist" : "Second artist"))
        }
        try library.write(to: fixture.locator.databaseV2Url)
        let session = SeratoLibrarySyncSession(reader: fixture.reader, reconciler: fixture.reconciler,
                                               scanner: LibraryScanner(operationEngine: fixture.engine, database: fixture.database, seratoLocator: fixture.locator),
                                               operationEngine: fixture.engine, watchdog: fixture.watchdog, readiness: gate,
                                               conflictAnalyzer: SeratoConflictAnalyzer(inspect: { path in
                                                   if path.unicodeScalars.contains(where: { scalar in scalar.value == 0x301 }) {
                                                       throw CocoaError(.fileReadNoPermission)
                                                   }
                                                   return try SeratoConflictAnalyzer.inspectPath(path)
                                               }))
        var copied = ""
        var revealed: [String] = []
        var opened = 0
        var retries = 0
        let model = SeratoConflictReviewModel(session: session, copyDetails: { text in copied = text }, revealFile: { path in revealed.append(path) },
                                              openSerato: { opened += 1; throw CocoaError(.fileNoSuchFile) }, retrySync: { retries += 1 })
        try await session.synchronize()
        XCTAssertEqual(model.conflicts.count, 1)
        XCTAssertEqual(opened, 0)
        model.copyDetails()
        XCTAssertTrue(copied.contains("First artist"))
        XCTAssertTrue(copied.contains("Second artist"))
        XCTAssertTrue(copied.contains("U+00E9"), copied)
        XCTAssertTrue(copied.contains("U+0301"))
        XCTAssertTrue(copied.contains("UTF-8"))
        XCTAssertTrue(copied.contains("Inspection failed"))
        XCTAssertTrue(copied.contains("one physical file"))
        let occurrence = try XCTUnwrap(model.selectedConflict?.occurrences.first)
        await model.reveal(occurrence)
        XCTAssertEqual(revealed, [file.path])
        let originalURL = URL(fileURLWithPath: file.path)
        let heldURL = fixture.directory.appendingPathComponent("held-original.mp3")
        try FileManager.default.moveItem(at: originalURL, to: heldURL)
        try Data([5, 6, 7, 8]).write(to: originalURL)
        await model.reveal(occurrence)
        XCTAssertEqual(revealed.count, 1, "Finder must not reveal a replacement that reuses the saved path")
        XCTAssertNotNil(model.actionError)
        try FileManager.default.removeItem(at: originalURL)
        try FileManager.default.moveItem(at: heldURL, to: originalURL)

        await model.openSerato()
        XCTAssertEqual(opened, 1)
        XCTAssertNotNil(model.actionError)
        session.suspend()
        XCTAssertTrue(model.isStale)
        XCTAssertEqual(model.conflicts.count, 1)
        try await render(model)
        model.retry()
        XCTAssertEqual(retries, 1)
        try fixture.save(paths: [file.path])
        try await session.synchronize()
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertNil(model.selectedConflict)
        XCTAssertFalse(model.isStale)
    }

    private func render(_ model: SeratoConflictReviewModel) async throws {
        let output = URL(fileURLWithPath: "/tmp/crate-130-conflict-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suiteName = "SeratoConflictPresentationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        for density in AppDensity.allCases {
            preferences.set(density.rawValue, forKey: AppPresentation.densityPreference)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.appearance = NSAppearance(named: appearance)
                let navigationStart = ContinuousClock.now
                let host = NSHostingView(rootView: SeratoConflictReviewView(model: model).defaultAppStorage(preferences))
                window.contentView = host
                window.orderBack(nil)
                try await Task.sleep(for: .milliseconds(10))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let navigationDuration = navigationStart.duration(to: .now)
                XCTAssertLessThan(navigationDuration, .milliseconds(500))
                print("CONFLICT_NAV \(name) \(density.rawValue) \(navigationDuration)")
                XCTAssertGreaterThan(host.fittingSize.width, 0)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try bytes.write(to: output.appendingPathComponent("\(name)-\(density.rawValue).png"))
                let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.png")
                attachment.name = "Conflict review \(name) \(density.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
