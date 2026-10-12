# Incremental startup validation

Issue: https://github.com/aud-eos/crate-agent/issues/129

Status: approved by the owner on 2026-10-12. Automatic incremental validation
on launch is approved, keeping full **Re-scan File Info** manual. The implementation
plan awaits review before product changes.

## User outcome

On the owner's approximately 30,000-track library, the window opens onto the last
committed library immediately. Browsing, search, scrolling and sidebar navigation
work while validation runs. A compact status explains the current phase; actions
requiring fresh authorization remain disabled with a reason. Fingerprinting waits
for validated readiness and then resumes through the existing worker.

An unchanged launch should become ready in under two seconds on the reference Mac,
without reading any per-track audio tags, bitrates, fingerprints or lightweight
hashes. A changed V2 is parsed once, then only affected files require expensive
refresh. Explicit **Re-scan File Info** remains the force-refresh command.

This intentionally replaces today's manual-first startup. At b83deec, AppServices
starts watching and fingerprinting but does not request synchronization. Readiness
is closed, and filesystem delivery waits for the first successful manual sync.
The issue's description of a full scan on every launch predates that behavior.

## Approach and alternatives

Use a persisted validated checkpoint, an explicit filesystem replay boundary, and
an incremental refresh planner within the existing synchronization session.

Moving the existing full scan off the main actor alone would preserve repeated
per-file reads. Trusting V2 identity alone would miss audio changes while the app
was closed. A new indexing engine or general job framework would duplicate the
existing mutation, reconciliation and worker architecture. Reuse GRDB transactions,
Apple FSEvents, the strict Rust reader, and current observation mutations instead.

## Launch and readiness sequence

1. Construct the browsing UI from SQLite without awaiting sync. Start the watcher
   immediately and keep normal processing authorization closed.
2. Capture a startup replay boundary from the native event stream. Observe
   historical replay completion and flush pending delivery through a known stream
   boundary. Serialize acknowledgement after the corresponding callbacks reach the
   processor. An empty application queue alone is not proof of complete replay.
3. Inspect the saved checkpoint, configured library/source identity, watched roots,
   volume state, and local database revision. If Serato is running, remain visibly
   waiting; its close notification requests incremental validation automatically.
4. Establish membership from a valid checkpoint or a strict V2 read. On a first
   run or migration, establish legacy membership before replaying filesystem moves,
   preserving the existing old-path association rules.
5. Consume the captured observations under closed readiness. The processor reports
   dirty paths and broad-reconciliation requirements to the session instead of
   synchronously requesting another session that waits for the same processor.
   Events after the captured boundary remain queued for subsequent processing.
6. Reconcile affected membership/identity/metadata, install conflict protection,
   and service required queued work. If that work changes V2, read the resulting
   saved source and update its baseline; no second parse for a no-op drain.
7. Revalidate source identity, watchdog revision, replay acknowledgement and local
   database revision. Publish the checkpoint transactionally, install the matching
   scope, and open readiness for that epoch. Any intervening invalidation prevents
   publication or reopening. Expose success only after these steps complete.

Startup replay is a phase of synchronization, not a recursive synchronization
request. Ordinary runtime event batches retain existing independent-progress and
held-checkpoint behavior. A mixed conflict/root-change batch must still service
required reconciliation. Blocked observations never advance the durable cursor
past unhandled work.

## Checkpoint and invalidation

Use versioned SQLite tables for derived synchronization state. Migrations create
schema only; ordinary verified synchronization populates the cache. Store:

- Supported library identity and strict V2 source identity: device, inode, size,
  nanosecond modification and change times. Preserve current regular-file and
  source-location validation; do not weaken it to seconds or file size alone.
- The last validated saved-record projection needed for membership and metadata
  comparison. Preserve occurrence multiplicity and raw path bytes; canonical path
  equality must never erase conflicting records.
- Per-file refresh evidence: file ID, membership revision, verified physical
  identity, precise stat stamp and the basis for derived-value refresh. This is
  cache evidence, not a replacement for Chromaprint recording identity.
- Watch-root identity, replay cursor/coverage, relevant mounted-volume identity,
  cache format version, local invalidation revision, and conflict/completion state.

Persist cache invalidation with relevant local database mutations, in the same
writer transaction. Cover insert/removal, path, membership, availability, identity,
metadata and recording-link changes, including existing derived-value writers.
Pure fingerprint progress must not require full audio rescanning. The plan must
identify every writer and assign either targeted invalidation or an explicit
irrelevance rule; an in-memory flag alone cannot protect a restart.

An interrupted synchronization or effectful engine batch invalidates eligibility
before its effects can occur. Completion is recorded only after validation and
required external effects finish. Pending writes, failed cleanup, retained events,
unresolved interruption, or a database revision mismatch prohibit the fast path.
This cache is not a durable external-write queue and does not claim to recover lost
in-memory intent. Interrupted effects remain visible through existing recovery and
History flows; merely reading V2 successfully must not claim their intent completed.

Missing or older-version cache data triggers normal validation with a visible
reason. Malformed cache data or storage I/O failures surface as errors; they are
not treated as successful validation. Library relocation, root changes, event-log
loss/wrap, volume replacement and unknown replay coverage require broader checks.

## Unchanged fast path

The fast path requires a previously completed, conflict-free checkpoint, matching
source/library/configuration identities, valid event coverage, no relevant dirty
rows or pending recovery, and successful final revalidation. It neither parses V2
nor scans all audio content. No trusted checkpoint means normal synchronization.

Prior conflicts force fresh strict analysis so raw evidence and physical aliases
remain current. Unrelated work may become ready with conflicts using the existing
scope rules, but that result does not qualify for the conflict-free shortcut.
This avoids persisting stale Finder authorization or silently dropping exclusions.

Watch coverage is explicit. Existing watchers cover the configured music folder
and its applicable Trash directory, not every path referenced by Serato. Do not
expand watching to the whole home directory or every mounted disk. For indexed
files outside trusted coverage, compare precise per-file stat evidence and refresh
only changed or uncertain files. Stat-only checks are allowed on an unchanged
launch; audio content reads are not. A reference benchmark must include this case
and report its separate cost, rather than claiming all real libraries are covered.

Volume disappearance or remount invalidates the corresponding availability
assumptions even when V2 has not changed. Offline files remain distinguishable
from removed membership. Physical aliases and uncertain identity use the existing
strict verification path before granting processing eligibility.

## Changed-library planning

Parse the changed saved source once off the main actor. Analyze conflicts before
using normalized lookup keys. Load lightweight paged projections without fingerprint
blobs; share them across analysis/planning where ownership permits.

Compare incoming records with the last validated external projection, separately
from current local metadata and queued intent. Use existing external baseline and
per-field supersession rules. A local edit must not be overwritten merely because
it differs from unchanged Serato metadata.

Partition work into unchanged, metadata-only, new, removed, moved, unavailable,
identity-changed, legacy-incomplete and conflicted entries. Metadata-only changes
with valid audio evidence do not need tag/bitrate/hash reads. Other changes use
existing identity and mutation primitives; no alternate write path is introduced.

Derived values are refreshed only when missing without a completed probe, or when
their verified basis changed. A successfully probed file with no available bitrate
must not cause the same audio read on every launch; distinguish a legitimate
absent value from an unattempted or failed probe. Failures remain visible/retryable.

Do not infer physical sameness from V2 sameness. Precise cache stamps and observed
changes determine when the existing verified-content checks are required. Keep
commit-time membership, physical identity and scope authorization checks intact.

Force-refresh bypasses the cache and checks the complete saved library. It remains
cancellable, keeps browsing available and publishes a new checkpoint only after
success. Retry Sync retries the failed incremental or recovery operation; it is
not an implicit request for a full force-refresh on every retry.

## UI and component boundaries

The main window and menu bar share phases: validating saved state, catching up on
filesystem changes, reading Serato, reconciling membership, refreshing file info,
and applying queued changes. Show counts only when a meaningful total is known.
Throttle progress updates and avoid full-list invalidation per processed row.

Keep errors, waiting-for-Serato and conflict counts visible with existing actions.
Do not hide diagnostics inside new disclosure controls. The cached library is
clearly labeled as being checked until ready. All processing entry points retain
authoritative engine checks in addition to disabled UI controls.

Keep responsibilities separate:

- Snapshot reader: strict parsing and current source/lifecycle authorization.
- Checkpoint store: transactional cache evidence and durable invalidation.
- Refresh planner: compare projections and determine necessary work.
- Reconciler/scanner: execute planned observations through OperationEngine.
- Event watcher/processor: native replay boundary, observations and checkpoints.
- Sync session: sequence these components and publish readiness/progress.

No new Rust parser, dependency, generic worker dashboard, tag-writing policy,
automatic conflict repair or cross-machine portability is part of this change.

## Verification and performance contract

Measure the current explicit sync and the new launch path on the same deterministic
30,000-track fixture. Record parsing, conflict analysis, planning, filesystem work,
metadata refresh, queue drain, checkpoint persistence and time to ready. Record
counts and durations, never track paths or metadata. Use production-shaped WAL
storage and realistic saved-record sizes; an in-memory timing alone is insufficient.

Required acceptance evidence:

- Unchanged restart: under two seconds to ready on the reference Mac, zero V2
  parses and zero per-track audio reads on the trusted fast path. Include both
  covered and uncovered-stat variants and state coverage in the PR.
- First window and actual sidebar navigation: responsive within 500 ms during a
  changed-library sync; measure during work, not only after it finishes.
- One changed V2 metadata record: one parse and only the affected indexed row
  updated, without rereading unrelated audio.
- New/removal/move/replacement/offline/legacy cases preserve existing semantics.
- Restart with conflicts never opens an empty protection scope from cached success.
- Historical replay arriving late, empty replay, dropped/wrapped events, directory
  rename, root/volume change and changes outside watched roots cannot falsely pass.
- Local mutation, interrupted work, pending imports/cleanup, mid-sync V2 changes,
  cancellation and Serato launch/close cannot publish stale readiness/checkpoints.
- Queued external intent survives unchanged saved metadata and is superseded only
  by applicable external changes, preserving existing per-target ownership.
- Production service wiring exercises automatic validation, fingerprint resume,
  event delivery, force-refresh and Retry Sync without owner-library access.

Extend existing behavioral tests rather than duplicating them. Use injected I/O
boundaries for deterministic races and a small real FSEvents integration fixture
for native replay semantics. Run performance checks in an optimized isolated
configuration with the same fixture/settings before and after; report the native
serial Test suite separately. Do not weaken targets or rerun to select favorable
measurements. If a target is missed, fix the cause or bring the measured tradeoff
back for explicit design review.

Keep builds native arm64, serial and lower priority on this Mac, reuse build
artifacts, and never run heavy Rust and Swift builds concurrently. Complete the
repository checks before opening the implementation PR. Manual smoke verification
covers cold launch, navigation during refresh, waiting with Serato open, closing
Serato, forced rescan/cancellation and conflict-repair retry.

## References

- Existing reconciliation and physical-write contracts:
  `docs/serato-membership-reconciliation.md`.
- Conflict protection shipped in https://github.com/aud-eos/crate-agent/pull/158.
- Native event delivery/flush semantics:
  https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html
- Persistent queued-write recovery remains separately tracked:
  https://github.com/aud-eos/crate-agent/issues/110.

## Approved stat-validation amendment (2026-10-12)

The owner approved replacing the header-only shortcut with a lightweight file-stat validation pass after native experiments delivered file changes after a synchronous FSEvents flush. This amendment supersedes event-coverage-only reuse below: every reused file requires current precise entry/target stat evidence and volume identity, including files under watched roots. A replay boundary orders delivered callbacks; it does not prove that all preceding physical changes have arrived. Unchanged audio is not reread. The 30,000-file stat microprobe took 0.57–1.03 seconds; the complete startup path must still meet the original performance acceptance checks.
