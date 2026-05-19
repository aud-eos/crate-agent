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
        }
    ) {
        self.database = database
        self.seratoWatchdog = seratoWatchdog
        self.seratoLocator = seratoLocator
        self.fileTagWriter = fileTagWriter
        self.fileTrasher = fileTrasher
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

        if let pendingWrite = executionResult.seratoWrite {
            let isSeratoRunning = await seratoWatchdog.isSeratoRunning
            if isSeratoRunning {
                pendingSeratoWrites.append(pendingWrite)
                queueDepthSubject.send(pendingSeratoWrites.count)
            } else {
                try await applySeratoWrite(pendingWrite)
            }
        }

        return executionResult.eventId
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
        for inverseMutation in inverseMutations {
            _ = try await apply(inverseMutation, batchId: undoBatchId)
        }
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
        let crateFiles: [URL]
        do {
            crateFiles = try seratoLocator.enumerateCrateFiles()
        } catch {
            throw OperationEngineError.seratoEnumerationFailed(
                directory: seratoLocator.subcratesDirectoryUrl.path,
                underlying: String(describing: error)
            )
        }
        for crateFile in crateFiles {
            do {
                _ = try removePathFromCrate(
                    cratePath: crateFile.path,
                    trackPath: seratoRelativePath
                )
            } catch {
                throw OperationEngineError.seratoRewriteFailed(
                    path: crateFile.path,
                    underlying: String(describing: error)
                )
            }
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
            label: write.metadata.label
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

        let crateFiles: [URL]
        do {
            crateFiles = try seratoLocator.enumerateCrateFiles()
        } catch {
            throw OperationEngineError.seratoEnumerationFailed(
                directory: seratoLocator.subcratesDirectoryUrl.path,
                underlying: String(describing: error)
            )
        }

        for crateFile in crateFiles {
            do {
                _ = try rewriteCratePath(
                    cratePath: crateFile.path,
                    oldPath: oldSeratoPath,
                    newPath: newSeratoPath
                )
            } catch {
                throw OperationEngineError.seratoRewriteFailed(
                    path: crateFile.path,
                    underlying: String(describing: error)
                )
            }
        }

        let databaseV2Path = seratoLocator.databaseV2Url.path
        if FileManager.default.fileExists(atPath: databaseV2Path) {
            do {
                _ = try rewriteDatabasePath(
                    databasePath: databaseV2Path,
                    oldPath: oldSeratoPath,
                    newPath: newSeratoPath
                )
            } catch {
                throw OperationEngineError.seratoRewriteFailed(
                    path: databaseV2Path,
                    underlying: String(describing: error)
                )
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
        let seratoWrite: SeratoPendingWrite?
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
            return ExecutionResult(eventId: eventId, seratoWrite: nil)
        case .renameFile(let payload):
            let (eventId, seratoRename) = try applyRenameFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrite: .rename(seratoRename)
            )
        case .removeFile(let payload):
            let eventId = try applyRemoveFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrite: nil)
        case .setMetadata(let payload):
            let eventId = try applySetMetadata(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrite: nil)
        case .commitMetadataToSerato(let payload):
            let (eventId, seratoUpdate) = try applyCommitMetadataToSerato(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrite: .metadataUpdate(seratoUpdate)
            )
        case .addTrackToSerato(let payload):
            let (eventId, seratoAdd) = try applyAddTrackToSerato(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrite: .addTrack(seratoAdd)
            )
        case .writeFileTags(let payload):
            let (eventId, fileTagWrite) = try applyWriteFileTags(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrite: .fileTagWrite(fileTagWrite)
            )
        case .trashFile(let payload):
            let (eventId, trash) = try applyTrashFile(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(eventId: eventId, seratoWrite: .trashFile(trash))
        case .removeTrackFromSerato(let payload):
            let (eventId, removal) = try applyRemoveTrackFromSerato(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrite: .removeFromDatabase(removal)
            )
        case .removeFileFromCrates(let payload):
            let (eventId, removal) = try applyRemoveFileFromCrates(
                payload, batchId: batchId, timestamp: timestampMillis, in: db
            )
            return ExecutionResult(
                eventId: eventId,
                seratoWrite: .removeFromCrates(removal)
            )
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
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileTrashed,
            forwardPayload: forwardPayload,
            inversePayload: forwardPayload,
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
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .trackRemovedFromSerato,
            forwardPayload: forwardPayload,
            inversePayload: forwardPayload,
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
        let eventId = try insertEvent(
            batchId: batchId,
            timestamp: timestamp,
            fileId: payload.fileId,
            eventType: .fileRemovedFromCrates,
            forwardPayload: forwardPayload,
            inversePayload: forwardPayload,
            in: db
        )
        let pending = SeratoPendingRemoval(absolutePath: fileRecord.path)
        return (eventId, pending)
    }

    private static func insertEvent<ForwardPayload: Encodable, InversePayload: Encodable>(
        batchId: String,
        timestamp: Int64,
        fileId: Int64?,
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
            trackId: nil,
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
        }
    }
}
