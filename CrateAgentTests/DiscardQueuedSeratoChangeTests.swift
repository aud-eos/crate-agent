@testable import CrateAgent
import Foundation
import GRDB
import XCTest

/// Discarding a queued Serato change that cannot apply (#163). Each edit is a
/// metadata edit: the row, Serato's `database V2`, and the audio tags.
@MainActor
final class DiscardQueuedSeratoChangeTests: XCTestCase {
    func testDiscardingAFailedEditRevertsItInOneUndoableBatch() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await editableFile(fixture)
        try await edit(file, to: "Edited", batchID: "edit", fixture: fixture, engine: makeEngine(fixture, tagWriter: Self.readOnlyFile))
        let tagWrites = CallCounter()
        let engine = makeEngine(fixture) { path, update in
            tagWrites.increment()
            try writeAudioTags(filePath: path, update: update)
        }

        let discardBatch = try await engine.discardQueuedChange(batchID: "edit", fileID: XCTUnwrap(file.id))

        let reverted = try await fixture.row(file)
        XCTAssertEqual(reverted.title, "Original")
        XCTAssertEqual(try savedTitle(fixture, file), "Original", "The edit's landed V2 write is written back")
        XCTAssertEqual(tagWrites.count, 0, "The tag write that never ran is dropped, not written back")
        let pending = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(pending, 0)
        let batches = try await EventHistoryQuery.loadRecentBatches(database: fixture.database)
        let discarded = try XCTUnwrap(batches.first { batch in batch.batchId == discardBatch })
        XCTAssertTrue(discarded.isDiscardBatch)
        XCTAssertTrue(discarded.canUndo)
        XCTAssertFalse(batches.contains { batch in !batch.stuckChanges.isEmpty }, "No change is left stuck")

        _ = try await engine.undoBatch(discardBatch)

        let redone = try await fixture.row(file)
        XCTAssertEqual(redone.title, "Edited")
        XCTAssertEqual(try savedTitle(fixture, file), "Edited")
        XCTAssertEqual(try readAudioTags(filePath: file.path).title, "Edited", "Undo queues the discarded tag write again")
    }

    func testDiscardingAChangeThatMayHaveLandedWritesTheOldValueBack() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await editableFile(fixture)
        try await edit(file, to: "Edited", batchID: "edit", fixture: fixture,
                       engine: makeEngine(fixture, metadataWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }))
        // The V2 rewrite replaced the file before a later attempt's process stopped.
        try setSavedTitle(fixture, file, "Edited")
        try await fixture.database.writer.write { database in try database.execute(sql: "UPDATE serato_write_queue SET may_have_landed = 1") }
        let engine = makeEngine(fixture)

        let preview = try await engine.discardPreview(batchID: "edit", fileID: XCTUnwrap(file.id))
        XCTAssertTrue(preview.writesBackOldValues)
        XCTAssertEqual(preview.fieldChanges, [DiscardedFieldChange(field: "Title", discarded: "Edited", restored: "Original")])
        try await engine.discardQueuedChange(batchID: "edit", fileID: XCTUnwrap(file.id))

        XCTAssertEqual(try savedTitle(fixture, file), "Original")
        XCTAssertEqual(try readAudioTags(filePath: file.path).title, "Original", "Each write that may have landed is written back")
    }

    func testALaterQueuedChangeToTheSameFileIsDiscardedFirst() async throws {
        let fixture = try SeratoRemovalFixture()
        defer { fixture.cleanup() }
        let file = try await editableFile(fixture)
        let fileID = try XCTUnwrap(file.id)
        let failing = makeEngine(fixture, tagWriter: Self.readOnlyFile)
        try await edit(file, to: "Edited", batchID: "first", fixture: fixture, engine: failing)
        try await edit(file, to: "Newer", batchID: "second", fixture: fixture, engine: failing)
        let engine = makeEngine(fixture)

        let preview = try await engine.discardPreview(batchID: "first", fileID: fileID)
        XCTAssertEqual(preview.laterChanges.map(\.batchID), ["second"])
        await XCTAssertThrowsErrorAsync(try await engine.discardQueuedChange(batchID: "first", fileID: fileID)) { error in
            guard case OperationEngineError.queuedChangeHasLaterChanges = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let unchanged = try await fixture.row(file)
        XCTAssertEqual(unchanged.title, "Newer", "A refused discard reverts nothing")

        try await engine.discardQueuedChange(batchID: "second", fileID: fileID)
        try await engine.discardQueuedChange(batchID: "first", fileID: fileID)

        let reverted = try await fixture.row(file)
        XCTAssertEqual(reverted.title, "Original")
        XCTAssertEqual(try savedTitle(fixture, file), "Original")
        let pending = try await engine.pendingSeratoWriteCount
        XCTAssertEqual(pending, 0)
    }

    func testDiscardIsRefusedWhileADrainIsApplyingTheChange() async throws {
        let fixture = try SeratoRemovalFixture(fileBacked: true)
        defer { fixture.cleanup() }
        let file = try await editableFile(fixture)
        let fileID = try XCTUnwrap(file.id)
        try await edit(file, to: "Edited", batchID: "edit", fixture: fixture, engine: makeEngine(fixture, tagWriter: Self.readOnlyFile))
        let gate = WriteGate()
        let draining = makeEngine(fixture) { path, update in
            gate.hold()
            try writeAudioTags(filePath: path, update: update)
        }
        let drain = Task { try await draining.drainPendingSeratoUpdates() }
        await gate.waitUntilHeld()

        await XCTAssertThrowsErrorAsync(try await draining.discardQueuedChange(batchID: "edit", fileID: fileID)) { error in
            guard case OperationEngineError.queuedChangeApplying = error else { return XCTFail("Unexpected error: \(error)") }
        }
        gate.release()
        _ = try await drain.value

        let applied = try await fixture.row(file)
        XCTAssertEqual(applied.title, "Edited", "The refused discard reverted nothing")
        XCTAssertEqual(try readAudioTags(filePath: file.path).title, "Edited")
    }

    private static let readOnlyFile: OperationEngine.FileTagWriter = { _, _ in throw CocoaError(.fileWriteNoPermission) }

    private func makeEngine(_ fixture: SeratoRemovalFixture,
                            metadataWriter: @escaping OperationEngine.SeratoMetadataBatchWriter = { databasePath, updates in
                                try batchUpdateDatabaseRecords(databasePath: databasePath, updates: updates)
                            },
                            tagWriter: @escaping OperationEngine.FileTagWriter = { path, update in try writeAudioTags(filePath: path, update: update) })
        -> OperationEngine
    {
        OperationEngine(database: fixture.database, seratoWatchdog: fixture.watchdog, seratoLocator: fixture.locator,
                        fileTagWriter: tagWriter, seratoMetadataBatchWriter: metadataWriter)
    }

    /// A file titled "Original" in the library and in Serato.
    private func editableFile(_ fixture: SeratoRemovalFixture) async throws -> FileRecord {
        let file = try await fixture.add("edited.wav", bytes: FinalRemovalIntegrationTests.wav())
        try fixture.save(paths: [SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path)])
        try setSavedTitle(fixture, file, "Original")
        try await fixture.database.writer.write { database in
            try database.execute(sql: "UPDATE files SET title = ? WHERE id = ?", arguments: ["Original", file.id])
        }
        return try await fixture.row(file)
    }

    /// An edit whose queued writes may fail; the edit itself still commits.
    private func edit(_ file: FileRecord, to title: String, batchID: String, fixture: SeratoRemovalFixture, engine: OperationEngine) async throws {
        let current = try await fixture.row(file)
        var edited = current.seratoMetadata
        edited.title = title
        do {
            try await engine.applyMetadataEdit(fileId: XCTUnwrap(current.id), membershipRevision: current.membershipRevision,
                                               previous: current.seratoMetadata, edited: edited, batchId: batchID)
        } catch OperationEngineError.externalSyncIncomplete {}
    }

    private func savedTitle(_ fixture: SeratoRemovalFixture, _ file: FileRecord) throws -> String? {
        try readDatabaseRecordsStrict(databasePath: fixture.locator.databaseV2Url.path).first { record in
            SeratoPath.normalized(record.path) == file.path
        }?.title
    }

    private func setSavedTitle(_ fixture: SeratoRemovalFixture, _ file: FileRecord, _ title: String) throws {
        _ = try batchUpdateDatabaseRecords(databasePath: fixture.locator.databaseV2Url.path, updates: [
            .init(trackPath: SeratoLibraryLocator.seratoRelativePath(fromAbsolute: file.path),
                  update: .init(artist: nil, title: title, album: nil, genre: nil, bpm: nil, key: nil, comment: nil, length: nil, label: nil)),
        ])
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var count: Int {
        lock.withLock { stored }
    }

    func increment() {
        lock.withLock { stored += 1 }
    }
}

/// Holds the first write that reaches it until the test releases it.
private final class WriteGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var held = false

    func hold() {
        let first = lock.withLock {
            defer { held = true }
            return !held
        }
        guard first else { return }
        entered.signal()
        released.wait()
    }

    func waitUntilHeld() async {
        let entered = entered
        await Task.detached { entered.wait() }.value
    }

    func release() {
        released.signal()
    }
}
