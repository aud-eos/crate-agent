# Serato Removal Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Respect Serato library removals without losing history, deleting audio, or allowing stale work to restore removed entries.

**Architecture:** Persist library membership independently from file availability. A strict saved-library snapshot drives journaled retirement/reactivation through OperationEngine. Shared eligibility and revision checks protect UI actions, background completion, and external-write execution.

**Tech Stack:** Swift 5.10, SwiftUI, GRDB/SQLite, Rust, existing UniFFI bindings, XCTest, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-09-14-serato-removal-sync-design.md`

## Global Constraints

- Retirement preserves the file row, recording link, fingerprint, and event history.
- It never deletes, moves, restores, or re-imports audio.
- Filesystem observations alone are never proof that Serato membership was removed.
- Removing one file does not retire sibling files sharing its track_id.
- All membership and availability changes go through OperationEngine with forward and inverse events.
- No real AppServices boot, live-library mutation, normal hosted test run, secret-file access, or application launch during verification.
- No new dependencies or portable-library subsystem. Keep main untouched; work in `feature/serato-removal-sync`.
- Do not reuse the deleting `removeFile` mutation for retirement.
- Reuse current values and applicable intent, never historical event counts, as current-state evidence.
- Independent GPT-6 Astra review before the implementation PR; no merge without the user.

## Delivery and testing conventions

These tasks implement one coupled lifecycle change. Commit each tested component,
but do not enable automatic retirement in AppServices until guards and query
filtering are complete. Open one integrated PR after the final gate. Keep the
existing shared-row undo redesign and durable-queue issues separate; membership
guards must integrate without pretending those issues are solved.

Use the isolated framework/XCTest approach from PR #121: compile production
sources as a test-only framework named CrateAgent, exclude the application @main
entry, set TEST_HOST/BUNDLE_LOADER empty, and exclude AppLauncherTests. Build a
fresh scratch project at `/private/tmp/serato-removal-tests` referencing THIS
worktree, not the old UI worktree. Reuse the prior scratch harness only after
checking every source path and exclusion. Save construction commands in the
ignored progress ledger so another executor can reproduce them.

The test scheme is `CrateAgentLogic`; generate a project called
`CrateAgentLogic.xcodeproj`. Use this command, adding `-only-testing` for the class
named in each task:

```sh
xcodebuild -project /private/tmp/serato-removal-tests/CrateAgentLogic.xcodeproj -scheme CrateAgentLogic -destination 'platform=macOS' -derivedDataPath /private/tmp/serato-removal-tests/build test
```

For every test cycle: first observe a failing assertion caused by the original
behavior, then implement, then run green. A new missing symbol can establish the
initial red stage, but each final regression must also fail when its production
fix is temporarily removed. Save toggle scripts outside tracked source and restore
in a finally block. Do not commit while a fault is installed.

Use real temporary DBs, real encoded V2/crate bytes, native file moves, and real
Tasks with controlled completion. Stub only unrelated effects. Never stub the
snapshot validator, state guard, or mechanism the test is intended to protect.

## Task 1: Strict library snapshots

**Files:** Modify `rust-core/src/serato.rs`, `rust-core/src/ffi.rs`,
`rust-core/src/crate-agent-core.udl`. Create
`CrateAgent/Services/SeratoMembershipSnapshot.swift` and
`CrateAgentTests/SeratoMembershipSnapshotTests.swift`.

**Interfaces:** Add Rust
`DatabaseV2::strict_track_records(&self) -> Result<Vec<SeratoTrackRecord>, SeratoError>`
and FFI `read_database_records_strict(database_path: String) -> Result<Vec<SeratoTrackRecord>, CoreError>`.
Preserve the existing permissive reader for callers that do not infer absence.

Swift defines `SeratoMembershipSnapshot` with `libraryID: String`,
`records: [SeratoTrackRecord]`, `source: FileFreshnessSnapshot`, and
`generation: UInt64`. `SeratoMembershipSnapshotReader.read() async throws`
returns it, checking source identity before/after parsing and watchdog state.
Define typed failures: sourceUnavailable, malformedSource, sourceChanged,
seratoRunning, and unsupportedSource. Use the configured locator plus source
volume identity to identify the library; changing source must not retire members
owned by another library.

- [ ] Add real-byte Rust cases: version-only empty V2 succeeds; zero bytes,
  truncated TLV, malformed nested otrk, absent/empty pfil, and invalid UTF-16 fail.
  Unknown non-membership fields remain preserved and accepted. Validate lengths
  before allocating TLV payloads; a corrupt length must not allocate gigabytes.

```rust
#[test]
fn strict_membership_rejects_an_otrk_without_a_path() {
    let database = DatabaseV2 {
        records: vec![TlvRecord { tag: *b"otrk", payload: Vec::new() }],
    };
    assert!(database.strict_track_records().is_err());
}
```

- [ ] Run `cargo test --manifest-path rust-core/Cargo.toml -p crate-agent-core strict_membership` and observe red.
- [ ] Implement strict traversal without filter_map/error swallowing; share field
  decoding mechanics with the existing reader. Validate a real version record so
  an empty byte stream cannot be interpreted as an intentionally empty library.
- [ ] Add Swift tests using actual fixture files for missing/empty/corrupt sources,
  watchdog changes, and file replacement during reading. Use nanosecond source
  identity or exact-byte validation if FileFreshnessSnapshot lacks enough precision;
  do not inherit whole-second timestamp limitations for snapshot authority.
- [ ] Regenerate bindings with `./scripts/build-rust.sh`; run targeted Rust and
  SeratoMembershipSnapshotTests green; toggle the strict validation and prove red.
- [ ] Commit `Add strict Serato membership snapshots` with explicit paths.

## Task 2: Preserved file lifecycle state

**Files:** Create `CrateAgent/Models/FileLibraryState.swift`,
`CrateAgent/Database/Migrations/AddFileLibraryStateMigration.swift`,
`CrateAgent/Services/FileLibraryStateMutation.swift`, and
`CrateAgentTests/FileLibraryStateTests.swift`. Modify `FileRecord.swift`,
`EventRecord.swift`, `Database.swift`, `OperationEngine.swift`, and
`EventHistoryQuery.swift` in their existing directories.

**Interfaces:**

```swift
enum LibraryMembership: String, Codable, Sendable {
    case legacyUnverified, active, pendingImport, retired
}
enum FileAvailability: String, Codable, Sendable {
    case unknown, available, missing, trashed, offline, inaccessible
}
struct FileLibraryState: Codable, Equatable, Sendable {
    let membership: LibraryMembership
    let availability: FileAvailability
    let libraryID: String?
    let retiredAt: Int64?
}
struct SetFileLibraryStatePayload: Codable, Sendable {
    let fileId: Int64
    let expectedRevision: Int64
    let state: FileLibraryState
}
```

Persist fields on files as library_membership, file_availability,
serato_library_id, retired_at, and membership_revision. Migration defaults existing
rows to legacyUnverified/unknown/revision 0; does not inspect disk or retire rows.
Add `.setFileLibraryState` mutation and `.fileLibraryStateChanged` event. Revision
increases on membership transitions, explicit new import intent, and confirmed
physical/content replacement (which invalidates cached association and queued
work). Same-file location/availability observations do not advance it.
Task 3's dedicated `.beginFileImport` mutation advances
it even for pending→pending retries, validates file identity, and journals the
audit-only `.fileImportRequested` event with a full prior-state inverse.
Never decrement/reuse a revision when replaying an inverse.

- [ ] Add migration tests that seed pre-migration file/track/event rows and verify
  IDs, fingerprints, relationships, and history remain unchanged.
- [ ] Add mutation tests: retire one of two files sharing a track; assert the same
  file ID and event links survive, only the target retires, and both payloads decode.
  Stale expectedRevision rejects atomically. Repeating identical state creates no event.

```swift
XCTAssertEqual(after.id, before.id)
XCTAssertEqual(after.trackId, before.trackId)
XCTAssertEqual(after.chromaprintFingerprint, before.chromaprintFingerprint)
XCTAssertEqual(after.libraryMembership, .retired)
XCTAssertGreaterThan(after.membershipRevision, before.membershipRevision)
```

- [ ] Run FileLibraryStateTests red, implement the transaction helper with
  OperationEngine dispatch, then green. Keep the large engine's orchestration in
  place; extract only the state mutation mechanic into the new helper.
- [ ] Mark observation-only history batches non-undoable/non-replayable; reject
  mixed undo batches containing observations before any inverse is applied.
  Record inverse payloads for audit integrity without offering an implicit Serato re-add.
- [ ] Toggle retirement to hard deletion, no revision increment, and unconditional
  repeat events separately; verify each regression fails; restore and commit
  `Preserve file history through library membership changes`.

## Task 3: Eligibility and stale external work

**Files:** Create `CrateAgent/Services/FileProcessingEligibility.swift`,
`CrateAgent/Services/SeratoWriteEligibility.swift`,
`CrateAgentTests/RetiredFileWriteGuardTests.swift`. Modify `OperationEngine.swift`,
`ImportCoordinator.swift`, `AutoTagLibraryState.swift`, and existing resync tests.

**Interfaces:** `FileProcessingEligibility.requireProcessable(_ file: FileRecord)
throws`; `FileMembershipToken(fileId: Int64, revision: Int64)`;
`GuardedSeratoWrite(token: FileMembershipToken, write: SeratoPendingWrite)`.
OperationEngine's queue stores guarded writes created from the same DB transaction
that produces their events. Add membership revision to new projection payloads
with backward-compatible decoding. Legacy payloads may be replayed only after
checking current lifecycle state and whether any retirement has invalidated them;
they must never receive a freshly minted token that launders old intent.

- [ ] Use an actual queued metadata change against temporary V2/audio, retire its
  file, then drain. Assert V2/audio bytes are unchanged and outcome reports a
  superseded write. Repeat with retirement followed by reactivation: still blocked.
- [ ] Cover queued add, rename, tag update, removal, and Trash operation. A stale
  removal must not delete a deliberately re-added file's membership. All write
  variants carry identity; none bypasses validation because it lacks a current path.
- [ ] Run RetiredFileWriteGuardTests red. Implement revision checks at apply,
  drain, and History reconstruction. Keep field-level supersession logic intact.
  Explicit new imports enter pendingImport and own a new revision. Do not derive
  permission from an old trackAddedToSerato event's mere existence.
- [ ] Test known retired files reject direct metadata/match/rename processing,
  pending explicit import remains permitted, and History re-sync cannot reactivate.
  Propagate skipped/superseded counts to outcome summaries; do not call them applied.
- [ ] Recheck watchdog before each external write group, and queue the remainder
  if Serato starts. Test with an actual suspended task and controlled watchdog.
- [ ] Toggle revision and state guards independently, verify red, restore all
  existing partial-write/resync tests green, commit `Guard external writes by current membership revision`.

## Task 4: File availability and Trash-aware event handling

**Files:** Create `CrateAgent/Services/FileAvailabilityResolver.swift`,
`CrateAgent/Services/FilesystemEventProcessor.swift`,
`CrateAgentTests/FileAvailabilityResolverTests.swift`, and
`CrateAgentTests/FilesystemEventProcessorTests.swift`. Modify
`FSEventsWatcher.swift`, `FilesystemSyncCoordinator.swift`, and `AppServices.swift`.

**Interfaces:** `FileAvailabilityResolver.inspect(path: String, volumeID: String)
throws -> FileAvailability`; Trash classification uses Foundation volume-aware
Trash URLs and native relationship checks. `FilesystemEventBatch` contains
observations, highestEventID, and requiresReconciliation.
`FilesystemEventProcessor` is an actor with `enqueue(_ batch: FilesystemEventBatch)`
and a single draining loop. Handler is async throws; checkpoint occurs only after
successful processing. A failed head batch blocks advancement of later checkpoints.

- [ ] Build real temp-file tests: rename to another folder, remove file on online
  volume, permission failure, unavailable volume, and directory named "Trash" that
  is not native Trash. For the positive native Trash test, create one uniquely
  named disposable file, trash it via FileManager, inspect the returned URL, then
  remove only that exact fixture. Never enumerate or delete unrelated Trash content.
- [ ] Prove Trash movement does not change the last normal DB path or emit Serato
  rename writes. Restoring a retired fixture updates availability but not membership.
- [ ] Run resolver/event tests red; implement classification and journaled
  availability changes using Task 2. Change coordinator handlers to throw visibly
  instead of logging and advancing on failed DB/mutation operations.
- [ ] Feed two batches to the real processor; suspend the first handler, assert
  no checkpoint and no second handler; fail first, assert neither event ID is
  checkpointed. Retry and verify ordered completion.
- [ ] Parse dropped-event/must-scan flags into requiresReconciliation. Directory
  rename handling schedules one bounded reconciliation request rather than one
  recursive scan per child/event. Task 5 supplies the reconciliation consumer.
- [ ] Toggle early checkpoint and Trash exclusion separately; confirm red and
  restore green. Commit `Respect Trash moves and checkpoint completed filesystem work`.

## Task 5: Membership reconciliation and import/reactivation

**Files:** Create `CrateAgent/Services/SeratoMembershipReconciler.swift` and
`CrateAgentTests/SeratoMembershipReconcilerTests.swift`. Modify
`LibraryScanner.swift`, `ImportCoordinator.swift`, and `FileMetadataCollector.swift`.

**Interfaces:** `ReconciliationSummary(retired: Int, reactivated: Int,
unavailable: Int, skippedUnsupported: Int)`;
`SeratoMembershipReconciler.reconcile(_ snapshot: SeratoMembershipSnapshot)
async throws -> ReconciliationSummary`. Read lightweight identity projections in
batches, compare normalized V2 paths, resolve known pending same-file rename intent,
and apply expected-revision state changes through OperationEngine.

- [ ] Create a reusable `SeratoRemovalFixture` in
  `CrateAgentTests/Support/SeratoRemovalFixture.swift` owning temp V2/crates/audio,
  in-memory DB, real engine, and controllable watchdog. Expose `engine`, `database`,
  `locator`, `reader`, `reconciler`; cleanup only its unique temp directory.
  Reuse existing TLV writers from tests by extracting the mechanic, not copying it.
- [ ] Test the membership matrix against actual decoded V2:
  absent+present audio retires; absent+missing retires; present+missing remains
  active/unavailable; crate-only removal remains active; valid empty V2 retires
  managed online members; source failure and offline/unsupported ownership retire none.
- [ ] Run SeratoMembershipReconcilerTests red, implement deterministic batched
  reconciliation and compare-and-set revisions. Reject stale snapshot generations.
  Scanner accepts a validated snapshot instead of rereading an unrelated version.
- [ ] Test initial legacy rows, successful explicit re-import, failed pending import,
  queued same-file rename, Unicode-equivalent paths, same-path replacement, and
  two files sharing one recording. If replacement identity differs, invalidate
  cached fingerprint/match association through a journaled identity-refresh mutation;
  retain the historical record without applying old audio metadata to new content.
- [ ] Detect ambiguous identity matches and surface them without guessing. A
  file reappearing at a new path must satisfy the existing rename identity contract;
  inability to resolve a move must not silently transfer an unrelated track link.
- [ ] Verify restore-from-Trash without V2 re-add stays retired, while verified V2
  re-add reactivates exactly once. Repeated identical snapshots add zero events.
- [ ] Toggle absent-set subtraction and pending-intent protections separately,
  demonstrate failures, restore green, commit `Reconcile saved Serato library membership`.

## Task 6: Processing and query integration

**Files:** Modify `FingerprintWorker.swift`, `AutoTaggerService.swift`,
`AutoTagSession.swift`, `AutoTagFileBrowse.swift`, `AutoTagFileSearch.swift`,
`LibraryOrganizer.swift`, `LibraryHygiene.swift`, `Models/HygieneFileRow.swift`,
`Views/LibraryBrowserView.swift`, and `Services/FileProcessingEligibility.swift`.
Create `CrateAgentTests/FileEligibilityIntegrationTests.swift`; extend existing
Auto-Tag browse/session and fingerprint persistence tests.

**Interfaces:** Add `FileProcessingEligibility.activeSQL` and
`FileProcessingEligibility.processableSQL` as shared SQL predicates, plus GRDB
request helpers using the same state values. Active browsing includes unavailable
active entries for diagnosis; processing requires active+available. Pending local
imports are displayed with pending status and cannot be auto-processed before
their import/availability is confirmed. Legacy-unverified rows may be displayed
but cannot automatically process before initial reconciliation finishes.

- [ ] Seed active, missing, retired, pending, and legacy rows in a real DB. Assert
  default counts/pages/search and every hygiene/organizer query agree; keep all
  existing OR expressions parenthesized under the membership predicate.
- [ ] Suspend a real Auto-Tag lookup and a real worker decode, retire the row,
  release the work, and verify no result is persisted/applied. Test retire then
  reactivate during suspension; captured revision must still reject the old result.
- [ ] Run FileEligibilityIntegrationTests and affected existing tests red. Apply
  shared query predicates and execution/completion guards. Preserve stopped-pass
  semantics, bounded pages, and partial batch reporting for other eligible rows.
- [ ] Existing Auto-Tag choices for retired files remain inspectable but cannot
  be approved/applied; show the reason and remove them from bulk approval. Ensure
  session navigation persistence does not retain processing authority.
- [ ] Toggle guards and predicate parentheses separately, confirm regression red,
  restore and commit `Exclude retired and unavailable files from processing`.

## Task 7: Startup/exit sequencing and visible sync state

**Files:** Modify `AppServices.swift`, `SeratoSyncCoordinator.swift`,
`OperationEngine.swift`, `MainWindowView.swift`, and `MenuBarStatusView.swift`.
Create `CrateAgent/Services/SeratoLibrarySyncSession.swift` and
`CrateAgentTests/SeratoLibrarySyncSessionTests.swift`.

**Interfaces:** `SeratoLibrarySyncSession` serializes read → reconcile → drain →
metadata refresh, publishes `waitingForSerato`, `reconciling`, `ready(summary)`,
or `failed(message)`, and accepts `requestSync()` from startup, Serato exit, and
coalesced filesystem-reconciliation requests. No unbounded task-per-event fanout.

- [ ] Add real temporary-library tests with a queued add/rename plus an external
  Serato removal, then simulate Serato exit. Assert retirement commits before
  drain and removed entries do not reappear in V2 or either crate format.
- [ ] Run tests red. Replace the existing drain-first orchestration; do not
  activate automatic reconciliation elsewhere. Failed snapshot validation blocks
  drain and processing eligibility, retaining queued intent and visible error.
- [ ] Test startup while Serato runs never infers absence, starting/stopping during
  reconciliation suspends writes, cancellation cannot mark initial sync complete,
  and an older scan cannot overwrite a newer snapshot. Request bursts coalesce.
- [ ] Use real Tasks and fixture files; assert actual V2 bytes and DB state, not
  just mock invocation order. Disable serialization once to demonstrate red.
- [ ] Connect visible waiting/errors to existing shared presentation components;
  reserve logger output for supplementary diagnosis. Commit
  `Reconcile removals before background work and Serato queue drain`.

## Task 8: Diagnostic views, documentation, and final gate

**Files:** Modify `Views/LibraryBrowserView.swift`, `Views/HistoryView.swift`,
`Models/BrowserRow.swift`, `Services/EventHistoryQuery.swift`, `README.md`, and
`docs/auto-tag.md`. Create `CrateAgent/Services/LibraryStatusBrowse.swift` and
`CrateAgentTests/LibraryStatusBrowseTests.swift`.

**Interfaces:** `LibraryStatusFilter` has active, removedFromSerato, and missing.
`LibraryStatusBrowse` shares existing search/order/limit behavior, exposes status,
last normal path, and per-file history. Removed view includes retired files of
any availability. Missing view includes active unavailable files, with offline
and permission failures labeled accurately rather than called deleted.

- [ ] Write DB tests for status counts, search, pagination, mixed availability,
  stable file history, and no processing actions on removed rows. Run red.
- [ ] Implement a compact Library filter and status text using AppPresentation
  typography/density; preserve the native table and its existing bounded display.
  Display unavailable filenames in Auto-Tag errors instead of only numeric IDs.
- [ ] Render synthetic fixture-only Library/History/Auto-Tag states in light/dark
  and Comfortable/Compact. Do not launch the normal app to inspect UI.
- [ ] Document Serato removal versus Trash, retirement/reactivation, missing-file
  behavior, external-volume limitations, and snapshot error behavior. Read README
  opening/setup/layout for consistency; update only claims affected by this change.
- [ ] Run all isolated Swift tests and Rust workspace tests; review any Rust tests
  that optionally read a real Serato database before execution and keep those
  disabled. Run `cargo fmt --manifest-path rust-core/Cargo.toml --all --check`
  and `cargo clippy --manifest-path rust-core/Cargo.toml --workspace -- -D warnings`.
- [ ] Format changed Swift paths only, run `git diff --check`, and run `make build`.
  Report exact commands, counts, exclusions, and failures in the progress ledger.
- [ ] Request independent GPT-6 Astra review of the complete diff against both
  spec and plan, explicitly hunting removal/re-add races, queue revival, incomplete
  snapshots, canonical shared-row effects, and fake regression passes. Resolve
  every genuine finding and repeat only affected verification.
- [ ] Commit final UI/docs, push the feature branch, open the PR with current
  behavior and actual validation evidence. Do not merge or run a live-library
  reconciliation without the user's separate action.

## Plan self-review

- State/history and migration: Task 2; no physical deletion or history cascade.
- Complete authoritative snapshot and corruption: Task 1, source/generation guards in Task 7.
- Pending import/rename, reactivation, replacement identity, online scope: Tasks 3 and 5.
- Queue, History replay, late completion, Serato restart: Tasks 3, 6, and 7.
- Trash, missing/offline distinction, checkpoint ordering, coalescing: Tasks 4 and 7.
- Default queries, bounded diagnostics, counts, UI and docs: Tasks 6 and 8.
- Real regression mechanisms, isolated verification, independent review: every task and final gate.
