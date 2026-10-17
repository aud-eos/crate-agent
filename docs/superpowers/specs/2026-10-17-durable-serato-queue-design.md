# Durable Serato write queue (#110, with #115, #117, #100)

## Intent

Every edit made while Serato is open must reach Serato's library files and the audio files exactly once, however the session ends — Serato quitting first, crate-agent quitting or crashing first, a reboot, or a crash mid-drain — without the user repairing anything by hand in History. Today the queue (`OperationEngine.pendingSeratoWrites`) is memory-only; after a crash the leftover `event:N` fences make startup fail with `incompleteEffects` forever.

## Decisions

- **#106 (resolved):** audio file-tag writes stay queued while Serato runs.
- **D1 (resolved):** keep the existing rule. If crate-agent launches while Serato is running, browsing works and queued changes are shown; processing opens only after Serato quits and the strict sync completes (`LibraryStartupTests.swift:195`).
- **D2 (resolved):** a queued write that fails is isolated to the writes that depend on it, shown with its error, and retried by Retry Sync. A "Discard queued change" action is deferred to a follow-up issue.
- Engineering calls: legacy destructive fences (trash/remove events from before the upgrade) are not auto-resumed; a crash mid tag write is recorded as `interrupted`, not retried; queue identity is `(event_id, kind)`; a duplicate-cleanup intent is created in the same transaction as its first step.

## Scenarios (owner-approved)

1. Serato quits while crate-agent is open → drain from durable storage.
2. crate-agent quits/crashes, relaunches while Serato still runs → queue reloaded, browsing works, writes wait for quit (D1).
3. Relaunch after Serato already quit (incl. reboot) → drain during startup.
4. Crash mid-drain → resume; nothing applied twice.
5. Serato-session edits to the same tracks (#115) → newer Serato field values win for V2 per the baseline contract; only the affected ownership is dropped.
6. File moved/replaced/deleted meanwhile (#117) → verified against original identity; never redirected to an unrelated file; dropped writes surfaced visibly.
7. History Re-sync while queued → no double-apply.
Plus #100: drain coalesces V2 rewrites into one pass.

## A. Current state (from code reading at 11bab44)

### #115 — already handled in memory
- Session order is strict read → reconcile → scan (`refreshMetadata`) → drain (`SeratoLibrarySyncSession.swift:337-358`), with a fresh snapshot/re-run after a drain that applied anything (`:365-376`).
- `OperationEngine.observeSnapshotMetadata` (`:544-619`) compares each queued `metadataUpdate` against its captured `externalBaseline` per field: keep iff `(baseline != nil && saved == prior) || saved == intended` (`:578`); unknown baseline → `uncertainV2Fields` (`:583-585`); SQLite overlay keeps local values for unchanged fields (`:556-567`); per-field row reduction (`:586-590`); only `metadataUpdate` reduced, so tag ownership is independent (`:571`).
- Covered by `FinalRemovalIntegrationTests.swift` (`:113`, `:156`, `:400`, `:586`, `:611`).

### #115 — remaining
1. Nothing durable: `pendingSeratoWrites` (`:69`), `observedSeratoMetadata` (`:70`), `pendingFieldConflicts` (`:71`), per-write baselines (`SeratoWriteEligibility.swift:20`).
2. **Live bug without a crash:** baselines go unknown too easily and queued intent is then dropped. `routeSeratoWrites` falls back to `SyncCheckpointStore.cachedBaseline` (`OperationEngine.swift:679-686`), which returns nil unless the current V2 source identity equals the published header's (`SyncCheckpointStore.swift:160,169`). The fast startup path (`SeratoLibrarySyncSession.swift:264-285`) never calls `restoreObservedSeratoMetadata` (only slow path, `:317-327`). Own immediate V2 writes advance the in-memory baseline only if one exists (`OperationEngine.swift:2333-2337`). So after fast startup + any own V2 write or Serato save, later queued writes get `externalBaseline = nil`; on quit an unchanged A with queued B drops B and the overlay writes A back to SQLite. Breaks "A→queued B→unchanged A applies B".
3. Renamed files are never observed: the scanner indexes Serato records by current SQLite path (`LibraryScanner.swift:280-305`); with a queued rename Serato's record is at the old path, lands in `refreshPaths` (`LibraryRefreshPlanner.swift:84-92`), finds no row, is skipped (`LibraryScanner.swift:328-331`). A Serato edit C at the old path is never seen; drain renames and writes B over C. The reconciler maps old paths for membership (`SeratoMembershipReconciler.swift:225-237`, `hasApplicableRename`) but not metadata.
4. Interrupted own write misattributes ownership: if V2 got B but the process died before the queue cleared, the next scan journals B as an external change (`OperationEngine.swift:595`, `:1058-1061`).
5. Kept writes never refresh their baseline after reconciliation (`:588-590`).
6. Coalesced V2 updates lose fields for the same file: Rust batch writer keys a `HashMap` by path, last update wins wholesale (`rust-core/src/ffi.rs:263-266`). Affects the immediate path today (`OperationEngine.swift:2258-2273`).

### #117 — already handled in memory
- `SeratoWriteEligibility.resolved` retargets tag/trash/add writes to the current `file.path`, reference writes when the old path is gone (`SeratoWriteEligibility.swift:27-56`); test `FinalRemovalIntegrationTests.swift:521`.
- `requirePhysicalTarget` (`:58-97`) rejects replacements, compares content following owned tag-write chains, checks exact paths (`:99-109`), inside the serialized writer transaction that performs I/O (`OperationEngine.swift:1618-1654`).
- Removed rows classify `.superseded` (`SeratoConflictQueue.swift:52-54`; `OperationEngine.swift:1637-1639`). `files.id` is AUTOINCREMENT and tokens include membership revision, so re-indexed files can't inherit work.

### #117 — remaining
1. Nothing durable, incl. original identity, reference paths, cleanup authority/receipts (`DuplicateCleanupIntent.swift:58-88`).
2. Dropped writes are only a count (`AppPresentation.swift:72`) + activity log.
3. Immediate-path failures drop writes (except adds) (`OperationEngine.swift:1771-1782`) and leave their fence — the path to the unclearable `incompleteEffects` state. A `cachedBaseline` throw after commit raises `externalSyncIncomplete` without queuing (`:680-685`).
4. History Re-sync appends reconstructed writes without dedup (`:801`) → double-apply if already queued.
5. Old-path reuse leaves the V2 reference on an unrelated occupant; user only sees a count.
6. Content check is coarse (`sameContent`, `SeratoWriteEligibility.swift:111-114`) — accepted by the doc; noted only.

### #100
`drainPendingSeratoUpdates` applies one write at a time via `applySeratoWrite` (`OperationEngine.swift:1507-1552`).

## B. Design

### Principle
The SQLite table is the queue. Every Serato-side write becomes a row inside the same transaction as the mutation that produced it, whether applied now or queued — at the point `beginEffect` is called today (`OperationEngine.swift:2375-2377`). A row is deleted inside the writer transaction that performs its I/O. In-memory `pendingSeratoWrites`, `observedSeratoMetadata`, `pendingFieldConflicts`, `pendingDuplicateCleanups`, event effect-fence bookkeeping, and `DuplicateCleanupReceipt` state go away; reads become queries. Process-local only: `isDraining`, `claimedQueueIDs` (never process a row twice concurrently), `duplicateCleanupResults` rebuilt from rows.

### Schema (next migration number)
```sql
CREATE TABLE serato_write_queue (
  queue_id INTEGER PRIMARY KEY AUTOINCREMENT,   -- FIFO order
  event_id INTEGER NOT NULL,
  kind TEXT NOT NULL,          -- rename|metadataUpdate|addTrack|fileTagWrite|removeFromDatabase|removeFromCrates|trashFile
  file_id INTEGER NOT NULL,    -- no FK: must outlive removeFile so it is superseded visibly
  membership_revision INTEGER NOT NULL,
  payload BLOB NOT NULL,       -- JSON: write, originalIdentity, originalReferencePaths, externalBaseline (null = unknown)
  cleanup_target_file_id INTEGER,
  attempts INTEGER NOT NULL DEFAULT 0, last_attempt_at INTEGER, last_error TEXT,
  created_at INTEGER NOT NULL,
  UNIQUE (event_id, kind)      -- same identity SeratoConflictQueue.sameIntent uses
);
CREATE INDEX serato_write_queue_file ON serato_write_queue(file_id);
CREATE TABLE duplicate_cleanup_intents (
  target_file_id INTEGER PRIMARY KEY, payload BLOB NOT NULL,  -- target+keeper FileActionAuthority, batchID
  step INTEGER NOT NULL, waiting_event_id INTEGER,
  removed_v2 INTEGER NOT NULL DEFAULT 0, removed_row INTEGER NOT NULL DEFAULT 0, failure TEXT);
CREATE TABLE serato_external_baselines (   -- last authorized external V2 observation not yet in a published checkpoint
  file_id INTEGER PRIMARY KEY, membership_revision INTEGER NOT NULL, metadata BLOB NOT NULL);
CREATE TABLE serato_write_dispositions (   -- durable "not applied" record
  id INTEGER PRIMARY KEY AUTOINCREMENT, event_id INTEGER NOT NULL, batch_id TEXT NOT NULL, kind TEXT NOT NULL,
  disposition TEXT NOT NULL,  -- superseded|uncertain|interrupted|legacyUnrecoverable
  detail TEXT, created_at INTEGER NOT NULL, reported INTEGER NOT NULL DEFAULT 0);
CREATE TRIGGER serato_write_queue_insert AFTER INSERT ON serato_write_queue
BEGIN INSERT INTO sync_revision (id, revision) VALUES (1,1) ON CONFLICT(id) DO UPDATE SET revision = revision + 1; END;
```
The insert trigger keeps the revision bump `beginEffect` provides, so a concurrently built checkpoint candidate is invalidated. Deletes/updates don't bump; session accounting unchanged. Note: the incremental-startup invalidation triggers name `files` columns explicitly — adding columns to `files` requires recreating them (not needed here).

### Codable
Already Codable: `FileMembershipToken`, `FileMetadata`, `SeratoMetadata`, `AudioFileReadIdentity`. Needs Codable: `SeratoPendingWrite` (explicit keys, `kind` discriminator equal to the column value — not synthesized `_0`), the six payload structs (`OperationEngine.swift:4005-4081`), `GuardedSeratoWrite` (token, write, eventId, originalIdentity, originalReferencePaths, externalBaseline; plus non-encoded `queueID: Int64?`; exclude `requiredKeeper`/`cleanupReceipt`, rebuilt from `duplicate_cleanup_intents`), `FileActionAuthority`, persisted part of `PendingDuplicateCleanup`. Replace `DuplicateCleanupReceipt` flags with `removed_v2`/`removed_row`, written in the same writer transaction as the I/O. Add a typed accessor `SeratoWriteQueue` (static funcs over `GRDB.Database`: insert, fetchOrdered, fetch(fileID:), replace, delete, exists, count).

### Inserts (same transaction as the mutation)
- `executeAndLog` (`:2375-2377`): replace `beginEffect` with `SeratoWriteQueue.insert` — covers apply, applyBatch, moves, undo, cleanup steps.
- Baseline captured in-transaction: `serato_external_baselines` first; else the checkpoint occurrence via a new in-connection `cachedBaseline` that drops the V2 source-equality check but keeps header-complete, library ID, evidence revision/identity and unique-occurrence checks; else null. Closes #115.2 (own writes now upsert `serato_external_baselines` in their I/O transaction) and removes the post-commit async lookup and its write-losing throw (`:676-689`).
- Cleanup: in `advanceDuplicateCleanup`'s write closure (`:209-221`) set `cleanup_target_file_id` on the step's rows and insert/update the intent (step, waiting_event_id) in the same transaction.
- History Re-sync (`:801`): `INSERT OR IGNORE` — an existing row for the same (event, kind) is already the current reconciled intent.

### Updates/deletes (every site today's arrays shrink or change)
- `observeSnapshotMetadata` replace/remove (`:606-611`): row UPDATE/DELETE, `serato_external_baselines` upsert (replaces `:605`), disposition inserts (replaces `pendingFieldConflicts`, `:612`) in the observation's transaction (extend `applyObservedBatch` with an in-transaction closure). Kept rows get `externalBaseline` = observed (fixes #115.5). Fields where saved == the row's intended value are our own write: advance baseline, not claimed as external ownership (fixes #115.4).
- Drain removal (`:1546-1548`): applied rows deleted inside `performExternalWrite`'s transaction after `operation(database)`, alongside `recordOwnedTagWrite` (`:1951`), baseline upsert (replaces `:2333-2337`), cleanup flags, trash `removeFile` (`:1838-1845`). Rename and crate-sweep (multi-store) rows deleted in a follow-up transaction after every store succeeds. addTrack row deleted in its confirmation transaction (`:1804-1818`). Superseded rows: delete + disposition in one transaction.
- Cleanup sites `:261, :286, :301, :315, :322`: delete intent row (+ disposition for superseded/failed); `:301` folded into the trash transaction. Updates at `:233, :246, :255, :257, :296` become column updates.
- Append sites `:234, :694, :1738, :1767, :1779` become no-ops (rows exist); on failure set `attempts`/`last_error`.
- `performExternalWrite` additionally requires each row still exists; a missing row means already applied → skip, not counted superseded. With `claimedQueueIDs` this is the double-apply guard (scenarios 4, 7).

### Effect fences
Remove `event:N` fences — the queue row is the fence. Delete `pendingEffectFenceIDs`, `finishResolvedEffectFences`, `activeEffectEvents`, begin call at `:1692-1696`. Keep `sync_effect_fences` only for `physical:` move fences (`PhysicalFileMoveTransaction.swift:23-44`) and one-time legacy recovery. `publish` (`SyncCheckpointStore.swift:113`) and `authorizeReady` (`:153`) check physical fences + queue rows not in `allowedQueueIDs` (blocked/isolated-failed) + cleanup intents. `incompleteEffects` message (`LibrarySyncCheckpoint.swift:66`) becomes specific to physical/legacy fences.

Legacy recovery: `operationEngine.recoverLegacyEffectFences()` at session run start, before `baseRevision` is read (`SeratoLibrarySyncSession.swift:246`). For each `event:N` fence with no row: rebuild via existing `reconstructResyncWrites` (reduces to current ownership, checks eligibility), insert rows and delete the fence in one transaction; rebuild an add only if the file is still a pending import; destructive kinds → `legacyUnrecoverable` disposition and clear the fence. Repairs users stuck today.

### Launch ordering
1. Migrations. 2. `OperationEngine.init` seeds `queueDepthSubject` with a synchronous COUNT. 3. `session.run`: legacy recovery; if Serato running → `.waitingForSerato` (rows stay, browsing works, processing closed, D1); else `hasPendingSynchronizationWork` (EXISTS over queue, intents, unreported dispositions) skips the fast path → strict read, reconcile, scan (rows reduced durably), drain under `drainAuthorization`, fresh read/re-scan, publish. 4. On Serato quit, `SeratoSyncCoordinator` runs the same path (scenarios 1, 3).

### Drain entry points
One function `processQueue(scope: .all | .rows(Set<Int64>))` for: session drain, Retry Sync (`retryingFailedCleanup`), the immediate path in `routeSeratoWrites` (scoped to rows just inserted), `resyncSeratoForBatch` (batch's rows), cleanup advancement. Scoped passes classify against all earlier rows; an earlier pending row sharing a dependency (`SeratoQueueDependency`) blocks the scoped row, so a fast path never jumps FIFO for the same file/path.

### Idempotency
| Kind | Exactly-once | Crash between I/O and COMMIT |
|---|---|---|
| fileTagWrite | row exists + identity verified in the I/O transaction; delete + `recordOwnedTagWrite` same transaction | commit `attempts++` before I/O; on restart identity mismatch → `interrupted` disposition (visible, not retried) |
| metadataUpdate (coalesced) | row deletes + baseline upsert in I/O transaction | replay writes same values; recognized as own write |
| rename/batch | rows deleted after all stores succeed | replay old→new is a no-op where old path absent; `requireReference` blocks unrelated occupants |
| addTrack | Rust `add_track` dedups on exact path (`serato.rs:581-596`); delete in confirmation transaction | no-op add then confirm; "active and in V2" counts complete |
| removeFromDatabase | absent path → 0 | idempotent; `removed_v2` in same transaction |
| removeFromCrates | per crate idempotent; delete after all crates | re-sweep |
| trashFile | trash + cleanup `removeFile` + row/intent delete in one transaction | attempt marker + original path absent → `validate(audioWasTrashed: true)` finishes cleanup; standalone trash → `interrupted` |
| duplicate cleanup | intent row is the state machine; step updates ride step transactions | resume from `step`/`waiting_event_id`, revalidating target and keeper each step |

### Coalescing (#100)
Drain classifies all rows FIFO, then groups eligible rows. Every `metadataUpdate` joins one V2 group unless an earlier pending row in the pass with a V2 path effect (rename, addTrack, removeFromDatabase) intersects its dependency → new segment. Consecutive renames (skipping independent tag writes) form one batch. Same-path updates are merged in queue order with `overlayMetadata` in Swift before calling the writer — fixes #115.6 on drain and immediate paths. If one target is rejected, valid siblings stay coalesced (existing logic `:1745-1754`).

### Failure isolation (D2)
A row whose I/O fails gets `last_error`/`attempts` and blocks only its dependents; independent rows still drain. The drain then throws an aggregated `externalSyncIncomplete` naming the file and suggesting Retry Sync. (Stop-on-first-failure at `:1537-1541` would become a permanent cross-restart wedge once durable.)

### Visible states
Queue depth from the table; waiting-for-Serato with "N queued changes will apply when Serato quits"; failure message with `last_error`; dispositions feed `ReconciliationSummary.supersededWrites` (+ interrupted/uncertain counts), marked `reported` once a ready summary shows them. Optional: per-batch "not applied" badge in History via dispositions.

### Other
- Rename mapping (#115.3): give `LibraryRefreshPlanner`/`LibraryScanner.scan` a map from normalized old path → file ID from each file's oldest pending `rename` row (reusing `hasApplicableRename` rules); the Serato record at that path is observed as that file's metadata. If both old-path and new-path records exist, block the row with a visible conflict.
- Docs: update the "in-process … does not implement durable queue recovery" statements in `docs/serato-membership-reconciliation.md`.
- Budget (Invariant 8): zero rows → fast path costs one EXISTS (measure with `LibraryStartupPerformanceTests`); draining N metadata rows = one V2 rewrite + N tag writes; scan per-file row lookup indexed.

### Sequencing
1 migration + Codable + `SeratoWriteQueue`; 2 insert in mutation transaction + in-transaction baseline + `serato_external_baselines`; 3 drain from table with in-transaction deletes + `claimedQueueIDs`; 4 cleanup intents; 5 replace fences in publish/authorizeReady + legacy recovery; 6 resync `INSERT OR IGNORE` + scoped processing; 7 coalescing + same-path merge; 8 rename-path observation; 9 dispositions + UI copy.

## C. Tests (public interface, real objects)
Fixture `SeratoRemovalFixture` (temp dir, synthesized V2/Subcrates/SmartCrates, real WAVs) with real engine/scanner/reconciler/session. Restart = new `OperationEngine` + session over the same database. Serato state via watchdog bundle-ID provider. Wrappers only at true boundaries: call-counting recorders around real `writeAudioTags` and `batchUpdateDatabaseRecords`; a trasher moving into a temp dir.

1. `testQueuedWritesSurviveRestartAndApplyOnceWhenSeratoQuits` over relaunch Serato `[running, already quit]`: MB match + rename queued; restart; if running `.waitingForSerato` and depth 3 from table; after quit/startup V2 path+metadata correct, each tag written once, queue empty, readiness open, checkpoint published.
2. `testInterruptedDrainResumesWithoutReapplyingOrRejournaling` over `[metadataUpdate, rename, removeFromCrates, addTrack, fileTagWrite]`: boundary wrapper performs real I/O then throws; restart; V2/crate bytes unchanged on second pass, events count unchanged, fileTagWrite → visible `interrupted`, no second write.
3. `testDuplicateCleanupResumesAfterRestart` (shape of `FinalRemovalIntegrationTests:480`): trashed exactly once, V2/crates clean, row gone.
4. `testSeratoSessionEditsWinAcrossRestartAndFastStartup` over unchanged A / C / clear: fast path start; own immediate V2 write to another file; launch Serato; queue B + tag write; restart → B applied / C kept / clear kept; tag written regardless. Fails today for "unchanged A".
5. `testSeratoEditAtOldPathOfQueuedRenameIsPreserved`: queue rename + B, C at old path in V2, quit → path renamed, C preserved.
6. `testReplacedRemovedOrReusedTargetsAreDroppedVisiblyAcrossRestart` over [replaced in place, undo of index, moved with old path reused]: unrelated bytes unchanged, independent row for another file still drains, disposition counts in the ready summary after restart.
7. `testHistoryResyncWhileQueuedDoesNotDoubleApply`: resync while running leaves depth unchanged; after quit one tag write and one V2 pass; also resync with Serato closed while a failed row pending → applied once, row gone.
8. `testDrainCoalescesQueuedV2MetadataIntoOneRewrite`: matches on 3 files + two edits to one file → batch writer called once, both same-file fields survive.
9. `testLegacyEffectFenceRecoversOnStartup`: `event:N` fence for a journaled match with no row → startup completes, V2 updated, no `incompleteEffects`.
10. Extend `SyncCheckpointStoreTests.testPublicationRejectsStaleRevisionAndDurableUnacknowledgedEffects`: rejected while queue rows/cleanup intents exist; accepted with only allowed queue IDs.
Existing tests likely needing updates: `FailedImportRecoveryTests` (retained adds now durable rows); `RetiredFileWriteGuardTests:364` should pass unchanged.

## Critical files
OperationEngine.swift, SeratoWriteEligibility.swift, SyncCheckpointStore.swift, SeratoLibrarySyncSession.swift, DuplicateCleanupIntent.swift, LibraryScanner.swift, LibraryRefreshPlanner.swift, rust-core/src/ffi.rs, Database/Database.swift (+ Migrations), CrateAgentTests/FinalRemovalIntegrationTests.swift.

## Implementation notes (PR 1, steps 1–6)

- `duplicate_cleanup_intents` has no `removed_row` column: the Trash writer
  transaction also removes the file row and deletes the intent, so no state
  exists between them.
- Publication does not check cleanup intents. An intent between steps owns no
  queue row; it forces the next startup onto the strict path, whose drain
  advances it. Blocking on it would wedge readiness behind a conflict-blocked,
  unstarted cleanup.
- The external baseline is read from `serato_external_baselines` first and
  falls back to checkpoint evidence without the V2-source-equality check.
- A scoped pass treats an out-of-scope row as a dependency only while its
  membership revision still permits it; a superseded row blocks nothing.
- Review fixes: completing a V2 edit rebases later same-file edits; the
  observation reducer is FIFO-aware; an interrupted cleanup Trash finishes on
  the next sync; pass claims are owned and taken atomically; malformed rows and
  fences are quarantined with a `malformed` disposition.
- The ordering gap where a scoped pass applied its metadata group before renames
  in the same scope is closed in PR 2: scoped and full drains share segmentation.

## Implementation notes (PR 2, steps 7–9)

- `SeratoWriteSegmenter` groups rows; an independent tag write between renames
  still ends the rename batch.
- A metadata segment is one V2 rewrite, so its rows succeed or fail together.
- The reducer also treats a saved value equal to a later queued edit as our own
  coalesced write; a row left with nothing to do is deleted without a disposition.
- Rows carry `baselineKnownFields`: the fields whose baseline is known. Rebasing
  after one of our edits lands marks that edit's fields as known.
- Rename-path observation needs no planner change: the scanner observes the
  Serato record at the old path for the file's oldest pending rename. A rename
  whose old and new paths both have saved records reuses `SeratoPathConflict`
  and the review screen.
- The History badge is a minimal count of changes not applied, per batch.
- A saved value counts as our own landed write only for rows with attempts > 0.
- With no observed baseline, insert uses the event's journaled `previousMetadata`
  (commit to Serato, MusicBrainz match) for the written fields.
- The write boundary names every conflicted row (`ExternalWriteInterruption.conflicted`);
  phase-one classification already blocks rows conflicted when the pass starts.

## Implementation notes (#117 completion)

- One pass over queued rows runs at a time; a pass started inside another (a
  cleanup step a drain advances) joins it. Overlapping passes stranded a rename
  behind another pass's unfinished row until the next sync.
- A rename batch applies its renames in order, so old → middle → new lands at the
  final path instead of stopping at the middle one.
- A row counts as possibly landed only when an attempt reached I/O and not every
  write for it threw (`io_started`); `may_have_landed` keeps that across a
  later failed retry, and an attempt stopped before I/O never sets it.
- Undo refuses to remove an indexed row once its membership changed, so only
  `removeFile` (duplicate cleanup) removes a row with queued work; the file ID is
  `AUTOINCREMENT`, so a re-indexed row never matches the removed row's tokens.
