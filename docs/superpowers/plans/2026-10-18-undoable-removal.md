# Undoable Removal Implementation Plan (Library readiness, phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make removing a track fully undoable from History, restoring the file from the Trash, its exact V2 record, and its exact position in every crate and SmartCrate cache. Then expose a keeper-less "remove this file" entry point that Duplicates cleanup and later filler removal both use.

**Architecture:**
- The Rust core gains capture and restore: removing records returns the removed TLV bytes with their indices, and restore reinserts them at those indices idempotently.
- The removal I/O stores those captures, and the Trash destination, in the database in the same transaction that completes the queue row. The journaled events stay append-only, and their inverse payloads point at the captures.
- Undo replays the inverses in reverse order: re-index the row, move the file back from the Trash, then restore the crate and V2 records. All Serato writes stay queued and gated.

**Tech Stack:** Swift 6 / SwiftUI, GRDB, Rust core over UniFFI (`rust-core/src/crate-agent-core.udl`, `ffi.rs`, `serato.rs`), XCTest, `cargo test`.

**Spec:** `docs/superpowers/specs/2026-10-17-library-readiness-design.md`, Goal 6 and the anti-goals.

## Global Constraints

- **Invariant 1:** every state change is a `TrackMutation` through `OperationEngine`, with a complete `SeratoConflictTargets.mutation` projection (every current, previous, destination and reference path) and recheck inside the serialized transaction.
- **Invariant 2:** every event has `payload_json` and `inverse_payload_json`; the `events` table stays append-only.
- **Invariant 3:** no write to V2, Subcrates or SmartCrates while Serato runs. Undo's restores queue like any other write, and every crate-shaped file is round-tripped via `SeratoLibraryLocator.enumerateCrateFiles()`.
- **Invariant 4:** physical I/O verifies its target matches the authorized identity (`SeratoWriteEligibility.requirePhysicalTarget`, `FileTrashLocation`).
- **Migrations:** schema only, using the next free migration id at implementation time. On main, 014–018, 020, 021, 023 and 024 are taken; 022 is PR 236 and 025 may be #95.
- **Tests:** fewest that give confidence; each must fail first on its assertion. No lint suppressions, no `as` casts that bypass checking, descriptive names, no chevrons in UI.
- **Copy:** strings used more than once go in `CrateAgent/Constants/`.

## Review Focus

1. **Trash emptied, or the item replaced, before undo:** undo refuses before changing anything, and names the file. (Task 4 test)
2. **Original path now occupied:** another file was put at the old path. The restore refuses rather than overwrite. (Task 4 test)
3. **Serato running at undo time:** the file comes back immediately, the V2 and crate restores queue and land after Serato quits, and History shows them pending. (Task 4 test)
4. **A crate was deleted or rewritten since the removal:** a deleted crate is skipped and reported as not applied. An index past the end appends. Nothing duplicates if the path is already present. (Task 1 test)
5. **Undo of a half-finished cleanup:** removal is queued but not yet run while Serato runs. Undo drops the queued rows, with nothing to restore. (Task 4 test)

---

### Task 1: Capture and restore records in the Rust core

**Files:**
- Modify: `rust-core/src/serato.rs`: `remove_otrks_referencing_path` (≈477), `CrateFile::remove_track` (≈694), `DatabaseV2::remove_track` (≈841)
- Modify: `rust-core/src/crate-agent-core.udl`, `rust-core/src/ffi.rs` (next to `remove_track_from_database` ≈292 and `remove_path_from_crate` ≈305)
- Test: `rust-core/src/serato.rs` `#[cfg(test)]` module

**Interfaces:**
- Produces (UDL):
  - `dictionary SeratoRemovedRecord { u32 index; bytes record; };`
    - `record` is the full TLV encoding (`otrk` tag, length, payload).
    - `index` is the record's position among all top-level records before removal.
  - `sequence<SeratoRemovedRecord> remove_track_from_database_capturing(string database_path, string track_path);`
  - `sequence<SeratoRemovedRecord> remove_path_from_crate_capturing(string crate_path, string track_path);`
  - `u32 restore_removed_records(string file_path, string track_path, sequence<SeratoRemovedRecord> records);`
    - Returns the number reinserted.
    - Works for V2 (`pfil`), `.crate` and `.scrate` (`ptrk`), choosing the path tag the same way the remove functions do.
- The existing `remove_track_from_database` and `remove_path_from_crate` become thin wrappers that return the capture count. Keep their signatures so the other callers still compile.

- [ ] **Step 1: Write the failing tests**
  - `capture_then_restore_round_trips_crate_bytes`:
    - A crate `vrsn, otrk(a), otrk(b), otrk(c)`.
    - Removing `b` returns one record with `index == 2`.
    - After restore, the file bytes equal the original exactly.
  - `capture_then_restore_round_trips_database_v2_bytes`: the same check for V2, using a record carrying metadata fields, not just `pfil`.
  - `restore_skips_paths_already_present_and_appends_past_end`:
    - Restoring when `b` is already present reinserts 0 records and leaves the bytes unchanged.
    - Restoring an `index` greater than the record count appends at the end.
  - `restore_inserts_multiple_records_at_their_original_indices`: records are inserted in ascending `index` order.
- [ ] **Step 2:** `cargo test --manifest-path rust-core/Cargo.toml capture_then_restore`. Expected: FAIL to compile, because the functions don't exist.
- [ ] **Step 3: Implement.**
  - `remove_otrks_referencing_path` returns `Vec<(usize, TlvRecord)>` and is still order-preserving.
  - Restore checks whether the path is already held using the existing `PathKeys` / `otrk_has_path_in`.
  - Writes go through `replace_file`.
- [ ] **Step 4:** run the full `cargo test --manifest-path rust-core/Cargo.toml`. Expected: PASS. Then `make build-rust`.
- [ ] **Step 5: Commit:** "Capture removed Serato records with their positions and restore them exactly".

### Task 2: Persist captures and the Trash destination at I/O time

**Files:**
- Create: `CrateAgent/Database/Migrations/AddSeratoRemovalCapturesMigration.swift`. Register it in `Database.swift`'s migrator list, after the last entry.
- Create: `CrateAgent/Services/SeratoRemovalCaptureStore.swift`
- Modify: `CrateAgent/Services/OperationEngine.swift`:
  - `applySeratoDatabaseRemoval` (≈2747) and `applySeratoCrateSweepRemoval` (≈2777) call the `_capturing` FFI.
  - `applyTrashFileOperation` (≈2724) records the Trash destination.
  - `FileTrasher` (≈66, default ≈150) changes type.
- Test: `CrateAgentTests/UndoableRemovalTests.swift` (new). Reuse `SeratoRemovalFixture`, `ConfirmedDuplicateGroup` and the `saveCrates` helper pattern from `DurableSeratoQueueTests`.

**Interfaces:**
- Produces:
  - Table `serato_removal_captures(event_id INTEGER NOT NULL, store_path BLOB NOT NULL, track_path BLOB NOT NULL, records BLOB NOT NULL, captured_at INTEGER NOT NULL, PRIMARY KEY (event_id, store_path))`.
    - `store_path` is the V2 or crate file.
    - `records` is the JSON-encoded `[SeratoRemovedRecord]`.
  - `enum SeratoRemovalCaptureStore`:
    - `static func save(eventID: Int64, storePath: String, trackPath: String, records: [SeratoRemovedRecord], in: Database) throws`
    - `static func captures(eventID: Int64, in: Database) throws -> [SeratoRemovalCapture]`
    - `struct SeratoRemovalCapture: Sendable { let storePath: String; let trackPath: String; let records: [SeratoRemovedRecord] }`
  - `public typealias FileTrasher = @Sendable (String) throws -> String`:
    - It returns the resulting Trash path.
    - The default uses `trashItem(at:resultingItemURL:)` and returns the resulting URL's path.
    - Test trashers in the existing fixtures return their destination.
  - Table `removal_trash_destinations(event_id INTEGER PRIMARY KEY, original_path BLOB NOT NULL, trash_identity BLOB NOT NULL)`. It is keyed by the `.fileTrashed` event id, not the file id, because `file_trash_locations` rows are tied to the file row that `.removeFile` deletes.
    - `trash_identity` is the JSON-encoded `FileMetadata` from `FileTrashLocation.capture(at:for:)`.
    - `applyTrashFileOperation` saves it in the same transaction as `.removeFile`.
  - `SeratoRemovalCaptureStore` also provides `static func saveTrashDestination(eventID: Int64, originalPath: String, identity: FileMetadata, in: Database) throws` and `static func trashDestination(eventID: Int64, in: Database) throws -> (originalPath: String, identity: FileMetadata)?`.
- Captures are saved in the same `database.writer.write` that completes the queue row, so a crash can't leave a landed removal with no capture. If a removal removed 0 records, nothing is saved.

- [ ] **Step 1: Write the failing test** `testCleanupRecordsEveryRemovedRecordAndTheTrashDestination`:
  - Duplicate-clean a file that's in V2, `owned.crate` and `owned.scrate`.
  - Assert three captures for the `.trackRemovedFromSerato` and `.fileRemovedFromCrates` events, one per store path.
  - Each capture's records, restored with `restoreRemovedRecords` into the post-removal bytes, reproduce the pre-removal bytes exactly.
  - `SeratoRemovalCaptureStore.trashDestination(eventID:)` for the `.fileTrashed` event names the actual Trash item, and it is still present after `.removeFile` deletes the row.
- [ ] **Step 2:** run `xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent -configuration Test -derivedDataPath build-output/DerivedData -only-testing:CrateAgentTests/UndoableRemovalTests test`. Expected: FAIL, with no captures.
- [ ] **Step 3: Implement** the migration, the store, the FFI switch and the trasher type change.
- [ ] **Step 4:** run the same command, plus `-only-testing:CrateAgentTests/DurableSeratoQueueTests -only-testing:CrateAgentTests/FinalRemovalIntegrationTests`. Expected: PASS.
- [ ] **Step 5: Commit:** "Record removed Serato records and the Trash destination when a removal lands".

### Task 3: Inverse mutations: restore from the Trash, and restore Serato records

**Files:**
- Modify: `CrateAgent/Services/OperationEngine.swift`:
  - `TrackMutation` (≈4378) gains `restoreFromTrash(RestoreFromTrashPayload)` and `restoreSeratoRecords(RestoreSeratoRecordsPayload)`.
  - The `NonUndoableInverse` for the three removal events is replaced.
  - `decodeInverseMutation` (≈1889, branch ≈1936) handles them.
  - `SeratoPendingWrite` gains `.restoreRecords(SeratoPendingRestore)`.
- Modify: `CrateAgent/Services/SeratoConflictTargets.swift`. Add the new mutation and write cases, naming the original path, the Trash path and the file identity.
- Modify: `CrateAgent/Services/SeratoWriteEligibility.swift`. `permits` allows `.restoreRecords` only for a row that is `.active` and `.available` at its original path.
- Modify: `CrateAgent/Services/SeratoWriteQueue.swift`. Add a `SeratoWriteKind.restoreRecords`, with `writesSeratoLibrary == true`.
- Modify: `CrateAgent/Models/EventRecord.swift`. Add `fileRestoredFromTrash = "file_restored_from_trash"` and `seratoRecordsRestored = "serato_records_restored"`, and update the exhaustive switches.

**Interfaces:**
- Produces:
  - `public struct RestoreFromTrashPayload: Codable, Sendable, Equatable { public let originalPath: String; public let identity: FileMetadata; public let removalEventID: Int64 }`
    - Apply loads `SeratoRemovalCaptureStore.trashDestination(eventID: removalEventID)`.
    - It verifies the item with `FileTrashLocation.availability(of:resolver:)`.
    - It refuses if `originalPath` exists.
    - It moves the item inside the undo's `PhysicalFileMoveTransaction`, then sets the re-indexed row to `.available`.
  - `public struct RestoreSeratoRecordsPayload: Codable, Sendable, Equatable { public let removalEventID: Int64; public let trackPath: String }`
    - Apply queues one `.restoreRecords` write per capture of `removalEventID`.
    - The write calls `restoreRemovedRecords(filePath: capture.storePath, trackPath:, records:)`.
    - A capture whose `store_path` no longer exists is recorded as a not-applied disposition, with a detail message in `CrateAgent/Constants/`, and the rest continue.
  - Forward events journal `removalEventID` in their inverse, so `inverse_payload_json` stays immutable. Undo reads the captures by event id.
  - Inverses of the restore events are removals by the same path. The redo path runs the existing removal mutations.

- [ ] **Step 1: Write the failing tests** in `UndoableRemovalTests`:
  - `testUndoRestoresTheFileAndExactSeratoBytes`:
    - Duplicate-clean a file, then `undoBatch`.
    - The file is back at its path with an identical identity.
    - V2, `owned.crate` and `owned.scrate` are byte-identical to before the removal.
    - The row is `.active` and `.available`.
  - `testUndoQueuesSeratoRestoresWhileSeratoRuns`:
    - The same flow with Serato running at undo.
    - The file returns at once, and the V2 and crate bytes are unchanged until Serato quits and `drainPendingSeratoUpdates()` runs.
    - Then they're byte-identical.
- [ ] **Step 2:** run the `UndoableRemovalTests` command. Expected: FAIL with `undoNotSupported`.
- [ ] **Step 3: Implement** the cases, the projections, eligibility, the queue kind and the event types.
  - In undo, `removeFile`'s inverse `indexNewFile` runs first and creates a new file id.
  - The restore payloads are path- and identity-based, so they don't depend on the old id.
- [ ] **Step 4:** run `UndoableRemovalTests`, `RetiredFileWriteGuardTests` (update `testEveryQueuedVariantIsFencedAcrossRetirementAndReadd` to include `.restoreRecords`) and `DuplicateResolverTests`. Expected: PASS, except `testResolveBatchIsNotUndoable`, which Task 5 deletes.
- [ ] **Step 5: Commit:** "Undo a removal by restoring the file from Trash and its exact Serato records".

### Task 4: Undo refuses safely

**Files:**
- Modify: `CrateAgent/Services/OperationEngine.swift`, `undoBatch` (≈1658). Pre-validate all `restoreFromTrash` targets before any mutation, alongside the existing pre-decode.
- Modify: `OperationEngineError` (≈4974). Add `case restoreBlocked(path: String, reason: RestoreBlockReason)` with `enum RestoreBlockReason: Sendable { case trashItemMissing, trashItemChanged, originalPathOccupied }`, plus `LocalizedError` text in `CrateAgent/Constants/`.
- Test: `UndoableRemovalTests`

- [ ] **Step 1: Write the failing tests:**
  - `testUndoRefusesWhenTheTrashItemIsGoneAndChangesNothing`:
    - Empty the item from the Trash.
    - `undoBatch` throws `.restoreBlocked(path:, reason: .trashItemMissing)`.
    - There is no row, no V2 or crate change, and no new event.
  - `testUndoRefusesWhenTheOriginalPathIsOccupied`: write a different file at the original path. Undo throws `.originalPathOccupied`, and that file is untouched.
  - `testUndoOfAQueuedCleanupDropsItsPendingRows`:
    - Run cleanup while Serato runs, so nothing has landed, then undo.
    - The queue has no rows for that file, and V2, the crates and the file are unchanged.
- [ ] **Step 2:** run them. Expected: FAIL.
- [ ] **Step 3: Implement** the pre-validation and the error. Queued, unlanded removal rows are dropped through the existing `dropQueuedWrite` path.
- [ ] **Step 4:** run `UndoableRemovalTests`. Expected: PASS.
- [ ] **Step 5: Commit:** "Refuse a removal undo up front when its file can't be restored".

### Task 5: Keeper-less removal entry point, History and copy

**Files:**
- Modify: `CrateAgent/Services/DuplicateCleanupIntent.swift`:
  - `PendingDuplicateCleanup` becomes `PendingFileRemoval`, with `let authority: RemovalAuthority`.
  - `enum RemovalAuthority: Codable, Sendable, Equatable { case duplicateOf(FileActionAuthority, DuplicateEvidenceRequirement); case ownerChoice }`
  - Keep decoding the saved `duplicate_cleanup_intents` payload shape, and decode an old row as `.duplicateOf`.
- Modify: `CrateAgent/Services/OperationEngine.swift`:
  - Add `public func removeFile(target: FileRecord, batchID: String) async throws -> FileRemovalResult`.
  - `resolveDuplicate` calls the same `advanceFileRemoval` with `.duplicateOf`.
  - Rename `DuplicateCleanupResult` to `FileRemovalResult`.
  - `GuardedSeratoWrite.isOrphanedCleanup` (`SeratoWriteEligibility.swift` ≈192) checks that an intent exists, not that a keeper does.
- Modify: `CrateAgent/Services/EventHistoryQuery.swift`. Remove the three removal types from `canUndoBatch`'s `unsupportedRaw` (≈240), and add phrases for the two restore types.
- Modify: `CrateAgent/Views/Cleanup/DuplicatesPanel.swift`. Lines ≈144, 155 and 188 become "You can undo this from History while the file is still in the Trash."
- Modify: the doc comments on `DuplicateResolver.swift` (lines 3–26) and the three removal payloads.
- Modify: `docs/serato-membership-reconciliation.md`, and the README section on Duplicates.
- Test: `UndoableRemovalTests`, `DuplicateResolverTests`

- [ ] **Step 1: Write the failing test** `testRemovingAFileWithoutAKeeperIsUndoable`:
  - `removeFile(target:batchID:)` on a file that is in V2 and both crates.
  - The file is in the Trash, and gone from V2 and the crates.
  - `undoBatch` restores the bytes and the file exactly.
  - History's `BatchSummary.canUndo` is true for the batch.
- [ ] **Step 2:** run it. Expected: FAIL to compile, because `removeFile` doesn't exist.
- [ ] **Step 3: Implement.** Delete `testResolveBatchIsNotUndoable`, which `testUndoRestoresTheFileAndExactSeratoBytes` replaces.
- [ ] **Step 4: Verify:**
  - `make lint` and `make format-check` pass.
  - `cargo test --manifest-path rust-core/Cargo.toml` passes.
  - The full `make test-swift` passes.
- [ ] **Step 5: Commit:** "Remove a file without a keeper, undoable from History". Then push and open the PR.
