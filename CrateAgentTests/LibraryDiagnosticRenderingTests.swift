import AppKit
@testable import CrateAgent
import SwiftUI
import XCTest

@MainActor
final class LibraryDiagnosticRenderingTests: XCTestCase {
    func testSyntheticDiagnosticComponentsAcrossAppearanceAndDensity() async throws {
        let rows = [
            BrowserRow(id: 1, path: "/Synthetic/M/Mira - Afterhours.mp3", artist: "Mira", title: "Afterhours", libraryMembership: .active, fileAvailability: .available),
            BrowserRow(id: 2, path: "/Synthetic/O/Orbit - Lunar.flac", artist: "Orbit", title: "Lunar", libraryMembership: .active, fileAvailability: .offline),
            BrowserRow(id: 3, path: "/Synthetic/A/Aster - Dusk.mp3", artist: "Aster", title: "Dusk", libraryMembership: .active, fileAvailability: .inaccessible),
            BrowserRow(id: 4, path: "/Synthetic/S/Sol - Dawn.mp3", artist: "Sol", title: "Dawn", libraryMembership: .pendingImport, fileAvailability: .available),
            BrowserRow(id: 5, path: "/Synthetic/E/Echo - Night.mp3", artist: "Echo", title: "Night", libraryMembership: .legacyUnverified, fileAvailability: .unknown),
            BrowserRow(id: 6, path: "/Synthetic/V/Vela-009-master.wav", artist: "Vela", title: "Signal", libraryMembership: .retired, fileAvailability: .available),
            BrowserRow(id: 7, path: "/Synthetic/T/Tala - Blue.mp3", artist: "Tala", title: "Blue", libraryMembership: .retired, fileAvailability: .trashed),
            BrowserRow(id: 8, path: "/Synthetic/N/Nova-demo-v2.mp3", artist: "Nova", libraryMembership: .retired, fileAvailability: .missing),
        ]
        let payload = SetFileLibraryStatePayload(fileId: 6, expectedRevision: 0,
                                                 state: FileLibraryState(membership: .retired, availability: .available, libraryID: "synthetic", retiredAt: 1))
        let event = try EventRecord(eventId: 1, batchId: "fixture", timestamp: 1_750_000_000_000, fileId: 6,
                                    eventType: .fileLibraryStateChanged, payloadJson: String(decoding: JSONEncoder().encode(payload), as: UTF8.self), inversePayloadJson: "{}")
        for density in AppDensity.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = "\(density.rawValue)-\(scheme == .dark ? "dark" : "light")"
                for filter in LibraryStatusFilter.allCases {
                    let filtered = rows.filter { row in
                        switch filter {
                        case .active: row.libraryMembership != .retired
                        case .removedFromSerato: row.libraryMembership == .retired
                        case .missing: row.libraryMembership == .active && row.fileAvailability != .available
                        }
                    }
                    try await render(VStack(spacing: 0) {
                        PageHeading("Library", subtitle: "Synthetic diagnostic fixture").padding()
                        LibraryStatusFilterBar(selection: .constant(filter))
                        LibraryBrowserTable(rows: filtered, selectedFileIds: .constant([]), sortOrder: .constant([]), showsFilenames: filter != .active)
                    }.appPresentation(), name: "library-\(filter.rawValue)-\(suffix)", density: density, scheme: scheme, width: 1500, height: 530)
                }
                try await render(FileHistoryContent(file: rows[5], entries: [FileHistoryEntry(event: event)]),
                                 name: "history-\(suffix)", density: density, scheme: scheme, width: 760, height: 430)
                try await render(VStack(alignment: .leading, spacing: 0) {
                    PageHeading("Choose tracks to scan", subtitle: "Synthetic diagnostic fixture").padding()
                    ForEach(rows) { file in
                        AutoTagSelectionRow(fileID: file.id, path: file.path, artist: file.artist, title: file.title,
                                            libraryMembership: file.libraryMembership, fileAvailability: file.fileAvailability,
                                            isSelected: file.canProcess, onToggle: { XCTFail("Rendering must not select or process files") })
                    }
                    ActionErrorMessage(message: FileProcessingEligibilityError.unavailable(fileId: 2, membership: .active, availability: .offline, path: rows[1].path).localizedDescription)
                }.padding().appPresentation(), name: "autotag-\(suffix)", density: density, scheme: scheme, width: 900, height: 720)
            }
        }
    }

    private func render(_ content: some View, name: String, density: AppDensity, scheme: ColorScheme, width: CGFloat, height: CGFloat) async throws {
        let suite = "DiagnosticRender.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(density.rawValue, forKey: AppPresentation.densityPreference)
        let host = NSHostingView(rootView: content.defaultAppStorage(preferences).environment(\.colorScheme, scheme)
            .frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if name.hasPrefix("library-") || name.hasPrefix("history-") {
            let tables = descendants(of: host).compactMap { $0 as? NSTableView }
            XCTAssertTrue(tables.contains { $0.numberOfRows > 0 }, "Native table must have rendered fixture rows: \(name)")
            if name.hasPrefix("library-removedFromSerato-") || name.hasPrefix("library-missing-") {
                let table = try XCTUnwrap(tables.first { $0.numberOfRows > 0 })
                XCTAssertGreaterThanOrEqual(table.rect(ofRow: 0).height, density.minimumRowHeight + 12,
                                            "Diagnostic rows must accommodate a visible filename: \(name)")
            }
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crate-agent-task8-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { child in [child] + descendants(of: child) }
    }
}
