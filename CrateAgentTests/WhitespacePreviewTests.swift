import AppKit
@testable import CrateAgent
import GRDB
import SwiftUI
import XCTest

final class WhitespacePreviewTests: XCTestCase {
    func testLeadingAndTrailingSpacesAreNamed() {
        XCTAssertEqual(WhitespacePreview(current: " Track", proposed: "Track").summary, "Remove leading spaces")
        XCTAssertEqual(WhitespacePreview(current: "Track ", proposed: "Track").summary, "Remove trailing spaces")
        XCTAssertEqual(WhitespacePreview(current: " Track ", proposed: "Track").summary, "Remove leading and trailing spaces")
    }

    func testMarkersExposeSpacesTabsAndLineBreaksWithoutChangingValues() {
        let current = " A\tB\r\nC\n"
        let proposed = "A B C"
        let preview = WhitespacePreview(current: current, proposed: proposed)
        XCTAssertEqual(preview.visibleCurrent, "·A⇥B↵C↵")
        XCTAssertEqual(preview.visibleProposed, "A·B·C")
        XCTAssertEqual(preview.current, current)
        XCTAssertEqual(preview.proposed, proposed)
    }

    func testMixedBoundaryWhitespaceUsesAccurateDescription() {
        XCTAssertEqual(WhitespacePreview(current: "\tTrack\n", proposed: "Track").summary, "Remove leading and trailing whitespace")
    }

    func testInternalWhitespaceChangesAreNamed() {
        XCTAssertEqual(WhitespacePreview(current: "A\t B", proposed: "A B").summary, "Normalize internal whitespace")
    }

    func testCombinedChangesAreNotReducedToOneCause() {
        XCTAssertEqual(WhitespacePreview(current: " A\t B ", proposed: "A B").summary, "Remove leading and trailing spaces; normalize internal whitespace")
    }

    func testUnchangedWhitespaceIsNotClaimedAsAFix() {
        let preview = WhitespacePreview(current: " A\tB ", proposed: " A\tB ")
        XCTAssertEqual(preview.summary, "No change")
        XCTAssertEqual(preview.visibleCurrent, preview.visibleProposed)
    }

    func testWhitespaceOnlyBecomesEmpty() {
        let preview = WhitespacePreview(current: " \t\n", proposed: "")
        XCTAssertEqual(preview.summary, "Clear whitespace-only value")
        XCTAssertEqual(preview.visibleProposed, "Empty")
    }

    func testEmptyUnchangedValueIsExplicit() {
        let preview = WhitespacePreview(current: "", proposed: "")
        XCTAssertEqual(preview.visibleCurrent, "Empty")
        XCTAssertEqual(preview.summary, "No change")
    }

    func testTextEditsAreNotMisrepresentedAsWhitespaceNormalization() {
        XCTAssertEqual(WhitespacePreview(current: " Old ", proposed: "New").summary, "Change text and whitespace")
        XCTAssertEqual(WhitespacePreview(current: "Old", proposed: "New").summary, "Change text")
    }

    func testAddedWhitespaceIsNotDescribedAsRemoval() {
        XCTAssertEqual(WhitespacePreview(current: "Track", proposed: " Track").summary, "Change leading whitespace")
    }

    func testNonbreakingSpaceRemainsVisible() {
        XCTAssertEqual(WhitespacePreview(current: "A\u{00a0}B", proposed: "A B").visibleCurrent, "A⍽B")
    }

    func testPreviewUsesActualCleanupChangesAndKeepsFieldAndTrackCountsDistinct() {
        let file = HygieneFileRow(id: 1, path: "/fixture/track.mp3", artist: " Artist", title: "Title\t")
        let issues = LibraryHygiene.findWhitespaceIssues(in: [file])
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(Set(issues.map(\.fileId)).count, 1)
        XCTAssertEqual(issues.map { WhitespacePreview(current: $0.oldValue, proposed: $0.newValue).summary }, [
            "Remove leading spaces", "Remove trailing whitespace",
        ])
        XCTAssertEqual(file.artist, " Artist")
        XCTAssertEqual(file.title, "Title\t")
    }

    func testDensityControlsShareStorageAndSurviveRecreation() throws {
        let suiteName = "WhitespacePreviewTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let toolbar = AppStorage(wrappedValue: AppDensity.comfortable, AppPresentation.densityPreference, store: preferences)
        XCTAssertEqual(toolbar.wrappedValue, .comfortable)
        toolbar.wrappedValue = .compact
        XCTAssertEqual(preferences.string(forKey: AppPresentation.densityPreference), AppDensity.compact.rawValue)
        let settings = AppStorage(wrappedValue: AppDensity.comfortable, AppPresentation.densityPreference, store: preferences)
        XCTAssertEqual(settings.wrappedValue, .compact)
        let recreated = AppStorage(wrappedValue: AppDensity.comfortable, AppPresentation.densityPreference, store: preferences)
        XCTAssertEqual(recreated.wrappedValue, .compact)
        settings.wrappedValue = .comfortable
        XCTAssertEqual(preferences.string(forKey: AppPresentation.densityPreference), AppDensity.comfortable.rawValue)
        let reopenedToolbar = AppStorage(wrappedValue: AppDensity.compact, AppPresentation.densityPreference, store: preferences)
        XCTAssertEqual(reopenedToolbar.wrappedValue, .comfortable)
    }

    @MainActor
    func testMissingFillNormalizesValuesWithoutChangingOtherFields() async throws {
        let cases = [
            (input: " Artist ", saved: "Artist"),
            (input: "\t\nArtist\r\n", saved: "Artist"),
            (input: " \t \n", saved: ""),
            (input: " DJ \t Mix ", saved: "DJ \t Mix"),
        ]
        for fixture in cases {
            let database = try LibraryDatabase.openInMemory()
            let engine = try OperationEngine(
                database: database,
                seratoWatchdog: SeratoWatchdog(runningBundleIdentifiersProvider: { [] }),
                seratoLocator: makeEmptySeratoLibrary(),
                fileTagWriter: { _, _ in }
            )
            try await engine.apply(.indexNewFile(IndexNewFilePayload(
                path: "/fixture/missing-artist.mp3", volumeUuid: "fixture", inode: 1, fileSize: 1, mtime: 1,
                metadata: SeratoMetadata(title: "Keep this title")
            )))
            try await markProcessingFixturesAvailable(in: database)
            let files = try await database.writer.read { database in try FileRecord.fetchAll(database) }
            let runner = LibraryHygieneRunner(operationEngine: engine)
            _ = try await runner.applyMissingFieldFill(
                field: .artist, value: fixture.input, fileIds: files.compactMap(\.id), files: files
            )
            let savedFile = try await database.writer.read { database in try FileRecord.fetchOne(database) }
            let saved = try XCTUnwrap(savedFile)
            XCTAssertEqual(saved.artist ?? "", fixture.saved)
            XCTAssertEqual(saved.title, "Keep this title")
            let writes = try await database.writer.read { database in
                try EventRecord.filter(Column("event_type") == EventType.fileTagsWritten.rawValue).fetchAll(database)
            }
            XCTAssertEqual(writes.count, fixture.saved.isEmpty ? 0 : 1)
            if let write = writes.first {
                let payload = try JSONDecoder().decode(WriteFileTagsPayload.self, from: Data(write.payloadJson.utf8))
                XCTAssertEqual(payload.metadata.artist, fixture.saved)
            }
        }
    }

    @MainActor
    func testMountedDensityControlsObserveEachOthersChanges() async throws {
        let suiteName = "MountedDensityTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let mounted = expectation(description: "Both density controls mounted")
        mounted.expectedFulfillmentCount = 2
        let settingsChanged = expectation(description: "Settings observes toolbar compact choice")
        let toolbarChanged = expectation(description: "Toolbar observes settings comfortable choice")
        var toolbarBinding: Binding<AppDensity>?
        var settingsBinding: Binding<AppDensity>?
        let host = NSHostingView(rootView: HStack {
            DensityProbeView(onReady: { binding in
                toolbarBinding = binding
                mounted.fulfill()
            }, onChange: { value in
                if value == .comfortable {
                    toolbarChanged.fulfill()
                }
            })
            DensityProbeView(onReady: { binding in
                settingsBinding = binding
                mounted.fulfill()
            }, onChange: { value in
                if value == .compact {
                    settingsChanged.fulfill()
                }
            })
        }.defaultAppStorage(preferences))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [mounted], timeout: 2)
        try XCTUnwrap(toolbarBinding).wrappedValue = .compact
        await fulfillment(of: [settingsChanged], timeout: 2)
        try XCTUnwrap(settingsBinding).wrappedValue = .comfortable
        await fulfillment(of: [toolbarChanged], timeout: 2)
        withExtendedLifetime(host) {}
    }
}

private struct DensityProbeView: View {
    @AppStorage(AppPresentation.densityPreference) private var density: AppDensity = .comfortable
    let onReady: (Binding<AppDensity>) -> Void
    let onChange: (AppDensity) -> Void

    var body: some View {
        Text(density.title)
            .onAppear { onReady($density) }
            .onChange(of: density) { _, value in onChange(value) }
    }
}
