import Combine
import Foundation
import GRDB

/// The "apply track mutation" primitive — every state-changing
/// operation in crate-agent routes through this actor. Holding the
/// chokepoint here guarantees:
///   1. mutations apply atomically (SQLite transaction)
///   2. every mutation produces a journal event with both forward
///      payload and inverse payload (enables undo + per-file history)
///   3. writes to Serato library files are gated on
///      `seratoWatchdog.isSeratoRunning` — when Serato is running, the
///      Serato-side write is queued and replayed when Serato exits.
///      Database state is updated immediately either way, so the UI
///      always reflects the user's intent even when Serato hasn't
///      seen the change yet.
///
/// Mutations supported in SP-1:
///   - `indexNewFile`              : insert a file row, log event
///   - `renameFile`                : update path, rewrite Serato refs
///   - `removeFile`                : delete a file row (does NOT touch
///                                   Serato — used as the inverse of
///                                   `indexNewFile` during undo).
///   - `setMetadata`               : update file's metadata snapshot
///                                   from Serato (no Serato write —
///                                   used by the reload flow)
///   - `commitMetadataToSerato`    : write metadata into Serato's
///                                   database V2 (no DB update —
///                                   assumes DB is already current).
///                                   Gated by SeratoWatchdog like
///                                   renames.
///   - `addTrackToSerato`          : insert a new otrk entry into
///                                   Serato's database V2 (drag-drop
///                                   import). Gated by SeratoWatchdog.
public actor OperationEngine {

    /// Injectable audio-file tag writer. Production wires in the
    /// Rust `writeAudioTags` FFI; tests inject a no-op (or recording)
    /// closure so they can exercise the mutation pipeline without
    /// real audio files on disk.
    public typealias FileTagWriter = @Sendable (String, AudioTagUpdate) throws -> Void

    /// Injectable file-to-Trash mover. Production uses
    /// `FileManager.trashItem`; tests inject a no-op or recorder so
    /// the resolution flow can be exercised without actually moving
    /// files into the user's Trash.
    public typealias FileTrasher = @Sendable (String) throws -> Void

    private let database: LibraryDatabase
    private let seratoWatchdog: SeratoWatchdog
    private let seratoLocator: SeratoLibraryLocator
    private let fileTagWriter: FileTagWriter
    private let fileTrasher: FileTrasher
    private let activityLog: ActivityLog?

    /// Pending writes to Serato library files. Either a path
    /// rewrite or a metadata update. Drained when Serato exits via
    /// `drainPendingSeratoUpdates`.
    private var pendingSeratoWrites: [SeratoPendingWrite] = []

    /// Backing subject for `queueDepthPublisher`. CurrentValueSubject
    /// emits the latest value on subscribe, so UI bindings render
    /// with the correct depth at mount time rather than waiting for
    /// the next mutation.
    ///
    /// `nonisolated(unsafe)`: the subject is read from
    /// `queueDepthPublisher` (a nonisolated computed property used by
    /// SwiftUI) and written from inside the actor. Combine subjects
    /// are internally thread-safe; `CurrentValueSubject` just doesn't
    /// carry a `Sendable` conformance in the current SDK. Localized
    /// opt-out is tighter than asserting Sendable on Apple's class.
    private nonisolated(unsafe) let queueDepthSubject = CurrentValueSubject<Int, Never>(0)

    /// Observable stream of `pendingSeratoWrites.count`. Emits a new
    /// value after every enqueue and every drain step. UI subscribers
    /// (e.g., the menu bar status item) display "N changes pending."
    public nonisolated var queueDepthPublisher: AnyPublisher<Int, Never> {
        queueDepthSubject.eraseToAnyPublisher()
    }

    public init(
        database: LibraryDatabase,
        seratoWatchdog: SeratoWatchdog,
        seratoLocator: SeratoLibraryLocator,
        fileTagWriter: @escaping FileTagWriter = { path, update in
            try writeAudioTags(filePath: path, update: update)
        },
        fileTrasher: @escaping FileTrasher = { path in
            let url = URL(fileURLWithPath: path)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        },
        activityLog: ActivityLog? = nil
    ) {
        self.database = database
        self.seratoWatchdog = seratoWatchdog
        self.seratoLocator = seratoLocator
        self.fileTagWriter = fileTagWriter
        self.fileTrasher = fileTrasher
        self.activityLog = activityLog
    }

    private func note(_ message: String) async {
        guard let log = activityLog else { return }
        await log.log(message, category: .sync)
    }

    /// Apply a mutation with an auto-generated batch identifier. Use
    /// `apply(_:batchId:)` when grouping multiple mutations into a
    /// single user-initiated operation (so undo can replay them all).
    @discardableResult
    public func apply(_ mutation: TrackMutation) async throws -> Int64 {
        try await apply(mutation, batchId: UUID().uuidString)
    }

    /// Apply a mutation under a caller-supplied batch identifier. All
    /// mutations sharing a batch_id are treated as a single
    /// transaction for undo purposes.
    @discardableResult
    public func apply(_ mutation: TrackMutation, batchId: String) async throws -> Int64 {
        let executionResult: ExecutionResult = try await database.writer.write { db in
            try Self.executeAndLog(mutation: mutation, batchId: batchId, in: db)
        }

        if !executionResult.seratoWrites.isEmpty {
            let isSeratoRunning = await seratoWatchdog.isSeratoRunning
            if isSeratoRunning {
                pendingSeratoWrites.append(contentsOf: executionResult.seratoWrites)
                queueDepthSubject.send(pendingSeratoWrites.count)
            } else {
                try await applyConsecutiveSeratoWrites(executionResult.seratoWrites)
            }
        }

        return executionResult.eventId
    }

    /// Apply many mutations under a single batch identifier, atomically.
    ///
    /// One SQLite write transaction covers every mutation's DB-side
    /// work — if any throws, none persist. The `seratoWatchdog`
    /// running-state check happens once, before the transaction, and
    /// is reused for routing every Serato write the batch produced
    /// (queue if Serato is up, apply now if not). This is the path
    /// any caller that produces N>1 related mutations should take —
    /// for N renames the cost goes from N writer transactions and N
    /// actor hops to one of each.
    @discardableResult
    public func applyBatch(
        _ mutations: [TrackMutation],
        batchId: String
    ) async throws -> [Int64] {
        guard !mutations.isEmpty else { return [] }

        let executionResults: [ExecutionResult] = try await database.writer.write { db in
            try mutations.map { mutation in
                try Self.executeAndLog(mutation: mutation, batchId: batchId, in: db)
            }
        }

        let pendingWrites = executionResults.flatMap { $0.seratoWrites }
        if !pendingWrites.isEmpty {
            let isSeratoRunning = await seratoWatchdog.isSeratoRunning
            if isSeratoRunning {
                pendingSeratoWrites.append(contentsOf: pendingWrites)
                queueDepthSubject.send(pendingSeratoWrites.count)
            } else {
                try await applyConsecutiveSeratoWrites(pendingWrites)
            }
        }

        return executionResults.map(\.eventId)
    }

    /// Number of Serato library writes (renames + metadata updates)
    /// currently queued because Serato was running at apply time.
    /// Surfaced for UI ("M changes pending").
    public var pendingSeratoWriteCount: Int {
        pendingSeratoWrites.count
    }

    /// Reverse every event in `batchId` in newest-first order, applying
    /// each inverse mutation under a single fresh `undo:<originalBatchId>:<uuid>`
    /// batch. The new batch is itself journaled, so "undo of undo"
    /// (redo) is just another `undoBatch` call against the returned id.
    ///
    /// Failure modes:
    /// - empty batch → `batchNotFound`
    /// - batch contains an event whose inverse isn't supported (today:
    ///   `metadataCommittedToSerato`, `trackAddedToSerato`) →
    ///   `undoNotSupported`, thrown **before** any inverse runs, so
    ///   the DB stays in its pre-undo state
    /// - apply-time drift (e.g. the file was removed in a later batch
    ///   so renameFile can't find it) → bubbles up as `fileNotFound`
    ///   with partial undo state already applied — caller can issue
    ///   a follow-up undo of the partial undo batch to revert
    ///
    /// Returns the new batch id so the caller (UI) can offer "Undo the
    /// undo" without having to scan the events table.

    /// Replay the Serato-side writes for every `fileRenamed` event
    /// in a batch. Recovery primitive for the case where the
    /// original `applySeratoRename` failed mid-loop (e.g., a
    /// corrupted .crate file aborted the rewrite before
    /// `database V2` got updated). The file move on disk and the
    /// DB row update are already done; this just re-fires the
    /// Serato library rewrite so `database V2` and the .crate
    /// files catch up to the current DB state.
    ///
    /// Idempotent — re-applying a successful rewrite is a no-op
    /// (the path is already what we'd be setting it to).
    ///
    /// Reports applied vs queued counts so the UI can tell the
    /// user whether anything actually landed on disk. When Serato
    /// is running, replays queue in memory and drain on Serato
    /// exit — "Re-sync complete" without that distinction was
    /// misleading and bit a user (issue #64).
    @discardableResult
    public func resyncSeratoForBatch(_ batchId: String) async throws -> ResyncOutcome {
        let events: [EventRecord] = try await database.writer.read { db in
            try EventRecord
                .filter(Column("batch_id") == batchId)
                .order(Column("event_id").asc)
                .fetchAll(db)
        }
        guard !events.isEmpty else {
            throw OperationEngineError.batchNotFound(batchId: batchId)
        }

        await note("Re-syncing Serato library for batch — \(events.count) event\(events.count == 1 ? "" : "s") to inspect")

        var appliedCount = 0
        var queuedCount = 0
        for event in events {
            guard event.eventType == .fileRenamed else { continue }
            guard let forwardJsonData = event.payloadJson.data(using: .utf8) else {
                continue
            }
            let payload: RenameFilePayload
            do {
                payload = try JSONDecoder().decode(
                    RenameFilePayload.self, from: forwardJsonData
                )
            } catch {
                continue
            }
            // The forward payload's `previousPath` is the
            // pre-rename absolute path; if it's missing (older
            // events before this field was always populated),
            // skip — we have no source to rewrite from.
            guard !payload.previousPath.isEmpty else { continue }
            let rename = SeratoPendingRename(
                oldAbsolutePath: payload.previousPath,
                newAbsolutePath: payload.newPath
            )
            // Honor the Serato-running guard the same way
            // `apply` does — queue if Serato is up.
            let isSeratoRunning = await seratoWatchdog.isSeratoRunning
            if isSeratoRunning {
                pendingSeratoWrites.append(.rename(rename))
                queueDepthSubject.send(pendingSeratoWrites.count)
                queuedCount += 1
            } else {
                try await applySeratoRename(rename)
                appliedCount += 1
            }
        }

        let outcome = ResyncOutcome(appliedCount: appliedCount, queuedCount: queuedCount)
        await note(outcome.summaryMessage)
        return outcome
    }

    @discardableResult
    public func undoBatch(_ batchId: String) async throws -> String {
        let events: [EventRecord] = try await database.writer.read { db in
            try EventRecord
                .filter(Column("batch_id") == batchId)
                .order(Column("event_id").desc)
                .fetchAll(db)
        }

        guard !events.isEmpty else {
            throw OperationEngineError.batchNotFound(batchId: batchId)
        }

        // Pre-decode every inverse before mutating anything. If any
        // event in the batch is non-reversible, we fail clean — no
        // partial undo state lands in the DB.
        let inverseMutations = try events.map { event in
            try Self.decodeInverseMutation(event: event)
        }

        let undoBatchId = "undo:\(batchId):\(UUID().uuidString)"
        // One transaction for every inverse mutation in the batch.
        // Undo is conceptually atomic: either the whole batch
        // reverts or none of it does. With N transactions (the
        // pre-batch shape) we'd risk leaving the DB half-undone if
        // one inverse hit a fileNotFound mid-loop.
        _ = try await applyBatch(inverseMutations, batchId: undoBatchId)
        return undoBatchId
    }

    private static func decodeInverseMutation(event: EventRecord) throws -> TrackMutation {
        guard let inverseJsonData = event.inversePayloadJson.data(using: .utf8) else {
            throw OperationEngineError.payloadEncodingFailed
        }
        let decoder = JSONDecoder()
        switch event.eventType {
        case .fileRenamed:
            let payload = try decoder.decode(RenameFilePayload.self, from: inverseJsonData)
            return .renameFile(payload)
        case .metadataSet:
            let payload = try decoder.decode(SetMetadataPayload.self, from: inverseJsonData)
            return .setMetadata(payload)
        case .trackImported:
            let payload = try decoder.decode(RemoveFilePayload.self, from: inverseJsonData)
            return .removeFile(payload)
        case .fileRemoved:
            let payload = try decoder.decode(IndexNewFilePayload.self, from: inverseJsonData)
            return .indexNewFile(payload)
        case .metadataCommittedToSerato:
            // Undoable when the original caller supplied
            // `previousMetadata` (the values Serato held before the
            // forward commit). Old / minimal callers that don't
            // capture previous state journal an inverse with
            // previousMetadata == nil and remain non-undoable.
            let payload = try decoder.decode(
                CommitMetadataToSeratoPayload.self, from: inverseJsonData
            )
            if payload.previousMetadata == nil {
                throw OperationEngineError.undoNotSupported(eventType: event.eventType)
            }
            return .commitMetadataToSerato(payload)
        case .trackAddedToSerato:
            // Reversing this requires a `removeTrackFromSerato` FFI
            // we don't have yet. Document as unsupported rather
            // than half-undo.
            throw OperationEngineError.undoNotSupported(eventType: event.eventType)
        case .fileTrashed, .trackRemovedFromSerato, .fileRemovedFromCrates:
            // Resolution-flow events are deliberately not undoable.
            // Recovery: Finder Trash "Put Back" for the file +
            // manual re-add to Serato. Future work could add an
            // automated restore path if the user demands it.
            throw OperationEngineError.undoNotSupported(eventType: event.eventType)
        case .fileTagsWritten:
            // Undoable when previousMetadata was captured at forward
            // time. Same gate as commitMetadataToSerato.
            let payload = try decoder.decode(
                WriteFileTagsPayload.self, from: inverseJsonData
            )
            if payload.previousMetadata == nil {
                throw OperationEngineError.undoNotSupported(eventType: event.eventType)
            }
            return .writeFileTags(payload)
        case .musicBrainzMatchApplied:
            // Inverse restores prior state from the snapshots captured
            // at apply time (invariant #2). The forward apply always
            // captures them, so the match is unconditionally undoable.
            let payload = try decoder.decode(
                RevertMusicBrainzMatchPayload.self, from: inverseJsonData
            )
            return .revertMusicBrainzMatch(payload)
        case .musicBrainzMatchReverted:
            // Redo (undo of the undo): re-issue the original forward
            // match. The forward apply re-captures fresh snapshots.
            let payload = try decoder.decode(
                ApplyMusicBrainzMatchPayload.self, from: inverseJsonData
            )
            return .applyMusicBrainzMatch(payload)
        }
    }

    /// Apply every queued Serato write. Call this when Serato has
    /// just exited (the SeratoSyncCoordinator drives this). Drains
    /// the queue oldest-first and stops at the first failure, leaving
    /// the remaining entries queued for retry.
    public func drainPendingSeratoUpdates() async throws {
        while let next = pendingSeratoWrites.first {
            try await applySeratoWrite(next)
            pendingSeratoWrites.removeFirst()
            queueDepthSubject.send(pendingSeratoWrites.count)
        }
    }

    private func applySeratoWrite(_ write: SeratoPendingWrite) async throws {
        switch write {
        case .rename(let rename):
            try await applySeratoRename(rename)
        case .metadataUpdate(let update):
            try await applySeratoMetadataUpdate(update)
        case .addTrack(let add):
            try await applySeratoAddTrack(add)
        case .fileTagWrite(let write):
            try await applyFileTagWrite(write)
        case .removeFromDatabase(let removal):
            try await applySeratoDatabaseRemoval(removal)
        case .removeFromCrates(let removal):
            try await applySeratoCrateSweepRemoval(removal)
        case .trashFile(let trash):
            try await applyTrashFileOperation(trash)
        }
    }

    private func applyTrashFileOperation(_ trash: SeratoPendingTrash) async throws {
        do {
            try fileTrasher(trash.absolutePath)
        } catch {
            throw OperationEngineError.trashFailed(
                path: trash.absolutePath,
                underlying: String(describing: error)
            )
        }
    }

    private func applySeratoDatabaseRemoval(_ removal: SeratoPendingRemoval) async throws {
        let databaseV2Path = seratoLocator.databaseV2Url.path
        guard FileManager.default.fileExists(atPath: databaseV2Path) else {
            // No database V2 yet — nothing to remove from. Same
            // tolerant behavior as applySeratoMetadataUpdate.
            return
        }
        let seratoRelativePath = SeratoLibraryLocator.seratoRelativePath(
            fromAbsolute: removal.absolutePath
        )
        do {
            _ = try removeTrackFromDatabase(
                databasePath: databaseV2Path,
                trackPath: seratoRelativePath
            )
        } catch {
            throw OperationEngineError.seratoRewriteFailed(
                path: databaseV2Path,
                underlying: String(describing: error)
            )
        }
    }

    private func applySeratoCrateSweepRemoval(_ removal: SeratoPendingRemoval) async throws {
        let seratoRelativePath = SeratoLibraryLocator.seratoRelativePath(
            fromAbsolute: removal.absolutePath
        )
        let displayFilename = (removal.absolutePath as NSString).lastPathComponent
        let crateFiles: [URL]
        do {
            crateFiles = try seratoLocator.enumerateCrateFiles()
        } catch {
            await note("Failed to enumerate Subcrates directory while removing \(displayFilename): \(error.localizedDescription)")
            throw OperationEngineError.seratoEnumerationFailed(
                directory: seratoLocator.subcratesDirectoryUrl.path,
                underlying: String(describing: error)
            )
        }
        // Per-crate fault tolerance: one bad crate file can't
        // block removing the file's reference from every other
        // crate. Symmetric with `applySeratoRename`.
        var perCrateFailures: [(URL, Error)] = []
        for crateFile in crateFiles {
            do {
                _ = try removePathFromCrate(
                    cratePath: crateFile.path,
                    trackPath: seratoRelativePath
                )
            } catch {
                perCrateFailures.append((crateFile, error))
                let crateName = crateFile.lastPathComponent
                await note("Skipped crate \(crateName) while removing \(displayFilename): \(error.localizedDescription)")
            }
        }
        // Only throw if EVERY crate failed — a partial sweep is
        // still useful (most user crates will succeed).
        if !crateFiles.isEmpty && perCrateFailures.count == crateFiles.count {
            let firstFailure = perCrateFailures[0]
            throw OperationEngineError.seratoRewriteFailed(
                path: firstFailure.0.path,
                underlying: String(describing: firstFailure.1)
            )
        }
    }

    private func applyFileTagWrite(_ write: SeratoPendingFileTagWrite) async throws {
        let update = AudioTagUpdate(
            artist: write.metadata.artist,
            title: write.metadata.title,
            album: write.metadata.album,
            genre: write.metadata.genre,
            bpm: write.metadata.bpm,
            musicalKey: write.metadata.musicalKey,
            comment: write.metadata.comment,
            label: write.metadata.label,
            // Year lives on the pending write, not on SeratoMetadata:
            // Serato's database V2 has no year field, so the MusicBrainz
            // match routes year to the file tags only. `writeFileTags`
            // leaves it nil.
            year: write.year.flatMap { $0 >= 0 ? UInt32($0) : nil },
            clearYear: write.clearYear
        )
        do {
            try fileTagWriter(write.absolutePath, update)
        } catch {
            throw OperationEngineError.fileTagWriteFailed(
                path: write.absolutePath,
                underlying: String(describing: error)
            )
        }
    }

    private func applySeratoAddTrack(_ add: SeratoPendingAddTrack) async throws {
        let databaseV2Path = seratoLocator.databaseV2Url.path
        let seratoRelativePath = SeratoLibraryLocator.seratoRelativePath(
            fromAbsolute: add.absolutePath
        )

        // If Serato has never run on this machine there's no database
        // V2 yet. We still want to register the import — write a fresh
        // one with just our otrk. Subsequent Serato launches will
        // augment it with the full analysis schema.
        if !FileManager.default.fileExists(atPath: databaseV2Path) {
            try FileManager.default.createDirectory(
                at: seratoLocator.seratoDirectory,
                withIntermediateDirectories: true
            )
            let bootstrapBytes = freshDatabaseV2Bytes(
                withTrackPath: seratoRelativePath,
                metadata: add.metadata
            )
            try bootstrapBytes.write(to: URL(fileURLWithPath: databaseV2Path))
            return
        }

        do {
            _ = try addTrackToDatabase(
                databasePath: databaseV2Path,
                trackPath: seratoRelativePath,
                metadata: SeratoMetadataUpdate(
                    artist: add.metadata.artist,
                    title: add.metadata.title,
                    album: add.metadata.album,
                    genre: add.metadata.genre,
                    bpm: add.metadata.bpm,
                    key: add.metadata.musicalKey,
                    comment: add.metadata.comment,
                    length: add.metadata.length,
                    label: add.metadata.label
                )
            )
        } catch {
            throw OperationEngineError.seratoRewriteFailed(
                path: databaseV2Path,
                underlying: String(describing: error)
            )
        }
    }

    /// Build the byte layout of a brand-new `database V2` containing
    /// exactly one otrk for the supplied path + metadata. Used when
    /// a user drops a file but Serato has never run on this machine
    /// (the database V2 file doesn't exist yet).
    private func freshDatabaseV2Bytes(
        withTrackPath seratoRelativePath: String,
        metadata: SeratoMetadata
    ) -> Data {
        var bytes = Data()

        // vrsn header: 4-byte tag + 4-byte BE length + UTF-16BE payload
        let versionString = "2.0/Serato Scratch LIVE Database"
        let versionPayload = utf16BeBytes(of: versionString)
        bytes.append(contentsOf: "vrsn".utf8)
        bytes.append(contentsOf: uint32BeBytes(of: UInt32(versionPayload.count)))
        bytes.append(versionPayload)

        // otrk container with pfil + any t* metadata fields
        var otrkPayload = Data()
        appendTlv(tag: "pfil", payload: utf16BeBytes(of: seratoRelativePath), to: &otrkPayload)
        if let value = metadata.artist {
            appendTlv(tag: "tart", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.title {
            appendTlv(tag: "tsng", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.album {
            appendTlv(tag: "talb", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.genre {
            appendTlv(tag: "tgen", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.bpm {
            appendTlv(tag: "tbpm", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.musicalKey {
            appendTlv(tag: "tkey", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.comment {
            appendTlv(tag: "tcom", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.length {
            appendTlv(tag: "tlen", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }
        if let value = metadata.label {
            appendTlv(tag: "tlbl", payload: utf16BeBytes(of: value), to: &otrkPayload)
        }

        bytes.append(contentsOf: "otrk".utf8)
        bytes.append(contentsOf: uint32BeBytes(of: UInt32(otrkPayload.count)))
        bytes.append(otrkPayload)
        return bytes
    }

    private func appendTlv(tag: String, payload: Data, to data: inout Data) {
        precondition(tag.utf8.count == 4)
        data.append(contentsOf: tag.utf8)
        data.append(contentsOf: uint32BeBytes(of: UInt32(payload.count)))
        data.append(payload)
    }

    private func utf16BeBytes(of string: String) -> Data {
        var data = Data()
        for codeUnit in string.utf16 {
            data.append(UInt8(codeUnit >> 8))
            data.append(UInt8(codeUnit & 0xFF))
        }
        return data
    }

    private func uint32BeBytes(of value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private func applySeratoRename(_ rename: SeratoPendingRename) async throws {
        let oldSeratoPath = SeratoLibraryLocator.seratoRelativePath(
            fromAbsolute: rename.oldAbsolutePath
        )
        let newSeratoPath = SeratoLibraryLocator.seratoRelativePath(
            fromAbsolute: rename.newAbsolutePath
        )
        let displayFilename = (rename.newAbsolutePath as NSString).lastPathComponent

        // Database V2 first, then crates. Database V2 is the source
        // of truth for Serato's "All" view — the thing the user
        // actually sees and drags from. If a single corrupted
        // .crate file throws (rare but real on user libraries
        // that have accumulated cruft), we still need V2 updated;
        // otherwise tracks move on disk and Serato keeps the old
        // path forever (the bug PR fixed).
        var databaseV2Rewrites: UInt32 = 0
        var databaseV2Error: Error?
        let databaseV2Path = seratoLocator.databaseV2Url.path
        if FileManager.default.fileExists(atPath: databaseV2Path) {
            do {
                databaseV2Rewrites = try rewriteDatabasePath(
                    databasePath: databaseV2Path,
                    oldPath: oldSeratoPath,
                    newPath: newSeratoPath
                )
                if databaseV2Rewrites == 0 {
                    // Old path wasn't in database V2. Surprising —
                    // surface so the user can see something is off
                    // (e.g., Unicode normalization mismatch, prior
                    // failed sync, or the track was never in
                    // Serato to begin with).
                    await note("⚠️ database V2 had no entry for \(oldSeratoPath) — \(displayFilename) won't appear in Serato until re-imported.")
                }
            } catch {
                databaseV2Error = error
                await note("Failed to update database V2 for \(displayFilename): \(error.localizedDescription)")
            }
        }

        let crateFiles: [URL]
        do {
            crateFiles = try seratoLocator.enumerateCrateFiles()
        } catch {
            // Enumeration failure is symmetric with the V2 failure
            // — both surface, neither stops the other.
            await note("Failed to enumerate Subcrates directory: \(error.localizedDescription)")
            if databaseV2Error != nil {
                throw OperationEngineError.seratoEnumerationFailed(
                    directory: seratoLocator.subcratesDirectoryUrl.path,
                    underlying: String(describing: error)
                )
            }
            return
        }

        var perCrateFailures: [(URL, Error)] = []
        for crateFile in crateFiles {
            do {
                _ = try rewriteCratePath(
                    cratePath: crateFile.path,
                    oldPath: oldSeratoPath,
                    newPath: newSeratoPath
                )
            } catch {
                // Per-crate fault tolerance: log and continue. A
                // single bad crate file can't poison the entire
                // sync for the rest of the user's library.
                perCrateFailures.append((crateFile, error))
                let crateName = crateFile.lastPathComponent
                await note("Skipped crate \(crateName) while renaming \(displayFilename): \(error.localizedDescription)")
            }
        }

        // Throw only if both V2 and every crate failed — at that
        // point we genuinely couldn't sync anything and the caller
        // (e.g., the organizer) needs to know the file move on
        // disk has no matching library update.
        let everyCrateFailed = !crateFiles.isEmpty
            && perCrateFailures.count == crateFiles.count
        if databaseV2Error != nil && (everyCrateFailed || crateFiles.isEmpty) {
            throw OperationEngineError.seratoRewriteFailed(
                path: databaseV2Path,
                underlying: String(describing: databaseV2Error!)
            )
        }
    }

    /// Bulk variant of `applySeratoRename`. One Rust FFI call to
    /// rewrite the `database V2` file for every rename in the batch,
    /// then one FFI call per crate file. Same failure semantics as
    /// the single-rename path — V2 errors are recorded but don't
    /// stop the crate sweep; a final throw only fires if V2 failed
    /// AND every crate failed (or there were no crates).
    ///
    /// Falls back to the per-rename path for batches of size 1 to
    /// preserve the more granular "⚠️ no entry for X" diagnostic
    /// (the batch FFI returns a single aggregate count and can't
    /// distinguish "0 renames applied" from "all renames missed").
    private func applySeratoRenameBatch(_ renames: [SeratoPendingRename]) async throws {
        guard renames.count > 1 else {
            if let single = renames.first {
                try await applySeratoRename(single)
            }
            return
        }

        let pairs = renames.map { rename in
            SeratoPathRename(
                oldPath: SeratoLibraryLocator.seratoRelativePath(
                    fromAbsolute: rename.oldAbsolutePath
                ),
                newPath: SeratoLibraryLocator.seratoRelativePath(
                    fromAbsolute: rename.newAbsolutePath
                )
            )
        }

        var databaseV2Error: Error?
        let databaseV2Path = seratoLocator.databaseV2Url.path
        if FileManager.default.fileExists(atPath: databaseV2Path) {
            do {
                _ = try batchRewriteDatabasePaths(
                    databasePath: databaseV2Path,
                    renames: pairs
                )
            } catch {
                databaseV2Error = error
                await note("Failed to update database V2 for \(renames.count) renames: \(error.localizedDescription)")
            }
        }

        let crateFiles: [URL]
        do {
            crateFiles = try seratoLocator.enumerateCrateFiles()
        } catch {
            await note("Failed to enumerate Subcrates directory: \(error.localizedDescription)")
            if databaseV2Error != nil {
                throw OperationEngineError.seratoEnumerationFailed(
                    directory: seratoLocator.subcratesDirectoryUrl.path,
                    underlying: String(describing: error)
                )
            }
            return
        }

        var perCrateFailures: [(URL, Error)] = []
        for crateFile in crateFiles {
            do {
                _ = try batchRewriteCratePaths(
                    cratePath: crateFile.path,
                    renames: pairs
                )
            } catch {
                perCrateFailures.append((crateFile, error))
                await note("Skipped crate \(crateFile.lastPathComponent) during batch rename: \(error.localizedDescription)")
            }
        }

        let everyCrateFailed = !crateFiles.isEmpty
            && perCrateFailures.count == crateFiles.count
        if databaseV2Error != nil && (everyCrateFailed || crateFiles.isEmpty) {
            throw OperationEngineError.seratoRewriteFailed(
                path: databaseV2Path,
                underlying: String(describing: databaseV2Error!)
            )
        }
    }

    /// Coalesce consecutive `.rename` writes into one
    /// `applySeratoRenameBatch` call; non-rename writes apply
    /// individually. Used by `applyBatch` when Serato is not
    /// running — for a bulk Organize batch (all renames) this
    /// turns N full V2 read+write cycles into one.
    private func applyConsecutiveSeratoWrites(
        _ writes: [SeratoPendingWrite]
    ) async throws {
        var index = 0
        while index < writes.count {
            if case .rename = writes[index] {
                var renames: [SeratoPendingRename] = []
                while index < writes.count, case .rename(let rename) = writes[index] {
                    renames.append(rename)
                    index += 1
                }
                try await applySeratoRenameBatch(renames)
            } else {
                try await applySeratoWrite(writes[index])
                index += 1
            }
        }
    }

    private func applySeratoMetadataUpdate(_ update: SeratoPendingMetadataUpdate) async throws {
        let databaseV2Path = seratoLocator.databaseV2Url.path
        guard FileManager.default.fileExists(atPath: databaseV2Path) else {
            // No database V2 exists yet — Serato has never run on
            // this machine. The metadata update is a no-op (nothing
            // for Serato to "see").
            return
        }

        let seratoRelativePath = SeratoLibraryLocator.seratoRelativePath(
            fromAbsolute: update.absolutePath
        )

        do {
            _ = try updateDatabaseRecord(
                databasePath: databaseV2Path,
                trackPath: seratoRelativePath,
                update: SeratoMetadataUpdate(
                    artist: update.metadata.artist,
                    title: update.metadata.title,
                    album: update.metadata.album,
                    genre: update.metadata.genre,
                    bpm: update.metadata.bpm,
                    key: update.metadata.musicalKey,
                    comment: update.metadata.comment,
                    length: update.metadata.length,
                    label: update.metadata.label
                )
            )
        } catch {
            throw OperationEngineError.seratoRewriteFailed(
                path: databaseV2Path,
                underlying: String(describing: error)
            )
        }
    }

    // MARK: - Synchronous SQL apply

    private struct ExecutionResult: Sendable {
        let eventId: Int64
        /// Serato-gated writes this mutation produced, applied in order.
        /// Most mutations emit zero or one; `applyMusicBrainzMatch`
        /// emits two (a database-V2 metadata update and a file-tag
        /// write).
        let seratoWrites: [SeratoPendingWrite]
    }

    private static func executeAndLog(
        mutation: TrackMutation,
        batchId: String,
        in db: GRDB.Database
    ) throws -> ExecutionResult {
        let timestampMillis = Int64(Date().timeIntervalSince1970 * 1000)
        switch mutation {
        case .indexNewFile(let payload):
            let eventId = try applyIndexNewFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case .renameFile(let payload):
            let (eventId, seratoRename) = try applyRenameFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.rename(seratoRename)]
            )
        case .removeFile(let payload):
            let eventId = try applyRemoveFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case .setMetadata(let payload):
            let eventId = try applySetMetadata(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: [])
        case .commitMetadataToSerato(let payload):
            let (eventId, seratoUpdate) = try applyCommitMetadataToSerato(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.metadataUpdate(seratoUpdate)]
            )
        case .addTrackToSerato(let payload):
            let (eventId, seratoAdd) = try applyAddTrackToSerato(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.addTrack(seratoAdd)]
            )
        case .writeFileTags(let payload):
            let (eventId, fileTagWrite) = try applyWriteFileTags(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.fileTagWrite(fileTagWrite)]
            )
        case .trashFile(let payload):
            let (eventId, trash) = try applyTrashFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: [.trashFile(trash)])
        case .removeTrackFromSerato(let payload):
            let (eventId, removal) = try applyRemoveTrackFromSerato(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.removeFromDatabase(removal)]
            )
        case .removeFileFromCrates(let payload):
            let (eventId, removal) = try applyRemoveFileFromCrates(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrites: [.removeFromCrates(removal)]
            )
        case .applyMusicBrainzMatch(let payload):
            let (eventId, seratoWrites) = try applyMusicBrainzMatch(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: seratoWrites)
        case .revertMusicBrainzMatch(let payload):
            let (eventId, seratoWrites) = try applyRevertMusicBrainzMatch(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrites: seratoWrites)
        }
    }

    private static func applyRemoveFile(
        _ payload: RemoveFilePayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> Int64 {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }

        // The inverse of a removal is a full reinsertion. Capture
        // every field the indexer needs so undo can rebuild the row
        // byte-for-byte (modulo the new auto-incremented id, which
        // isn't user-visible).
        let inversePayload = IndexNewFilePayload(
            path: fileRecord.path,
            volumeUuid: fileRecord.volumeUuid,
            inode: fileRecord.inode,
            fileSize: fileRecord.fileSize,
            mtime: fileRecord.mtime,
            lightweightHash: fileRecord.lightweightHash,
            bitrateKbps: fileRecord.bitrateKbps,
            metadata: SeratoMetadata(
                artist: fileRecord.artist,
                title: fileRecord.title,
                album: fileRecord.album,
                genre: fileRecord.genre,
                bpm: fileRecord.bpm,
                musicalKey: fileRecord.musicalKey,
                comment: fileRecord.comment,
                length: fileRecord.length,
                label: fileRecord.label
            )
        )

        // Insert the event BEFORE deleting the file: at delete time,
        // the schema's ON DELETE SET NULL cascade rewrites every
        // file_id referencing this row (including the event we just
        // inserted) to NULL. Per-file-history queries can't find the
        // event afterward, but the batch_id grouping is preserved
        // and the inverse payload carries everything undo needs.
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileRemoved,
            forwardPayload: payload,
            inversePayload: inversePayload,
            in: db
        )

        try fileRecord.delete(db)

        return eventId
    }

    private static func applyIndexNewFile(
        _ payload: IndexNewFilePayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> Int64 {
        var fileRecord = FileRecord(
            path: payload.path,
            volumeUuid: payload.volumeUuid,
            inode: payload.inode,
            fileSize: payload.fileSize,
            mtime: payload.mtime,
            lightweightHash: payload.lightweightHash,
            fingerprintStatus: .pending,
            bitrateKbps: payload.bitrateKbps,
            artist: payload.metadata.artist,
            title: payload.metadata.title,
            album: payload.metadata.album,
            genre: payload.metadata.genre,
            bpm: payload.metadata.bpm,
            musicalKey: payload.metadata.musicalKey,
            comment: payload.metadata.comment,
            length: payload.metadata.length,
            label: payload.metadata.label
        )
        try fileRecord.insert(db)
        guard let fileId = fileRecord.id else {
            throw OperationEngineError.insertDidNotReturnRowId
        }

        return try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: fileId,
            eventType: .trackImported,
            forwardPayload: payload,
            inversePayload: RemoveFilePayload(fileId: fileId),
            in: db
        )
    }

    private static func applySetMetadata(
        _ payload: SetMetadataPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> Int64 {
        guard var fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }

        let originalMetadata = SeratoMetadata(
            artist: fileRecord.artist,
            title: fileRecord.title,
            album: fileRecord.album,
            genre: fileRecord.genre,
            bpm: fileRecord.bpm,
            musicalKey: fileRecord.musicalKey,
            comment: fileRecord.comment,
            length: fileRecord.length,
            label: fileRecord.label
        )

        fileRecord.artist = payload.metadata.artist
        fileRecord.title = payload.metadata.title
        fileRecord.album = payload.metadata.album
        fileRecord.genre = payload.metadata.genre
        fileRecord.bpm = payload.metadata.bpm
        fileRecord.musicalKey = payload.metadata.musicalKey
        fileRecord.comment = payload.metadata.comment
        fileRecord.length = payload.metadata.length
        fileRecord.label = payload.metadata.label
        try fileRecord.update(db)

        let forwardPayload = SetMetadataPayload(
            fileId: payload.fileId,
            metadata: payload.metadata,
            previousMetadata: originalMetadata
        )
        let inversePayload = SetMetadataPayload(
            fileId: payload.fileId,
            metadata: originalMetadata,
            previousMetadata: payload.metadata
        )

        return try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .metadataSet,
            forwardPayload: forwardPayload,
            inversePayload: inversePayload,
            in: db
        )
    }

    private static func applyRenameFile(
        _ payload: RenameFilePayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingRename) {
        guard var fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        let originalPath = fileRecord.path
        let originalVolumeUuid = fileRecord.volumeUuid
        let originalInode = fileRecord.inode

        fileRecord.path = payload.newPath
        if let newVolumeUuid = payload.newVolumeUuid {
            fileRecord.volumeUuid = newVolumeUuid
        }
        if let newInode = payload.newInode {
            fileRecord.inode = newInode
        }
        try fileRecord.update(db)

        let forwardPayload = RenameFilePayload(
            fileId: payload.fileId,
            newPath: payload.newPath,
            previousPath: originalPath,
            newVolumeUuid: payload.newVolumeUuid,
            newInode: payload.newInode,
            previousVolumeUuid: payload.newVolumeUuid == nil ? nil : originalVolumeUuid,
            previousInode: payload.newInode == nil ? nil : originalInode
        )
        let inversePayload = RenameFilePayload(
            fileId: payload.fileId,
            newPath: originalPath,
            previousPath: payload.newPath,
            newVolumeUuid: payload.newVolumeUuid == nil ? nil : originalVolumeUuid,
            newInode: payload.newInode == nil ? nil : originalInode,
            previousVolumeUuid: payload.newVolumeUuid,
            previousInode: payload.newInode
        )

        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileRenamed,
            forwardPayload: forwardPayload,
            inversePayload: inversePayload,
            in: db
        )
        let seratoRename = SeratoPendingRename(
            oldAbsolutePath: originalPath,
            newAbsolutePath: payload.newPath
        )
        return (eventId, seratoRename)
    }

    private static func applyAddTrackToSerato(
        _ payload: AddTrackToSeratoPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingAddTrack) {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }

        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .trackAddedToSerato,
            forwardPayload: payload,
            inversePayload: payload,
            in: db
        )

        let pending = SeratoPendingAddTrack(
            absolutePath: fileRecord.path,
            metadata: payload.metadata
        )
        return (eventId, pending)
    }

    private static func applyCommitMetadataToSerato(
        _ payload: CommitMetadataToSeratoPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingMetadataUpdate) {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }

        // Inverse is the "re-issue this commit with previous and
        // current swapped" mutation. Only meaningful when the caller
        // supplied `previousMetadata`; otherwise the inverse mirrors
        // the forward and the event is rejected by undoBatch
        // (decodeInverseMutation gates on inverse.previousMetadata
        // being non-nil).
        let inversePayload = CommitMetadataToSeratoPayload(
            fileId: payload.fileId,
            metadata: payload.previousMetadata ?? payload.metadata,
            previousMetadata: payload.previousMetadata == nil ? nil : payload.metadata
        )
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .metadataCommittedToSerato,
            forwardPayload: payload,
            inversePayload: inversePayload,
            in: db
        )

        let pending = SeratoPendingMetadataUpdate(
            absolutePath: fileRecord.path,
            metadata: payload.metadata
        )
        return (eventId, pending)
    }

    private static func applyWriteFileTags(
        _ payload: WriteFileTagsPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingFileTagWrite) {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }

        // Mirror commitMetadataToSerato's inverse pattern: when the
        // caller supplied `previousMetadata`, the inverse swaps
        // metadata ↔ previousMetadata. Without it, the inverse
        // mirrors the forward and the event is rejected by
        // decodeInverseMutation (callers without prior state forfeit
        // undo for this event).
        let inversePayload = WriteFileTagsPayload(
            fileId: payload.fileId,
            metadata: payload.previousMetadata ?? payload.metadata,
            previousMetadata: payload.previousMetadata == nil ? nil : payload.metadata
        )
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileTagsWritten,
            forwardPayload: payload,
            inversePayload: inversePayload,
            in: db
        )

        let pending = SeratoPendingFileTagWrite(
            absolutePath: fileRecord.path,
            metadata: payload.metadata
        )
        return (eventId, pending)
    }

    /// Sentinel stored in `inverse_payload_json` for events that
    /// are structurally non-undoable (trash, remove-from-Serato,
    /// remove-from-crates). Previously these events stored the
    /// forward payload twice — auditors couldn't distinguish "no
    /// inverse" from "inverse identical to forward," and a future
    /// engineer wiring up undo would decode garbage. The sentinel
    /// makes the events table self-describing: `inverse_payload_json`
    /// reading `{"reason":"non-undoable",…}` is the unambiguous
    /// signal that `decodeInverseMutation` will throw
    /// `undoNotSupported` for this row.
    private struct NonUndoableInverse: Codable {
        let reason: String
        let eventType: String
        let recoveryNote: String
    }

    private static func applyTrashFile(
        _ payload: TrashFilePayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingTrash) {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }

        // Capture path in the journal payload so even if the file
        // row gets deleted later in the same batch (ON DELETE SET
        // NULL cascade nulls the event's file_id), History still
        // records exactly what was trashed.
        struct ForwardPayload: Codable {
            let fileId: Int64
            let path: String
        }
        let forwardPayload = ForwardPayload(
            fileId: payload.fileId,
            path: fileRecord.path
        )
        let inverse = NonUndoableInverse(
            reason: "non-undoable",
            eventType: EventType.fileTrashed.rawValue,
            recoveryNote: "Restore from Finder Trash before it is emptied."
        )
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileTrashed,
            forwardPayload: forwardPayload,
            inversePayload: inverse,
            in: db
        )
        return (eventId, SeratoPendingTrash(absolutePath: fileRecord.path))
    }

    private static func applyRemoveTrackFromSerato(
        _ payload: RemoveTrackFromSeratoPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingRemoval) {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        struct ForwardPayload: Codable {
            let fileId: Int64
            let path: String
        }
        let forwardPayload = ForwardPayload(
            fileId: payload.fileId,
            path: fileRecord.path
        )
        let inverse = NonUndoableInverse(
            reason: "non-undoable",
            eventType: EventType.trackRemovedFromSerato.rawValue,
            recoveryNote: "Re-add the track to Serato's library via drag-drop or rescan."
        )
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .trackRemovedFromSerato,
            forwardPayload: forwardPayload,
            inversePayload: inverse,
            in: db
        )
        let pending = SeratoPendingRemoval(absolutePath: fileRecord.path)
        return (eventId, pending)
    }

    private static func applyRemoveFileFromCrates(
        _ payload: RemoveFileFromCratesPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, SeratoPendingRemoval) {
        guard let fileRecord = try FileRecord.fetchOne(db, key: payload.fileId) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileId)
        }
        struct ForwardPayload: Codable {
            let fileId: Int64
            let path: String
        }
        let forwardPayload = ForwardPayload(
            fileId: payload.fileId,
            path: fileRecord.path
        )
        let inverse = NonUndoableInverse(
            reason: "non-undoable",
            eventType: EventType.fileRemovedFromCrates.rawValue,
            recoveryNote: "Re-add the path to each affected crate manually in Serato."
        )
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileRemovedFromCrates,
            forwardPayload: forwardPayload,
            inversePayload: inverse,
            in: db
        )
        let pending = SeratoPendingRemoval(absolutePath: fileRecord.path)
        return (eventId, pending)
    }

    /// The paired Serato-side writes a MusicBrainz match (or its
    /// revert) produces: a `database V2` metadata update and an audio
    /// file-tag write. Year rides only on the file-tag write —
    /// `SeratoMetadata`, and thus `database V2`, has no year field. This
    /// is the shared mechanic both the forward apply and the inverse
    /// revert call with different values (applied vs. restored).
    private static func musicBrainzSeratoWrites(
        absolutePath: String,
        artist: String?,
        title: String?,
        album: String?,
        year: Int?,
        clearFileYear: Bool = false
    ) -> [SeratoPendingWrite] {
        let metadata = SeratoMetadata(artist: artist, title: title, album: album)
        return [
            // Serato's database V2 has no year field, so `clearFileYear`
            // is irrelevant to the metadata update — it only affects the
            // file-tag write.
            .metadataUpdate(SeratoPendingMetadataUpdate(
                absolutePath: absolutePath, metadata: metadata
            )),
            .fileTagWrite(SeratoPendingFileTagWrite(
                absolutePath: absolutePath, metadata: metadata, year: year, clearYear: clearFileYear
            )),
        ]
    }

    private static func applyMusicBrainzMatch(
        _ payload: ApplyMusicBrainzMatchPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, [SeratoPendingWrite]) {
        guard var fileRecord = try FileRecord.fetchOne(db, key: payload.fileID) else {
            throw OperationEngineError.fileNotFound(fileId: payload.fileID)
        }

        // Snapshot the file's Serato metadata + track link before
        // mutating, so the inverse can restore them exactly.
        let previousMetadata = SeratoMetadata(
            artist: fileRecord.artist,
            title: fileRecord.title,
            album: fileRecord.album,
            genre: fileRecord.genre,
            bpm: fileRecord.bpm,
            musicalKey: fileRecord.musicalKey,
            comment: fileRecord.comment,
            length: fileRecord.length,
            label: fileRecord.label
        )
        let previousTrackID = fileRecord.trackId

        // Upsert the canonical track row keyed by fingerprint (invariant
        // #4): identity fields always applied, display fields cherry-
        // picked (nil leaves the prior value).
        var previousTrackIdentifiers: TrackIdentifiers?
        let createdTrackRow: Bool
        let trackID: Int64

        if var existingTrack = try TrackRecord
            .filter(Column("fingerprint_hash") == payload.fingerprintHash)
            .fetchOne(db) {
            previousTrackIdentifiers = TrackIdentifiers(
                acoustID: existingTrack.acoustidId,
                recordingMBID: existingTrack.musicbrainzRecordingId,
                releaseMBID: existingTrack.musicbrainzReleaseId,
                artistMBID: existingTrack.musicbrainzArtistId,
                isrc: existingTrack.isrc,
                artist: existingTrack.artist,
                title: existingTrack.title,
                album: existingTrack.album,
                year: existingTrack.year
            )
            createdTrackRow = false
            existingTrack.acoustidId = payload.acoustID
            existingTrack.musicbrainzRecordingId = payload.recordingMBID
            existingTrack.musicbrainzReleaseId = payload.releaseMBID
            existingTrack.musicbrainzArtistId = payload.artistMBID
            existingTrack.isrc = payload.isrc
            if let artist = payload.artist { existingTrack.artist = artist }
            if let title = payload.title { existingTrack.title = title }
            if let album = payload.album { existingTrack.album = album }
            if let year = payload.year { existingTrack.year = year }
            try existingTrack.update(db)
            guard let existingId = existingTrack.id else {
                throw OperationEngineError.insertDidNotReturnRowId
            }
            trackID = existingId
        } else {
            previousTrackIdentifiers = nil
            createdTrackRow = true
            var newTrack = TrackRecord(
                fingerprintHash: payload.fingerprintHash,
                acoustidId: payload.acoustID,
                musicbrainzRecordingId: payload.recordingMBID,
                musicbrainzReleaseId: payload.releaseMBID,
                musicbrainzArtistId: payload.artistMBID,
                isrc: payload.isrc,
                artist: payload.artist,
                title: payload.title,
                album: payload.album,
                year: payload.year
            )
            try newTrack.insert(db)
            guard let newId = newTrack.id else {
                throw OperationEngineError.insertDidNotReturnRowId
            }
            trackID = newId
        }

        // Link the file and apply the cherry-picked display fields to
        // its Serato snapshot.
        fileRecord.trackId = trackID
        if let artist = payload.artist { fileRecord.artist = artist }
        if let title = payload.title { fileRecord.title = title }
        if let album = payload.album { fileRecord.album = album }
        try fileRecord.update(db)

        var forwardPayload = payload
        forwardPayload.previousTrackID = previousTrackID
        forwardPayload.previousMetadata = previousMetadata
        forwardPayload.previousFileTags = previousMetadata
        forwardPayload.previousFileYear = payload.currentFileYear
        forwardPayload.previousTrackIdentifiers = previousTrackIdentifiers
        forwardPayload.createdTrackRow = createdTrackRow

        let inversePayload = RevertMusicBrainzMatchPayload(applied: forwardPayload)

        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileID,
            trackId: trackID,
            eventType: .musicBrainzMatchApplied,
            forwardPayload: forwardPayload,
            inversePayload: inversePayload,
            in: db
        )

        let seratoWrites = musicBrainzSeratoWrites(
            absolutePath: fileRecord.path,
            artist: payload.artist,
            title: payload.title,
            album: payload.album,
            year: payload.year
        )
        return (eventId, seratoWrites)
    }

    private static func applyRevertMusicBrainzMatch(
        _ payload: RevertMusicBrainzMatchPayload,
        batchId: String,
        timestamp: Int64,
        in db: GRDB.Database
    ) throws -> (Int64, [SeratoPendingWrite]) {
        let applied = payload.applied
        guard var fileRecord = try FileRecord.fetchOne(db, key: applied.fileID) else {
            throw OperationEngineError.fileNotFound(fileId: applied.fileID)
        }

        // Restore the file link + Serato snapshot for exactly the
        // display fields the forward changed.
        fileRecord.trackId = applied.previousTrackID
        if let previousMetadata = applied.previousMetadata {
            if applied.artist != nil { fileRecord.artist = previousMetadata.artist }
            if applied.title != nil { fileRecord.title = previousMetadata.title }
            if applied.album != nil { fileRecord.album = previousMetadata.album }
        }
        try fileRecord.update(db)

        // Restore or null the canonical track row (found by fingerprint;
        // it always exists here — the forward created it or it pre-
        // existed).
        if var track = try TrackRecord
            .filter(Column("fingerprint_hash") == applied.fingerprintHash)
            .fetchOne(db) {
            // Undoing batch A must never overwrite what a later batch B
            // established on the same fingerprint-keyed row (invariant
            // #4: FLAC+MP3 of one recording, or a re-encode, share a
            // track row). B — applied after A — takes the existing-row
            // branch and overwrites this row's identity, so if T's
            // current identity no longer matches what A's forward wrote,
            // B owns the row now and A's undo must leave it alone.
            let forwardIdentityStillOnRow =
                track.acoustidId == applied.acoustID
                && track.musicbrainzRecordingId == applied.recordingMBID
                && track.musicbrainzReleaseId == applied.releaseMBID
                && track.musicbrainzArtistId == applied.artistMBID
                && track.isrc == applied.isrc

            if applied.createdTrackRow {
                // The forward created this row. Null what it set and leave
                // the now-orphaned row in place — but ONLY when nothing
                // else adopted it since: no other file references it AND
                // its identity is still exactly what this forward wrote.
                // Otherwise a later batch's match would be silently wiped.
                let otherReferents = try FileRecord
                    .filter(Column("track_id") == track.id && Column("id") != applied.fileID)
                    .fetchCount(db)
                if otherReferents == 0 && forwardIdentityStillOnRow {
                    track.acoustidId = nil
                    track.musicbrainzRecordingId = nil
                    track.musicbrainzReleaseId = nil
                    track.musicbrainzArtistId = nil
                    track.isrc = nil
                    if applied.artist != nil { track.artist = nil }
                    if applied.title != nil { track.title = nil }
                    if applied.album != nil { track.album = nil }
                    if applied.year != nil { track.year = nil }
                    try track.update(db)
                }
            } else if let previous = applied.previousTrackIdentifiers {
                // Restore the pre-existing row's captured identity — but
                // only if no later batch changed it since. If B re-matched
                // the same row after A, restoring A's `previous` here would
                // clobber B's identity; leave B's in place instead.
                if forwardIdentityStillOnRow {
                    track.acoustidId = previous.acoustID
                    track.musicbrainzRecordingId = previous.recordingMBID
                    track.musicbrainzReleaseId = previous.releaseMBID
                    track.musicbrainzArtistId = previous.artistMBID
                    track.isrc = previous.isrc
                    track.artist = previous.artist
                    track.title = previous.title
                    track.album = previous.album
                    track.year = previous.year
                    try track.update(db)
                }
            } else {
                // Unreachable: a pre-existing track row (createdTrackRow
                // == false) always captures previousTrackIdentifiers in
                // the forward apply. If this ever fires, the forward's
                // invariant broke silently, and no-oping here would
                // leave the row's identifiers unchanged instead of
                // restored — fail loudly instead.
                assertionFailure(
                    "applyRevertMusicBrainzMatch: pre-existing track row for file \(applied.fileID) has no previousTrackIdentifiers to restore"
                )
                throw OperationEngineError.missingPreviousTrackIdentifiers(fileId: applied.fileID)
            }
        }

        // Journal the revert; its inverse is the original forward match
        // so redo (undo of the undo) re-applies it.
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: applied.fileID,
            trackId: applied.previousTrackID,
            eventType: .musicBrainzMatchReverted,
            forwardPayload: payload,
            inversePayload: applied,
            in: db
        )

        // Restore the audio file's tags to their exact pre-match values.
        // For every text field the forward actually wrote, undo must
        // rewrite it: to its captured pre-match value, or — when that was
        // absent — an empty string so the Rust writer *clears* it (nil
        // would leave the just-applied value in place).
        let restoredTags = applied.previousFileTags ?? applied.previousMetadata ?? .empty
        let forwardWroteYear = applied.year != nil
        let seratoWrites = musicBrainzSeratoWrites(
            absolutePath: fileRecord.path,
            artist: applied.artist != nil ? (restoredTags.artist ?? "") : nil,
            title: applied.title != nil ? (restoredTags.title ?? "") : nil,
            album: applied.album != nil ? (restoredTags.album ?? "") : nil,
            // Year rides only on the file tag. Restore the file's real
            // pre-match year; if the match added one where none existed
            // (previousFileYear == nil), clear the frame outright.
            year: forwardWroteYear ? applied.previousFileYear : nil,
            clearFileYear: forwardWroteYear && applied.previousFileYear == nil
        )
        return (eventId, seratoWrites)
    }

    private static func insertEvent<ForwardPayload: Encodable, InversePayload: Encodable>(
        batchId: String,
        timestamp: Int64,
        fileId: Int64?,
        trackId: Int64? = nil,
        eventType: EventType,
        forwardPayload: ForwardPayload,
        inversePayload: InversePayload,
        in db: GRDB.Database
    ) throws -> Int64 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let forwardJsonData = try encoder.encode(forwardPayload)
        let inverseJsonData = try encoder.encode(inversePayload)

        guard let forwardJsonString = String(data: forwardJsonData, encoding: .utf8),
              let inverseJsonString = String(data: inverseJsonData, encoding: .utf8) else {
            throw OperationEngineError.payloadEncodingFailed
        }

        var event = EventRecord(
            batchId: batchId,
            timestamp: timestamp,
            fileId: fileId,
            trackId: trackId,
            eventType: eventType,
            payloadJson: forwardJsonString,
            inversePayloadJson: inverseJsonString
        )
        try event.insert(db)
        guard let eventId = event.eventId else {
            throw OperationEngineError.insertDidNotReturnRowId
        }
        return eventId
    }
}

// MARK: - Resync types

/// Result of `resyncSeratoForBatch`. Separates writes that
/// actually hit disk from writes that queued because Serato was
/// running (in-memory only, drain on Serato exit). The UI uses
/// this split to phrase the result honestly — "Re-sync complete"
/// when N actually landed vs "Queued N — quit Serato to apply"
/// when nothing did.
public struct ResyncOutcome: Sendable, Equatable {
    public let appliedCount: Int
    public let queuedCount: Int

    public init(appliedCount: Int, queuedCount: Int) {
        self.appliedCount = appliedCount
        self.queuedCount = queuedCount
    }

    public var totalCount: Int { appliedCount + queuedCount }

    public var summaryMessage: String {
        if totalCount == 0 {
            return "Re-sync inspected the batch — no rename events to replay."
        }
        if queuedCount == 0 {
            return "Re-sync complete — wrote \(appliedCount) rename\(appliedCount == 1 ? "" : "s") to Serato library."
        }
        if appliedCount == 0 {
            return "Re-sync queued \(queuedCount) rename\(queuedCount == 1 ? "" : "s") — Serato is running, quit Serato to apply."
        }
        return "Re-sync wrote \(appliedCount), queued \(queuedCount) (Serato started during the sweep)."
    }
}

// MARK: - Mutation types

public enum TrackMutation: Sendable {
    case indexNewFile(IndexNewFilePayload)
    case renameFile(RenameFilePayload)
    case removeFile(RemoveFilePayload)
    case setMetadata(SetMetadataPayload)
    case commitMetadataToSerato(CommitMetadataToSeratoPayload)
    case addTrackToSerato(AddTrackToSeratoPayload)
    case writeFileTags(WriteFileTagsPayload)
    case trashFile(TrashFilePayload)
    case removeTrackFromSerato(RemoveTrackFromSeratoPayload)
    case removeFileFromCrates(RemoveFileFromCratesPayload)
    case applyMusicBrainzMatch(ApplyMusicBrainzMatchPayload)
    /// Inverse of `applyMusicBrainzMatch`, produced only by
    /// `decodeInverseMutation` during undo. Never constructed by
    /// feature code directly.
    case revertMusicBrainzMatch(RevertMusicBrainzMatchPayload)
}

/// Move the file at `fileId` to the user's Trash via
/// FileManager.trashItem. Reversible only by the user via Finder
/// ("Put Back"); journaled but undoNotSupported in the engine
/// because we can't reliably re-create audio bytes if the user has
/// emptied Trash by the time undo runs.
public struct TrashFilePayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public init(fileId: Int64) { self.fileId = fileId }
}

/// Remove the `otrk` from Serato's database V2 whose `pfil`
/// matches the file's path. Gated by `SeratoWatchdog` — Serato
/// must be closed to avoid the in-memory cache overwriting the
/// disk version on save. Not undoable: re-adding would require
/// reconstructing the otrk's full metadata + analysis (cue points,
/// beatgrid) which we don't carry across the boundary today.
public struct RemoveTrackFromSeratoPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public init(fileId: Int64) { self.fileId = fileId }
}

/// Sweep every `.crate` file in Serato's Subcrates directory and
/// remove the `otrk` whose `ptrk` matches the file's path. Gated
/// by SeratoWatchdog. Not undoable: a follow-up "re-add to original
/// crates" would need to track which crates contained the file
/// before removal, which isn't journaled today.
public struct RemoveFileFromCratesPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public init(fileId: Int64) { self.fileId = fileId }
}

/// Snapshot of the canonical `tracks` row's identity + display fields
/// as they stood immediately before an `applyMusicBrainzMatch`. Filled
/// by the engine at apply time only when the match landed on a
/// pre-existing row; `nil` when the match created the row (undo nulls
/// the row's fields instead of restoring them). Captures every column
/// the mutation may overwrite so undo restores the row exactly.
public struct TrackIdentifiers: Codable, Sendable, Equatable {
    public let acoustID: String?
    public let recordingMBID: String?
    public let releaseMBID: String?
    public let artistMBID: String?
    public let isrc: String?
    public let artist: String?
    public let title: String?
    public let album: String?
    public let year: Int?

    public init(
        acoustID: String?,
        recordingMBID: String?,
        releaseMBID: String?,
        artistMBID: String?,
        isrc: String?,
        artist: String?,
        title: String?,
        album: String?,
        year: Int?
    ) {
        self.acoustID = acoustID
        self.recordingMBID = recordingMBID
        self.releaseMBID = releaseMBID
        self.artistMBID = artistMBID
        self.isrc = isrc
        self.artist = artist
        self.title = title
        self.album = album
        self.year = year
    }
}

/// Writes a confirmed MusicBrainz match: upserts the canonical `tracks`
/// row (keyed by Chromaprint fingerprint — invariant #4), links the
/// file to it, and applies the cherry-picked display fields to the
/// file's Serato snapshot, Serato's `database V2`, and the audio file's
/// tags.
///
/// Identity fields (`acoustID`, `recordingMBID`, `releaseMBID`,
/// `artistMBID`, `isrc`) are ALWAYS written to the track row. Display
/// fields (`artist`, `title`, `album`, `year`) are cherry-picked — a
/// `nil` field is not applied, leaving the prior value in place.
///
/// `year` reaches ONLY the audio file's tags and `tracks.year`;
/// `SeratoMetadata` (and therefore Serato's `database V2`) has no year
/// field, so it is deliberately not threaded through the Serato write.
///
/// The `previous…` fields are populated by the engine at apply time to
/// make the event fully undoable (invariant #2). Callers leave them at
/// their defaults.
public struct ApplyMusicBrainzMatchPayload: Codable, Sendable, Equatable {
    public let fileID: Int64
    // Identity — always applied:
    public let acoustID: String?
    public let recordingMBID: String
    public let releaseMBID: String?
    public let artistMBID: String?
    public let isrc: String?
    public let fingerprintHash: Data
    // Cherry-picked display fields — absent (nil) means not applied:
    public let artist: String?
    public let title: String?
    public let album: String?
    public let year: Int?
    /// The file's actual on-disk year tag before the match, read by the
    /// review UI (`AudioTags.year`) and supplied by the caller. The
    /// engine can't recover it at apply time (`tracks.year` is a
    /// different, often-empty value — invariant #4), so undo depends on
    /// it being threaded through here. Snapshotted into
    /// `previousFileYear` at apply time.
    public let currentFileYear: Int?
    // Previous-state snapshots, filled by the engine at apply time:
    public var previousTrackID: Int64?
    public var previousMetadata: SeratoMetadata?
    public var previousFileTags: SeratoMetadata?
    /// The file's on-disk year immediately before the match (copied from
    /// `currentFileYear` at apply time). Undo restores the file tag to
    /// this value — or clears the year frame when it's nil and the match
    /// added one — independent of the canonical `tracks.year`.
    public var previousFileYear: Int?
    public var previousTrackIdentifiers: TrackIdentifiers?
    public var createdTrackRow: Bool

    public init(
        fileID: Int64,
        acoustID: String?,
        recordingMBID: String,
        releaseMBID: String?,
        artistMBID: String?,
        isrc: String?,
        fingerprintHash: Data,
        artist: String?,
        title: String?,
        album: String?,
        year: Int?,
        currentFileYear: Int? = nil,
        previousTrackID: Int64? = nil,
        previousMetadata: SeratoMetadata? = nil,
        previousFileTags: SeratoMetadata? = nil,
        previousFileYear: Int? = nil,
        previousTrackIdentifiers: TrackIdentifiers? = nil,
        createdTrackRow: Bool = false
    ) {
        self.fileID = fileID
        self.acoustID = acoustID
        self.recordingMBID = recordingMBID
        self.releaseMBID = releaseMBID
        self.artistMBID = artistMBID
        self.isrc = isrc
        self.fingerprintHash = fingerprintHash
        self.artist = artist
        self.title = title
        self.album = album
        self.year = year
        self.currentFileYear = currentFileYear
        self.previousTrackID = previousTrackID
        self.previousMetadata = previousMetadata
        self.previousFileTags = previousFileTags
        self.previousFileYear = previousFileYear
        self.previousTrackIdentifiers = previousTrackIdentifiers
        self.createdTrackRow = createdTrackRow
    }
}

/// Inverse of `applyMusicBrainzMatch`. Wraps the fully-populated
/// forward payload (with its `previous…` snapshots) so the revert can
/// restore prior state exactly, and so redo (undo of the undo) can
/// re-issue the original forward match.
public struct RevertMusicBrainzMatchPayload: Codable, Sendable, Equatable {
    public let applied: ApplyMusicBrainzMatchPayload

    public init(applied: ApplyMusicBrainzMatchPayload) {
        self.applied = applied
    }
}

/// Writes metadata into the audio file's primary tag (ID3v2.4 for
/// MP3, Vorbis comments for FLAC, iTunes atoms for M4A — Lofty
/// dispatches by format). Captures `previousMetadata` so the
/// reverse mutation can rewrite the file's tags back to their
/// prior state, making the event fully undoable.
///
/// Gated by `SeratoWatchdog` the same way Serato library writes
/// are: Serato may have a file mmapped during playback or analysis,
/// and writing tags underneath it can corrupt the read. The
/// pending-writes queue ensures crate-agent's file writes happen
/// only while Serato is closed.
public struct WriteFileTagsPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let metadata: SeratoMetadata
    public let previousMetadata: SeratoMetadata?

    public init(
        fileId: Int64,
        metadata: SeratoMetadata,
        previousMetadata: SeratoMetadata? = nil
    ) {
        self.fileId = fileId
        self.metadata = metadata
        self.previousMetadata = previousMetadata
    }
}

/// Inserts a new otrk entry into Serato's database V2 for the file
/// at `fileId`'s path. Used by the drag-drop import flow — after
/// `indexNewFile` registers the file in crate-agent's DB, this
/// mutation registers it with Serato. Gated by SeratoWatchdog.
public struct AddTrackToSeratoPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let metadata: SeratoMetadata

    public init(fileId: Int64, metadata: SeratoMetadata) {
        self.fileId = fileId
        self.metadata = metadata
    }
}

public struct IndexNewFilePayload: Codable, Sendable, Equatable {
    public let path: String
    public let volumeUuid: String
    public let inode: Int64
    public let fileSize: Int64
    public let mtime: Int64
    public let lightweightHash: Data?
    public let bitrateKbps: Int?
    public let metadata: SeratoMetadata

    public init(
        path: String,
        volumeUuid: String,
        inode: Int64,
        fileSize: Int64,
        mtime: Int64,
        lightweightHash: Data? = nil,
        bitrateKbps: Int? = nil,
        metadata: SeratoMetadata = .empty
    ) {
        self.path = path
        self.volumeUuid = volumeUuid
        self.inode = inode
        self.fileSize = fileSize
        self.mtime = mtime
        self.lightweightHash = lightweightHash
        self.bitrateKbps = bitrateKbps
        self.metadata = metadata
    }
}

/// Mirror of Serato's per-track metadata. Stored as strings even
/// for numeric-ish fields (`bpm`, `length`) because Serato stores
/// them that way ("128.000", "03:24") — round-trip lossless.
public struct SeratoMetadata: Codable, Sendable, Equatable, Hashable {
    public var artist: String?
    public var title: String?
    public var album: String?
    public var genre: String?
    public var bpm: String?
    public var musicalKey: String?
    public var comment: String?
    public var length: String?
    public var label: String?

    public init(
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        bpm: String? = nil,
        musicalKey: String? = nil,
        comment: String? = nil,
        length: String? = nil,
        label: String? = nil
    ) {
        self.artist = artist
        self.title = title
        self.album = album
        self.genre = genre
        self.bpm = bpm
        self.musicalKey = musicalKey
        self.comment = comment
        self.length = length
        self.label = label
    }

    public static let empty = SeratoMetadata()
}

public struct SetMetadataPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let metadata: SeratoMetadata
    /// Engine populates this at apply time from the row's current
    /// state. Callers pass `.empty` for forward invocation; the
    /// engine swaps it for the real previous values before journaling.
    public let previousMetadata: SeratoMetadata

    public init(
        fileId: Int64,
        metadata: SeratoMetadata,
        previousMetadata: SeratoMetadata = .empty
    ) {
        self.fileId = fileId
        self.metadata = metadata
        self.previousMetadata = previousMetadata
    }
}

/// Writes the specified metadata fields into Serato's `database V2`
/// for the file. Does NOT touch crate-agent's DB (the caller should
/// have already run `setMetadata` first). Gated by SeratoWatchdog —
/// queued while Serato is running, applied when Serato exits.
///
/// Typically batched with a `setMetadata` mutation under the same
/// batch_id when the user edits metadata in crate-agent's UI: the
/// setMetadata updates crate-agent's snapshot, the
/// commitMetadataToSerato propagates the change to Serato.
///
/// `previousMetadata` carries the values Serato held immediately
/// before this commit, supplied by the caller (the apply path
/// can't read Serato's state — it would race with Serato's own
/// writes). Non-nil here makes the event undoable: the inverse
/// re-issues the commit with `previousMetadata` swapped in for
/// `metadata`. Callers that don't know the previous state pass nil
/// and forfeit undo for this event.
public struct CommitMetadataToSeratoPayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let metadata: SeratoMetadata
    public let previousMetadata: SeratoMetadata?

    public init(
        fileId: Int64,
        metadata: SeratoMetadata,
        previousMetadata: SeratoMetadata? = nil
    ) {
        self.fileId = fileId
        self.metadata = metadata
        self.previousMetadata = previousMetadata
    }
}

public struct RenameFilePayload: Codable, Sendable, Equatable {
    public let fileId: Int64
    public let newPath: String
    public let previousPath: String
    /// Cross-volume rename: when the file moved to a different volume,
    /// its `inode` and `volume_uuid` change. nil means same-volume
    /// rename (engine leaves the identity fields alone). Engine fills
    /// in `previousVolumeUuid` / `previousInode` from the existing
    /// row at apply time — callers pass nil for those.
    public let newVolumeUuid: String?
    public let newInode: Int64?
    public let previousVolumeUuid: String?
    public let previousInode: Int64?

    public init(
        fileId: Int64,
        newPath: String,
        previousPath: String = "",
        newVolumeUuid: String? = nil,
        newInode: Int64? = nil,
        previousVolumeUuid: String? = nil,
        previousInode: Int64? = nil
    ) {
        self.fileId = fileId
        self.newPath = newPath
        self.previousPath = previousPath
        self.newVolumeUuid = newVolumeUuid
        self.newInode = newInode
        self.previousVolumeUuid = previousVolumeUuid
        self.previousInode = previousInode
    }
}

public struct RemoveFilePayload: Codable, Sendable, Equatable {
    public let fileId: Int64

    public init(fileId: Int64) {
        self.fileId = fileId
    }
}

// MARK: - Queue types

/// A write that's deferred while Serato is running. Originally
/// only Serato library files (`.crate`, `database V2`); SP-1.5
/// expanded the queue to also gate audio-file tag writes, because
/// Serato may have audio files mmapped during playback or analysis
/// and writing tags underneath could corrupt the read.
enum SeratoPendingWrite: Sendable, Equatable {
    case rename(SeratoPendingRename)
    case metadataUpdate(SeratoPendingMetadataUpdate)
    case addTrack(SeratoPendingAddTrack)
    case fileTagWrite(SeratoPendingFileTagWrite)
    case removeFromDatabase(SeratoPendingRemoval)
    case removeFromCrates(SeratoPendingRemoval)
    case trashFile(SeratoPendingTrash)
}

/// Queued removal of a file's references from Serato. Same payload
/// for database V2 (`.removeFromDatabase`) and `.crate` sweep
/// (`.removeFromCrates`) — both need just the absolute path.
struct SeratoPendingRemoval: Sendable, Equatable {
    let absolutePath: String
}

/// Queued trash-move. Routed through the SeratoWatchdog gate
/// because Serato may have the file open for playback or analysis;
/// moving a file out from under Serato can crash it or corrupt
/// in-flight reads.
struct SeratoPendingTrash: Sendable, Equatable {
    let absolutePath: String
}

/// File-tag write deferred by the SeratoWatchdog. Carries the
/// absolute path resolved from the FileRecord plus the metadata
/// snapshot to write.
struct SeratoPendingFileTagWrite: Sendable, Equatable {
    let absolutePath: String
    let metadata: SeratoMetadata
    /// Year to write into the audio file's tags. Lives here rather than
    /// on `SeratoMetadata` because Serato's `database V2` has no year
    /// field — only the file-tag path carries it. `nil` for callers
    /// that don't set a year (e.g. `writeFileTags`).
    let year: Int?
    /// Remove the file's year/date frame instead of writing a value.
    /// Used by MusicBrainz undo when the match added a year to a file
    /// that had none: `year: nil` alone would leave the added value in
    /// place (nil = leave-unchanged), so the clear must be explicit.
    let clearYear: Bool

    init(absolutePath: String, metadata: SeratoMetadata, year: Int? = nil, clearYear: Bool = false) {
        self.absolutePath = absolutePath
        self.metadata = metadata
        self.year = year
        self.clearYear = clearYear
    }
}

/// A Serato-side rewrite scheduled by `renameFile`. Carries absolute
/// paths; the rename application converts them to the Serato-relative
/// form (`/Users/x/Music/...` → `Users/x/Music/...`) before calling
/// the FFI rewrite functions.
struct SeratoPendingRename: Sendable, Equatable {
    let oldAbsolutePath: String
    let newAbsolutePath: String
}

/// A Serato-side metadata update scheduled by
/// `commitMetadataToSerato`. Carries the absolute path of the file
/// and the new metadata to write into Serato's `database V2`.
struct SeratoPendingMetadataUpdate: Sendable, Equatable {
    let absolutePath: String
    let metadata: SeratoMetadata
}

/// A Serato-side track-insert scheduled by `addTrackToSerato`.
/// Carries the file's absolute path plus the metadata to embed in
/// the new otrk entry.
struct SeratoPendingAddTrack: Sendable, Equatable {
    let absolutePath: String
    let metadata: SeratoMetadata
}

// MARK: - Errors

public enum OperationEngineError: LocalizedError, Equatable {
    case fileNotFound(fileId: Int64)
    case insertDidNotReturnRowId
    case payloadEncodingFailed
    case seratoEnumerationFailed(directory: String, underlying: String)
    case seratoRewriteFailed(path: String, underlying: String)
    case fileTagWriteFailed(path: String, underlying: String)
    case trashFailed(path: String, underlying: String)
    case batchNotFound(batchId: String)
    case undoNotSupported(eventType: EventType)
    case missingPreviousTrackIdentifiers(fileId: Int64)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let fileId):
            return "Mutation referenced file id \(fileId), which is not in the database."
        case .insertDidNotReturnRowId:
            return "Database insert did not produce a row id — schema or driver invariant broken."
        case .payloadEncodingFailed:
            return "Could not encode mutation payload as UTF-8 JSON."
        case .seratoEnumerationFailed(let directory, let underlying):
            return "Failed to enumerate Serato crate files in \(directory): \(underlying)"
        case .seratoRewriteFailed(let path, let underlying):
            return "Failed to rewrite Serato library file \(path): \(underlying)"
        case .fileTagWriteFailed(let path, let underlying):
            return "Failed to write audio tags to \(path): \(underlying)"
        case .trashFailed(let path, let underlying):
            return "Failed to move \(path) to Trash: \(underlying)"
        case .batchNotFound(let batchId):
            return "No events were found for batch \(batchId); nothing to undo."
        case .undoNotSupported(let eventType):
            return "Events of type \(eventType.rawValue) can't be undone yet."
        case .missingPreviousTrackIdentifiers(let fileId):
            return "Cannot revert MusicBrainz match for file id \(fileId): the pre-existing track row has no previous identifiers snapshot to restore."
        }
    }
}
