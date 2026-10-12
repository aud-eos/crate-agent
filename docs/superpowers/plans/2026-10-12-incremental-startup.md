# Incremental Startup Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open the saved library immediately, validate unchanged launches in under two seconds, and refresh only necessary files while preserving processing authorization.

**Architecture:** Extend the existing sync session with a transactional checkpoint store, an incremental planner and an explicit filesystem replay boundary. Normal mutations and strict observation authorization remain in OperationEngine; cached evidence never independently opens readiness. Manual Re-scan File Info bypasses incremental refresh selection.

**Tech Stack:** Swift 5.10, macOS 14+, SwiftUI/AppKit, GRDB 6.x, SQLite WAL, native FSEvents and the existing Rust/UniFFI reader. No new dependency or version upgrade.

**Spec:** `docs/superpowers/specs/2026-10-12-incremental-startup-design.md` (approved 2026-10-12).

**Execution:** Preserve the owner's native execution preference: implement inline, then one fresh whole-branch review. This plan awaits owner review before execution.

## Global Constraints

- "Browsing, search, scrolling and sidebar navigation work while validation runs."
- "Explicit **Re-scan File Info** remains the force-refresh command."
- "A local edit must not be overwritten merely because it differs from unchanged Serato metadata."
- "Blocked observations never advance the durable cursor past unhandled work."
- "Prior conflicts force fresh strict analysis so raw evidence and physical aliases remain current."
- "Stat-only checks are allowed on an unchanged launch; audio content reads are not."
- "Migrations create schema only; ordinary verified synchronization populates the cache."
- "This cache is not a durable external-write queue and does not claim to recover lost in-memory intent."
- "No new Rust parser, dependency, generic worker dashboard, tag-writing policy, automatic conflict repair or cross-machine portability is part of this change."
- "Keep builds native arm64, serial and lower priority on this Mac, reuse build artifacts, and never run heavy Rust and Swift builds concurrently."
- Unchanged ready budget: under 2 seconds for 30,000 tracks; actual rendering/navigation budget: 500 ms during synchronization.
- Retain raw occurrence bytes/multiplicity, conflict closure, commit-time revision checks and all existing physical-I/O guards.
- No production library, secrets, normal preferences or live AppServices in tests.

## Review Focus

1. Files reached through symlinks outside a watched directory must not inherit false event coverage. Task 3 exercises target replacement outside coverage.
2. A crash after external I/O but before its database acknowledgement must not leave a usable clean checkpoint. Task 1 exercises a durable pre-effect fence across database reopen.
3. A conflict repaired without a V2 change must not restore cached physical diagnostics or authorize a stale alias. Task 5 exercises same-source conflict reanalysis.
4. Metadata edited locally while a changed saved snapshot is being planned must retain newer intent and per-target ownership. Task 4 exercises a suspended observation with a later local edit.
5. Native replay with no file events, followed by an event between boundary capture and readiness, must neither hang nor reopen stale authorization. Tasks 2 and 5 exercise both orderings, including a real temporary FSEvents stream.

## File and interface map

New production units:

- `CrateAgent/Database/Migrations/AddSyncCheckpointMigration.swift`: schema and SQL invalidation triggers, registered after migration 010.
- `CrateAgent/Services/SyncCheckpointStore.swift`: versioned header/projections, transactional publication, dirty evidence and effect fences.
- `CrateAgent/Models/LibrarySyncCheckpoint.swift`: value types for stored evidence; no file I/O.
- `CrateAgent/Services/FilesystemReplayBoundary.swift`: callback delivery sequence and native boundary acknowledgement.
- `CrateAgent/Services/LibraryRefreshPlanner.swift`: partition saved/indexed evidence into necessary work.
- `CrateAgent/Services/LibrarySyncMetrics.swift`: phase durations and counts, no paths/metadata.
- `CrateAgent/Services/LibraryStartupCoordinator.swift`: shared production/test startup orchestration over injected existing services.

Existing owners to extend:

- `SeratoMembershipSnapshot.swift`: cached-source authorization without invoking the parser.
- `FSEventsWatcher.swift`, `FilesystemEventProcessor.swift`, `FilesystemSyncBatchHandler.swift`: native markers, closed-gate startup replay and normal delivery handoff.
- `SeratoMembershipReconciler.swift`, `LibraryScanner.swift`: execute a restricted plan or the existing full path.
- `OperationEngine.swift`: checkpoint invalidation/fences and baseline restoration; no parallel mutation engine.
- `SeratoLibrarySyncSession.swift`, `SeratoSyncCoordinator.swift`, `AppServices.swift`: automatic incremental startup/Serato-close behavior, checkpoint publication and retry.
- `Views/Components/AppPresentation.swift`, `LibraryBrowserView.swift`, `MainWindowView.swift`, `MenuBarStatusView.swift`: shared progress and visible authorization state.

Shared contracts are introduced by the indicated task, not independently redefined:

```swift
enum LibrarySyncRequest: Sendable { case incremental, forceRefresh }

struct FileRefreshStamp: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
}

struct FilesystemReplayReceipt: Sendable {
    let deliverySequence: UInt64
    let eventID: UInt64
    let requiresFullReconciliation: Bool
    let observations: [FSEventsObservation]
}

struct LibraryRefreshPlan: Sendable {
    let reconciliationFileIDs: Set<Int64>
    let metadataPaths: Set<Data>
    let verifiedIdentityPaths: Set<Data>
    let derivedValuePaths: Set<Data>
    let requiresFullReconciliation: Bool
}
```

Use `Data(path.utf8)` for raw path keys. Normalized path keys are only used after conflict analysis. `FileRefreshStamp` is cache evidence; keep existing domain identity and fingerprint formats intact.

## Verification commands

Prepare an isolated worktree and preserve the already verified b83deec baseline. No baseline rebuild is needed for the documentation-only commits. Before the first product test, generate the Xcode project and reuse matching current Rust/FFI artifacts from the main checkout; rebuild Rust only if inputs differ. Do not copy an unknown or mismatched static library.

Create an execution-local `test-swift.sh` with this exact command, accepting XCTest selectors before `test`:

```sh
#!/bin/zsh
set -eu
exec nice -n 10 xcodebuild -project CrateAgent.xcodeproj -scheme CrateAgent \
  -configuration Test -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /Users/benny/dev/crate-agent/build-output/DerivedData \
  -jobs 1 -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES \
  SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO "$@" test
```

`test-swift.sh` in commands below denotes that execution-local wrapper, not a new production script. Keep full logs and inspect XCTest failures separately from existing Xcode device-plugin warnings. Do not add the ineffective OTHER_SWIFT_FLAGS=-j1 override.

For optimized performance, use a separate cached DerivedData directory and the **Test** configuration with `SWIFT_OPTIMIZATION_LEVEL=-O` and `SWIFT_COMPILATION_MODE=wholemodule`; retain `CRATE_AGENT_TEST_HOST` and the isolated bundle ID. Never switch to the normal Release host. Use identical flags for baseline and final measurements.

## Performance preflight (before Task 1)

- [ ] Build the reusable `LibraryStartupPerformanceFixture` specified in Task 6 before changing the sync algorithm. Seed a 30,000-row WAL store and realistic encoded V2 records. Add only I/O injection/counters needed by the harness to the old path; production defaults must call the exact existing operations. Record that instrumentation patch so the baseline is reproducible.
- [ ] Capture the old explicit full-sync baseline on b83deec plus that instrumentation, using the isolated optimized settings above. Keep the same fixture and instrumentation for final comparison; commit the harness with Task 1 rather than rebuilding it later. Record machine/build settings, synthetic I/O boundaries, actual operation counts and cold/warm state. The previous conflict-analysis metric is not a startup baseline.
- [ ] Run the existing focused session tests to verify instrumentation preserves behavior. Do not open live AppServices or create owner-library data. If instrumentation changes results, fix it before measuring.

## Task 1: Persist checkpoint evidence and durable invalidation

**Files:** Create `LibrarySyncCheckpoint.swift`, `SyncCheckpointStore.swift`, `AddSyncCheckpointMigration.swift`, `CrateAgentTests/SyncCheckpointStoreTests.swift`; modify `Database.swift`, `OperationEngine.swift` and `MigrationTests.swift`. Include the performance fixture/instrumentation from preflight in this commit.

**Interfaces:** Introduce `FileRefreshStamp`; make existing `SeratoSourceIdentity` Codable without changing its comparison semantics. Introduce `SyncCheckpointHeader` with `formatVersion: Int`, `libraryID: String`, `source: SeratoSourceIdentity`, `localRevision: Int64`, `watchRoots: [String]`, `eventID: UInt64`, `hadConflicts: Bool`, `complete: Bool`. Volume identity and coverage evidence live in associated checkpoint rows. `SyncCheckpointStore.init(database: LibraryDatabase)`, `loadHeader() async throws -> SyncCheckpointHeader?`, `currentRevision() async throws -> Int64`, and `beginEffect(batchID: String) async throws` / `finishEffect(batchID: String) async throws` are shared by later tasks. Publication takes all evidence and an expected revision in one writer transaction; never expose an unchecked header setter.

- [ ] Create a WAL-backed store fixture once per test and close/reopen it to verify durability. Extend migration coverage to confirm existing domain rows/events are unchanged.
- [ ] Add a regression for relevant file updates advancing the durable revision, rollback leaving it unchanged, and fingerprint-only progress preserving it. Exercise the writer, not a hand-called invalidation helper:

```swift
let initial = try await store.currentRevision()
try await database.writer.write { connection in
    try connection.execute(sql: "UPDATE files SET title = ? WHERE id = ?",
                           arguments: ["Changed title", fileID])
}
let revised = try await store.currentRevision()
XCTAssertGreaterThan(revised, initial)
```

  Construct `database` with `LibraryDatabase.openWAL`, `store` with its initializer, and `fileID` by inserting one active/available FileRecord in the fixture. Extend the same behavior case with rollback and a real `FingerprintPersistence.write`.
- [ ] Run `test-swift.sh -only-testing:CrateAgentTests/SyncCheckpointStoreTests`; observe failure before implementation.
- [ ] Create `sync_checkpoint`, `sync_saved_occurrences`, `sync_file_evidence`, `sync_dirty_files`, `sync_revision`, and `sync_effect_fences`. Store raw path blobs and occurrence ordinals; do not serialize a unique-key path dictionary. Empty migrated tables mean no cache.
- [ ] Use SQLite triggers to advance the revision and retain dirty file IDs/old paths in the same transaction for insert/delete and relevant UPDATEs. Bootstrap the singleton revision row lazily during normal runtime setup, not by data backfill in the migration. Trigger predicates compare OLD/NEW values to avoid no-op churn.
- [ ] Audit all file writers. Invalidate for path, volume/inode, size/mtime/hash, membership/availability/revision, metadata and track ID; changes only to fingerprint bytes/status/basis do not invalidate source or metadata evidence. Derived bitrate updates update/invalidate their cached basis. Track-row metadata changes are not V2 file-field observations; do not copy them into the saved baseline.
- [ ] Commit an effect fence **before** physical or external effects may begin. This must be a prior committed transaction: a marker inside the effect's rollback transaction cannot survive a crash. Keep the existing revalidation under writer serialization immediately before I/O. Clear fences only when all required effects finish or are explicitly superseded; retained/failed batches keep their fence.
- [ ] Exercise a fence left across reopen, including a simulated effect followed by failed acknowledgement. Assert no clean shortcut; preserve an actionable recovery message/batch reference. These markers record uncertainty and do not implement a persisted replay queue.
- [ ] Implement strict cache decoding and publication compare-and-swap: missing/known-old format means cache miss; malformed current format and storage failures throw. Late local revision or incomplete effects reject fast eligibility. Cache writes themselves do not invalidate domain rows.
- [ ] Re-run the focused suite plus `MigrationTests` and existing import/physical-effect regressions. Format changed Swift files, inspect diff, commit `Persist validated sync evidence and invalidation fences`.

## Task 2: Establish a real startup replay boundary

**Files:** Create `FilesystemReplayBoundary.swift`, `CrateAgentTests/FilesystemReplayBoundaryTests.swift`; modify `FSEventsWatcher.swift`, `FilesystemEventProcessor.swift`, `FilesystemSyncBatchHandler.swift`, and `FilesystemEventProcessorTests.swift`.

**Interfaces:** Introduce `FilesystemReplayReceipt`. Add a watcher `captureReplayBoundary() async throws -> UInt64` returning a callback-delivery sequence, and processor `collectStartupReplay(through sequence: UInt64) async throws -> FilesystemReplayReceipt`. Native marker delivery and event batches use one ordered stream; do not compare a global current event ID with an unrelated per-stream last-delivered ID. `finishStartupReplay(_ receipt: FilesystemReplayReceipt) async throws` releases normal delivery only after session success.

- [ ] Add boundary tests with a fake event source: empty replay, history marker delayed after file batches, flush marker, cancellation, dropped/wrapped history and a new event just after the captured boundary. Use continuations for controlled ordering, not arbitrary sleeps.
- [ ] Preserve the existing failed-head and conflict-subset tests; add a startup variant proving later events remain buffered until authorization is established.
- [ ] Run `test-swift.sh -only-testing:CrateAgentTests/FilesystemReplayBoundaryTests -only-testing:CrateAgentTests/FilesystemEventProcessorTests` and observe failure for missing boundary behavior.
- [ ] Forward `HistoryDone`, stream loss/wrap and root changes as explicit control evidence. Capture a native flush boundary on a non-main queue using documented flush semantics; account for zero-event streams. Never call a synchronous flush from the callback queue. Sequence callbacks and boundary acknowledgement before handing them to the actor.
- [ ] Implement a closed-gate startup collection mode. Return observations and required broad reconciliation to the session; do not run a handler that calls `session.synchronize()` while the session awaits replay. Normal post-startup handling keeps existing retry and checkpoint ownership.
- [ ] Add a real temporary-directory FSEvents fixture: create/write a temporary file, await boundary completion and assert the emitted observation precedes the receipt. Stop the stream and await consumers before deleting the fixture. Repeat the empty-stream boundary case in the same fixture.
- [ ] Assert the checkpoint is unchanged while any captured observation is unhandled:

```swift
let receipt = try await processor.collectStartupReplay(through: boundarySequence)
XCTAssertEqual(receipt.eventID, expectedEventID)
let persisted = await checkpointProbe.values
XCTAssertEqual(persisted, [])
```

  Define `checkpointProbe` as an actor storing the IDs passed into the processor's existing checkpoint closure; `boundarySequence` and `expectedEventID` are independent injected stream values.
- [ ] Re-run these suites and `PR123FilesystemSyncRegressionTests`; verify late/empty native markers cannot hang. Format, diff-check, commit `Capture and acknowledge startup filesystem replay safely`.

## Task 3: Authorize cached sources and plan minimal refreshes

**Files:** Create `LibraryRefreshPlanner.swift`, `CrateAgentTests/LibraryRefreshPlannerTests.swift`; modify `LibrarySyncCheckpoint.swift`, `SyncCheckpointStore.swift`, `SeratoMembershipSnapshot.swift`, and `SeratoMembershipSnapshotTests.swift`.

**Interfaces:** Introduce `LibrarySyncRequest` and `LibraryRefreshPlan`. Add `SeratoMembershipSnapshotReader.authorizeCachedSource(libraryID: String, source: SeratoSourceIdentity) async throws -> SeratoSnapshotAuthorization`; this checks current source and watchdog generation without parsing. Define `LibraryRefreshPlanner.makePlan(request: LibrarySyncRequest, snapshot: SeratoMembershipSnapshot, indexedFiles: [FileRecord], previousRecords: [SeratoTrackRecord], dirtyFileIDs: Set<Int64>, dirtyPaths: Set<Data>, analysis: SeratoConflictAnalysis) async throws -> LibraryRefreshPlan`. File stamp/coverage lookup is injected at planner construction; its production default reads only stat/volume evidence unless a verified refresh is selected.

- [ ] Add a pure comparison fixture with three independently specified saved records and matching index rows. Change only the second title; require only its raw path in `metadataPaths`, no unrelated identity/derived reads. Include local title differences against an unchanged saved baseline to ensure SQLite is not mistaken for the external source.
- [ ] Add covered/uncovered stamp cases, symlink-target replacement outside coverage, volume disappearance/replacement, and same-size same-second edits with changed nanoseconds/ctime. Include a prior successful nil bitrate probe so it does not become perpetual work.
- [ ] Run `test-swift.sh -only-testing:CrateAgentTests/LibraryRefreshPlannerTests -only-testing:CrateAgentTests/SeratoMembershipSnapshotTests`; verify the new cases fail first.
- [ ] Implement cached authorization with a fresh reader generation, strict source identity comparison before/after, configured library identity and watchdog revision checks. Reuse the current commit-check closure. Parsing success from a previous process is usable only with the matching complete checkpoint.
- [ ] Partition work without collapsing raw occurrences. Reject supplied analysis for another source/generation. New/moved/unavailable/legacy/dirty rows require existing strict checks; metadata-only changes with sound evidence use current identity and no audio content read. Force-refresh selects every eligible saved entry.
- [ ] Treat replay loss/unknown coverage as broad reconciliation. Outside covered roots and through escaping symlinks, stat and compare stored precise evidence; uncertainty selects strict refresh. No new global watch root.
- [ ] Verify cached authorization becomes invalid after source replacement or watchdog change:

```swift
let snapshot = try await fixture.reader.read()
let authorization = try await fixture.reader.authorizeCachedSource(
    libraryID: snapshot.libraryID, source: snapshot.source)
try fixture.save(paths: ["/different.mp3"])
XCTAssertThrowsError(try authorization.check())
```

  Reuse `SeratoRemovalFixture`; add a parser-call counter at the reader's existing I/O boundary and assert cached authorization makes zero parse calls.
- [ ] Run the focused suites. Format, diff-check, commit `Plan incremental refresh from validated source evidence`.

## Task 4: Execute planned observations without redundant audio work

**Files:** Modify `LibraryScanner.swift`, `SeratoMembershipReconciler.swift`, `OperationEngine.swift`, `SyncCheckpointStore.swift`; extend `SeratoLibrarySyncSessionTests.swift`, `FileEligibilityIntegrationTests.swift`, and `PR123FilesystemSyncRegressionTests.swift`.

**Interfaces:** Extend strict `reconcile` and `scan` with `plan: LibraryRefreshPlan? = nil`; nil retains the existing full behavior. Add engine `restoreObservedSeratoMetadata(_ records: [FileMembershipToken: SeratoMetadata], authorization: SeratoSnapshotAuthorization) throws` for validated saved baselines only, with source authorization supplied by the caller and checked before assignment. Share the existing `observeSnapshotMetadata` overlay/supersession implementation.

- [ ] Extend real session fixtures to cover one external metadata change with unchanged audio; require only that file's event/row to change and no unrelated audio probes. Add an injected audio reader that fails if called on unaffected files.
- [ ] Strengthen the existing queue-baseline test: suspend planning, apply a newer local field value, then resume. Expect stale revision rejection/replanning or preserved local ownership; never overwrite newer intent from an earlier captured FileRecord.
- [ ] Run the affected fixture cases and observe the redundant I/O/stale-case failure before editing.
- [ ] Share lightweight projections between planner/reconciler/scanner. Restrict loops to planned rows/paths while retaining complete saved presence for retirement and complete alias candidates for move/conflict detection. Never retire a row because it was omitted from the refresh subset.
- [ ] Implement metadata-only observations with captured identity/evidence and current commit checks. Full verified refresh remains mandatory for identity uncertainty. Reuse derived values only when their recorded basis matches; record successful absent bitrate separately from failed/unattempted probe.
- [ ] Keep authorization around every observation transaction and preserve the existing original-target guards for queued effects. Cache baseline restoration must not fabricate unknown per-write baselines for interrupted intent.
- [ ] Verify unchanged records produce no observation events:

```swift
let before = try await fixture.events()
try await session.synchronize()
let after = try await fixture.events()
XCTAssertEqual(after, before)
```

  Apply this assertion only after seeding a fully verified fixture and an unchanged checkpoint; pair it with I/O counters so an expensive no-op scan cannot pass.
- [ ] Run the full session, eligibility and filesystem regression suites. Format, diff-check, commit `Apply incremental observations through existing guarded mutations`.

## Task 5: Wire automatic startup and checkpoint publication

**Files:** Create `LibraryStartupCoordinator.swift`, `CrateAgentTests/LibraryStartupTests.swift`; modify `SeratoLibrarySyncSession.swift`, `SeratoSyncCoordinator.swift`, `AppServices.swift`, `FilesystemSyncBatchHandler.swift`, `SyncCheckpointStore.swift`, and `SeratoLibrarySyncSessionTests.swift`.

**Interfaces:** Session `requestSync(_ request: LibrarySyncRequest = .incremental)` and `synchronize(_ request: LibrarySyncRequest = .incremental, retryingFailedCleanup: Bool = false) async throws`. Introduce `LibraryStartupCoordinator.init(session: SeratoLibrarySyncSession, processor: FilesystemEventProcessor, captureBoundary: @escaping @Sendable () async throws -> UInt64)` and `start()`, `stop()`, `waitUntilIdle() async`; production and tests use this same coordinator. Coalescing preserves forceRefresh if any pending request requires it. Add a typed `SyncPhase` shared with Task 6.

- [ ] Write startup integration tests using existing temporary fixture services and the shared coordinator, not live AppServices. Cover initial empty cache, unchanged restart, pending import/cleanup, Serato initially open then closed, cancellation, force-refresh and recovery.
- [ ] Include a same-V2 prior-conflict restart: alter filesystem identity, run startup, require fresh diagnostics and protection before worker persistence. Reuse existing suspended worker regression assertions.
- [ ] Include events between replay capture and readiness, a local DB write during checkpoint commit and a source change after parsing. Assert no stale checkpoint/readiness; retained observations keep their cursor dependency.
- [ ] Run `test-swift.sh -only-testing:CrateAgentTests/LibraryStartupTests -only-testing:CrateAgentTests/SeratoLibrarySyncSessionTests` and observe missing automatic startup/fast behavior.
- [ ] Implement the session sequence from the spec: closed epoch; acquire replay; establish saved membership; replay without recursion; choose cached or planned strict work; analyze conflicts; validate/drain; re-read only after source-changing effects; final source/revision/lifecycle checks; transactional checkpoint publication; mark ready; release delivery.
- [ ] Avoid a gap between cache publication and authorization: carry the expected database revision into the final gate check, and have concurrent relevant mutations invalidate that candidate. A cancelled/failed pass cannot persist a usable completed checkpoint or acknowledge startup replay.
- [ ] Add durable incomplete-effect reporting to the existing status/History recovery path. Full source validation may proceed, but must not silently clear an unresolved fence or claim an interrupted write completed. Existing explicit successful replay/supersession resolves the corresponding fence.
- [ ] Wire AppServices startup through the shared coordinator with the shared readiness gate injected into every processing consumer. Serato-close requests incremental validation; manual rescan passes `.forceRefresh`; stop cancels only the active scan and leaves last committed browsing usable. Retry preserves the failed request's mode and recovery latch.
- [ ] Update former tests expecting Serato-close to remain idle to the newly approved behavior. Keep unstarted session unit construction idle; automatic behavior belongs to the startup/coordinator wiring.
- [ ] Run all session/startup/filesystem/import/fingerprint suites. Confirm production call sites use the tested construction path. Format, diff-check, commit `Validate saved library automatically before background processing`.

## Task 6: Present phases and verify production-scale responsiveness

**Files:** Create `LibrarySyncMetrics.swift`; extend preflight `CrateAgentTests/LibraryStartupPerformanceTests.swift` and `CrateAgentTests/Support/LibraryStartupPerformanceFixture.swift`; modify `Views/Components/AppPresentation.swift`, `MainWindowView.swift`, `LibraryBrowserView.swift`, `MenuBarStatusView.swift`, `SeratoLibrarySyncSession.swift`, `README.md`, `docs/testing.md`, and `docs/serato-membership-reconciliation.md`.

**Interfaces:** Finalize the Task 5 `SyncPhase` cases: `validating`, `replaying`, `parsing`, `reconciling`, `refreshing`, `draining`; progress carries optional completed/total counts. Metrics collect monotonic duration plus parse/stat/tag/bitrate/hash/row-write counts. No path or metadata payload is logged. The fixture exposes a temporary WAL store, real V2 bytes, injected audio boundary counters, and actual mounted Library/navigation views.

- [ ] Reuse the committed preflight fixture and baseline evidence; extend it with the final startup/checkpoint path and mounted navigation. Do not rebuild the fixture differently or substitute conflict-only timing for startup measurements.
- [ ] Build 30,000 saved records with realistic metadata and 30,000 indexed projections once per performance test module. Exercise real parsing, DB persistence/reopen and planning; inject only expensive audio boundaries. Use a separate real temporary-file subset for native stat/replay correctness. Report synthetic audio evidence as a benchmark limitation.
- [ ] Test unchanged checkpoint restart with zero parser/audio calls, one-track external metadata change with one parse/one affected row, forced refresh, prior conflicts and uncovered stat checks. Count behavior independently of timing.
- [ ] Mount the actual window content/navigation while a controlled changed-library sync is active. Perform sidebar navigation before releasing sync and measure response latency. Do not use a post-sync render or only a main-actor heartbeat as the interaction test.
- [ ] Run the new suite before UI/phase integration to observe missing status/count behavior. Add phase publication and shared visible status, with throttled updates and unchanged paged browsing. Keep errors and conflicts visible; no new disclosure UI.
- [ ] Emit and attach evidence with hard behavior assertions and explicit performance acceptance evaluation:

```swift
XCTAssertEqual(counters.audioTagReads, 0)
XCTAssertEqual(counters.bitrateReads, 0)
XCTAssertEqual(counters.lightweightHashReads, 0)
XCTAssertEqual(counters.snapshotParses, 0)
XCTAssertLessThan(timeToReady, .seconds(2))
XCTAssertLessThan(navigationLatency, .milliseconds(500))
```

  `counters`, `timeToReady` and `navigationLatency` are independently recorded fixture outputs, not planner predictions. Apply these assertions to the unchanged covered case and the concurrent-navigation case respectively; report uncovered-stat timing separately and assess the same stated target.
- [ ] Run baseline/final optimized performance with identical settings, then the full serial isolated Test suite. Investigate misses; do not increase thresholds, hide runs or claim performance acceptance from correctness tests.
- [ ] Verify Rust tests/Clippy/fmt as required by the repository boundary; reuse already completed unchanged Rust evidence only when source inputs match. Run SwiftFormat, `git diff --check`, README byte limit, and inspect light/dark compact/comfortable status renders.
- [ ] Update README's manual-first startup description, reconciliation/replay/cache semantics and testing commands. Include measured costs, remaining limitations and owner-app smoke steps. Format/diff-check and commit `Show incremental sync progress and verify large-library startup`.

## Completion and review

- [ ] Compare each spec requirement with the final implementation and evidence. Confirm no task marked complete solely because its code compiles.
- [ ] Run one fresh whole-branch review from b83deec to final HEAD, including this plan, approved spec, measurements and recorded decisions. Explicitly include the five Review Focus cases and production service wiring.
- [ ] Reproduce and fix Important/Critical findings with meaningful public regressions; run affected checks and the full suite after fixes. Record any remaining limitations honestly.
- [ ] Push and open one implementation PR after checks pass, with before/after performance and test results. No merge without explicit owner instruction. Keep the worktree while the PR is open.

## Expected verification results

Every RED run must fail for the specified missing behavior or API, not fixture setup or unrelated compiler failures. Every task's GREEN run must pass all selected tests with no new skips. A pre-existing failure must be investigated and reported; do not weaken assertions. Final isolated Swift and required Rust checks must pass, and optimized performance must meet the approved acceptance budgets before the implementation is claimed complete.

## Spec coverage check

User outcome/UI → Tasks 5–6. Checkpoint/invalidation → Task 1. Launch/replay ordering → Tasks 2 and 5. Cached authorization/coverage → Task 3. Changed-record and queued-baseline semantics → Tasks 3–4. Conflicts/recovery/lifecycle → Tasks 4–5. Production-sized timing, native replay and actual concurrent navigation → Tasks 2 and 6. Every Review Focus item has an owning regression above.
