# Saved-library reconciliation

`SeratoMembershipReconciler` consumes the records from one strict, stable
`database V2` snapshot. Missing/corrupt sources are errors, never empty libraries.
An encoded valid empty library can retire online members owned by that library.
Crate membership does not participate in this decision.

The reconciler reads identity projections in pages of 256, without fingerprint
blobs, and checks only indexed locations and paths in the saved snapshot. It does
not enumerate a music folder or Trash. Ownership mismatches and offline volumes
cannot retire a row. File availability is recorded independently of membership.
Retirement retains file ID, recording association, fingerprint, and History.

Availability checks continue past UUID lookup failures for individual mounted
volumes. A successfully inspected matching volume establishes that the target
volume is online; no match leaves it offline. Failure to enumerate mounted
volumes still surfaces as an error, and target-path errors retain their existing
missing/inaccessible/error classifications.

Pending explicit imports survive absence. A saved old path also protects a
currently applicable rename when its membership revision still matches, its
destination is the verified indexed file, and its original location is missing.
Prior-membership rename events do not grant permission after reactivation.

Explicit import accepts an unknown historical content hash only when normalized
path, volume, inode, size, and modification time still match. The transaction
verifies the current file again and journals the hash backfill before import
intent. A known unequal hash or any other identity mismatch rejects the import.
This compatibility rule does not relax exact prior-identity observation guards.

The historical `unknown-volume` sentinel has a separate repair path: a readable
indexed location must pass the same retained attribute checks before its verified
real volume is adopted through a journaled observation. Adoption preserves the
recording and fingerprint and allows ordinary membership activation. Missing
sentinel locations remain unresolved/offline; arbitrary unknown volume IDs are
never adopted, and mismatched identities produce a visible ambiguity error.

A saved new path can retain a known file ID only through unique physical or
content identity and a missing old location. Case-only spellings on a filesystem
that reports case-insensitive names are accepted only when both paths still
resolve to the same verified physical/content identity. The planner and journal
transaction share this check. Ambiguous paths, distinct hard links with the
original still present, and conflicting candidates throw an actionable sync
error instead of choosing an association. Same-path replacements use a journaled
identity observation: the previous complete file record is retained in the inverse
payload, the file's recording link and fingerprint cache are cleared, and its
membership revision advances. Shared recording rows remain intact. Identity and
membership observations are informational History entries with no Undo or Re-sync
permission to write obsolete content.

Audio verification follows symbolic links to regular files and checks precise
directory-entry and target identities plus the resolved target path across the
read. Repointed links, changed targets, broken links, and nonregular targets fail
verification. This does not relax the strict `lstat` rule for `database V2`, or
the native move transaction's ownership of its opened regular source.

`lastProjectionInvalidationRevision` permanently fences unversioned historical
projections after retirement, replacement, or an observed re-add following a
registered cleanup's confirmed V2 removal. Initial legacy activation
alone does not set this fence. Modern projections always require an exact
membership revision. The field and migration are new on this unshipped branch;
the generalized name replaces the earlier retirement-only name.

## Consumer contract

`SeratoLibrarySyncSession` reads one snapshot, reconciles it, and calls
`LibraryScanner.scan(snapshot:reader:)` before draining outbound writes. A drain
can legitimately change `database V2`; consumers that scan after draining must
read a fresh strict snapshot. The snapshot overload uses only the supplied
records and journals guarded metadata/derived identity observations. Its legacy
`scan(progress:)` overload is a separate compatibility entry point and does not
provide this authorization contract.

Snapshot scanning applies the reconciler's library-owner check before observing
an existing row. An active, available row owned by another library remains
unchanged and is counted as skipped. Unowned legacy rows acquire membership
through reconciliation before metadata scanning.

The engine persists the last successfully authorized external metadata observation
per file/revision in `serato_external_baselines`, including unchanged observations;
the published checkpoint's evidence is the fallback when no row exists yet. Each
queued V2 edit captures that baseline in its own queue row, inside the mutation
transaction, separately from SQLite's local intended values. Saved `A` followed by queued `B` and unchanged saved `A`
allows `B`; a later saved `C` or clear supersedes only affected older V2 fields.
Unknown baselines report uncertainty/conflict rather than inventing newer external
ownership. The observation journals affected `uncertainV2Fields` separately from
proven raw external changes. History fences older V2 projections across those
fields and visibly counts their supersession; retry does not grant them fresh
authority. Independent fields and audio-tag writes retain their own authority.
Successful own V2 writes advance the external baseline in the same transaction
that removes their queue row, so a later own write to another file cannot make the
baseline unknown. A real drain is followed by a fresh strict read and metadata scan
before readiness can reopen.

Identity observations carry raw previous/current external metadata as well as the
local projection. History uses their actual changed fields, including clears, as
new V2 ownership. An external change is journaled even when SQLite already shows
that value; unchanged co-imported fields do not acquire ownership. These events
never claim audio-tag ownership. An owned successful tag write instead journals
its verified physical identity and fingerprint basis, preserving revision,
recording links, and Serato-mirrored metadata. Genuine replacements still invalidate
the prior association.

`reader.authorization(for:)` captures source identity, the reader's latest
generation, and the watchdog's closed lifecycle revision. The engine's
`applyObservedBatch` checks this authorization inside its serialized transaction
both before and after executing mutations; a failed check rolls the batch back.
Identity, expected membership revision, and expected availability/membership are
also checked when metadata observations commit. Starting a newer read invalidates
an older authorization even when source bytes and membership revisions match.

Reconciler batches preflight every observed row's prior physical identity, library
state, and membership revision before applying any mutation. This rejects a
same-revision filesystem location/availability update that arrived after the
decision, including when the planned availability is missing or offline. The
preflight precedes the batch's own identity refresh so that a verified move and
its state update can still commit together. Pending rename decisions use verified
current availability; a stale cached missing/unknown flag cannot cancel a restored
same-file rename.

`reconcileRequestedFilesystemChanges()` supplies one bounded reconciliation pass
for a coalesced filesystem request. The filesystem consumer owns retaining a
failed request/batch and advancing its checkpoint only after success. The running
application routes these requests through the same serialized session as the
user-requested file-info scan, including snapshot-authorized scanning and outbound drain. The
session never waits on the filesystem processor. A filesystem failure remains
latched until an explicit retry. Retry Sync permits only strict
read/reconcile/scan while the retained processor head is being recovered; it cannot
drain queued writes or reopen normal readiness in that scope. Only successful replay
and checkpoint clear the latch. A fresh normal session then drains and schedules
state-changing work, avoiding both a cyclic wait and a premature ready state.

Startup automatically validates the saved library while browsing stays available.
The watcher starts immediately; its processor buffers delivery and cursor updates.
A native boundary orders callbacks that have actually arrived. Native tests showed
that a flush can finish before a file change is delivered, so boundary completion
alone is never physical evidence: cached files also pass precise stat and volume
validation. Later delivered events invalidate an in-progress startup candidate.
The startup coordinator handles captured observations without recursively invoking
the session, then releases normal delivery only after successful validation.
Conflict-blocked observations retain their cursor dependency. Serato closing starts
another incremental pass. **Re-scan File Info** forces file-info reads; Retry retains
the failed request mode. Stop leaves the last committed browsing state available.

Production setup resolves the watched music folder's applicable native Trash
directory once, creating that directory if necessary, and watches the normalized,
deduplicated music and Trash paths in one stream. This captures native Trash
destinations without enumerating Trash or scanning it per missing row. A verified
Trash destination marks the indexed original path as trashed; it never becomes a
V2 rename target. Root derivation and stream creation/start failures fail startup
visibly. The checkpoint key includes the complete watched-path set. Until the
first checkpoint for that set, the old music-root cursor is a conservative replay
fallback; checkpoints advance only after the combined batch succeeds. Watch roots
are fixed for the AppServices lifecycle and reconstructed on the next startup.

A destination-first copy/move observation retains a verified candidate against
the original indexed file's revision, state, and identity. A live source remains
a copy. The first discovery also captures the source's precise read identity.
Later observations of that available source, including repeated destination
events, compare against the original identity. In-place drift discards the
candidate and requests reconciliation even when size, whole-second mtime, and
sampled content hash are unchanged; it never renews the candidate's authority.
The rejected original precise source identity is retained per file ID as a fence.
Later destination events request reconciliation without creating new move
authority for that row during the coordinator's lifetime, since the coordinator
cannot establish a refreshed precise source baseline from the scanner's coarse
identity projection. An unverifiable live source also discards and fences its
retained authority before reporting a verification error.
For a still-authorized candidate, source disappearance revalidates the destination
and commits the move through the engine, checking original authority inside the serialized
transaction and physical targets again before commit. Replacement, retirement,
or changed/missing destinations discard that candidate and request reconciliation.
A strict observation of an active source becoming missing is allowed progress
only while its original revision, owner, and physical identity remain unchanged;
it does not grant a replaced or reactivated row new move authority.
Pending state is keyed by known file ID with at most two destinations per entry;
the second represents ambiguity and stops checkpointing visibly. Retry can prune
invalid destinations, but cannot choose between two remaining candidates. This
observation state is in-process; it does not implement durable queue recovery.

The session installs a closed readiness gate before service startup. It invalidates
the gate's generation before stopping state-changing work or reading a new snapshot.
Ordinary mutation transactions verify the captured generation before and after their
transaction work; invalidation during an update rolls back the transaction. Together
these checks mean a close/reopen cannot authorize old mutations. Explicit import
intent and verified local filesystem observations remain possible, while external
writes queue. Only the session's scoped drain authorization can write before normal
readiness opens. Fingerprinting starts as an independent background task, waits
while source validation keeps readiness closed, and resumes automatically when the
gate opens. It reads only active, available, unconflicted rows and checks both the
sync generation and each row's membership token when persisting. A concurrent
conflict, retirement or identity change rejects stale results; a sync pause does
not terminate the worker or require a manual fingerprint retry.
Serato launch during a sync cancels it and leaves queued intent intact. After an
already validated session, Serato being open permits local processing with outbound
writes queued; initial startup while Serato is open never enables state-changing processing.

A Serato launch notification closes the locked external-write gate and advances its
revision together, before publishing the running state. Launch evidence remains
until the corresponding process's termination notification, so a lagging process-list
refresh or another instance sharing its bundle ID cannot reopen the gate.
Termination refreshes the process list and keeps writes
blocked while any other notified or observed Serato application remains running.

Main window and menu bar share waiting, reconciliation, result, and failure status
with Retry Sync. Missing or corrupt source errors retain queued writes. Fingerprint
worker database errors appear in the Library header and activity log without changing
file-info scan state; **Retry Fingerprinting** restarts only that worker. Initial
completion becomes true only after the whole scan sequence succeeds.

Synchronization acknowledgements belong to the latest requested generation, not
an earlier successful pass in a coalesced task. State-changing processing scheduling
must finish with the same authorization and no newer request before publishing
initial completion or ready. A later failed pass cannot acknowledge a required filesystem reconciliation
or advance its checkpoint. Validation-only filesystem retry records its successful
generation independently of the normal ready state.

Completed Auto-Tag reviews survive successful synchronization when original file
revision, identity, and freshness checks still pass. New explicit alternative
requests capture the current session epoch but retain the candidate's original file
token. In-flight lookup/decode/persistence keeps its original epoch. This permits
review persistence without granting retired or replaced candidates new authority.

Successful explicit adds and snapshots use the same volume UUID plus canonical
directory ownership identifier. Add confirmation remains the engine's existing
`import-confirmed:<eventID>` transaction. Failed adds retain pending membership.
An immediate add failure also retains the original guarded add as a durable
`serato_write_queue` row and reports a pending-sync import result. The Library drop flow publishes
the failure through the shared sync status and Retry Sync action. Retry performs
the external add and normal confirmation without repeating import intent or
changing the original event payloads/inverses. Failed or unattempted adds are
retained once per event; already completed adds are not queued again. The normal
membership, physical-target, and Serato-running checks still apply, so changed,
retired, or removed audio supersedes the old request. A new explicit drop can
establish new intent under the existing membership-revision rules; the older row
it supersedes no longer blocks the new import. This work does not change shared
recording ownership rules (#113).

## Physical effects and duplicate cleanup

Queued effects retain their original file identity and membership revision. The
shared final writer boundary resolves a verified move to the current audio target,
checks the actual target and original content intent, and rechecks after journal
lookups under writer serialization. Ordered reference renames retain their explicit
path transition; an unrelated occupant of an old path cannot authorize rewriting
or removing that occupant's V2/crate references. Expected supersession removes only
the obsolete queued work and records a `serato_write_dispositions` row so the drop
stays visible after a restart; unexpected I/O failure stays visible and retryable.

Coalesced metadata and consecutive rename groups retain each physically rejected
event's identity. The engine rebuilds the FFI payload from the still-eligible,
ordered survivors and rechecks them at the serialized writer boundary. Valid
survivors stay coalesced; a Serato restart queues them for guarded completion.
Rejecting one target never discards or reports supersession for its valid siblings,
and retrying the external subset does not repeat the local mutation journal.

Duplicate cleanup retains the original keeper and target authority for every step.
V2 removal, both crate forms, and Trash must actually complete before it reports
completion. The row remains while external work is pending or failed; its final
audited deletion runs in the successful Trash writer transaction. A failed crate
does not prevent attempts on other crates, but any failed crate blocks Trash.
An immediate external failure retains the already-journaled guarded write in the
existing queue and publishes the existing Sync failure/Retry Sync surface. Normal
sync leaves it failed; explicit Retry Sync resumes after fresh strict authorization,
without re-journaling the mutation or renewing the original plan.

Only a registered sequence with a confirmed own V2 removal may retain an absent
member during reconciliation. An unstarted queued removal has no exemption.
Retirement, replacement, a changed keeper, or a saved re-add cancels old cleanup.
A re-add after confirmed own removal journals an active-to-active revision and
permanent History fence without inventing retirement or altering recording/audio.
Pending, completed, failed, and superseded counts remain visible in sync status.
The sequence is durable in `duplicate_cleanup_intents`: each step's mutation,
queued effects, and intent update commit together, the confirmed V2 removal is
recorded in the removal transaction, and the Trash transaction also deletes the
row and the intent. A restart resumes the cleanup at its recorded step. If the
process exited after Trash moved the target but before that transaction committed,
the next sync finishes the cleanup from the attempted trash row instead of retiring
the target. Cancellations found during reconciliation are reported in the ready
summary.

Physical move rollback and retained-source cleanup use `OwnedAudioIdentity`:
precise device/inode/size/mtime/ctime plus a streaming SHA-256 digest of every byte.
Native copying remains bound to the opened source and exclusively created
destination. Changed or unowned files are retained with an error, including middle
edits within the same timestamp second. Digest reads use bounded memory on the
writer's execution context and only touch files participating in a move; browse
and full-library snapshots do not hash every audio byte.


## Unicode path conflicts and guided repair

A strict saved snapshot is analyzed before reconciliation, scanning, or queue
drain. Every occurrence is retained, including byte-identical repeated records.
Canonical path comparison groups Unicode-equivalent spellings, while diagnostics
preserve original UTF-8 bytes, metadata, and physical-file observations. Only
conflicted spellings are inspected for diagnostics; analysis does not decode audio
or fingerprint the library.

The conflict scope protects indexed file IDs, normalized source/destination and
historical reference paths, and volume/inode aliases. Operations writing a shared
recording row also check its track ID. Presence evidence still includes every
saved record, so excluded files are not falsely retired. Mutation transactions
check scope before and after work; queued physical effects check again immediately
before I/O. The global epoch still stops all processing for an invalid source,
cancellation, or Serato launch.

A ready session can contain conflicts. Fingerprinting and Auto-Tag skip protected
files without marking their audio failed; late results cannot commit. Import
reports blocked files separately from infrastructure failures. Previews retain
blocked rows with an explanation and exclude them from mutation selection.
Filesystem delivery retains blocked observations and holds its checkpoint while
later independent observations proceed. Repair retry replays retained observations
through current identity checks.

Queue draining makes a bounded pass over the durable queue in FIFO order. Protected
entries and later dependent entries remain in order; independent writes can proceed.
A blocked entry is not superseded. A failed entry records its error and blocks only
its dependents; the pass continues and then reports the failure. Rows are deleted in
the transaction that commits their I/O, so a replay after a crash finds nothing to
redo, and an attempted audio-tag write or Trash whose target then changed is
reported as interrupted instead of being repeated. Completing a queued V2 edit
rebases later queued edits of the same file onto the values it wrote, and a strict
observation treats a saved value equal to an earlier queued edit as that edit
landing, so the newest edit still applies after an interruption. A queue row or
pre-upgrade fence that no longer decodes is removed with a `malformed`
disposition; the rest of the queue still applies. Only one pass runs at a time:
a scoped pass leaves a row that depends on an unfinished earlier row for the
next drain, and with Serato closed that drain waits for the next sync, so a rename
made during another pass on the same file waits for that pass instead.

The pass groups eligible rows into segments in queue order. Every V2 metadata
edit joins one rewrite unless a rename, add, or V2 removal queued since that
rewrite opened touches the same file or path; then it starts a new rewrite after
that row. Consecutive renames share one path batch, which applies them in order:
a rename of an earlier rename's destination (old → middle → new) lands the record
at the final path. Consecutive adds of different files share one registration:
Serato's existing paths are read once, every add lands in one V2 rewrite, and
each import is confirmed in the same transaction; a second add of the same file
starts a new registration. Every other write is its own segment. Edits to the same record are merged in queue order before the batch
writer, which keeps only one update per path. A strict observation also treats a
saved value equal to a later queued edit of the same file as our own coalesced
write, so it is neither reapplied nor reported. Both landed-write rules apply only
to rows whose last attempt recorded no error: a saved value matching an unsent
edit, or one whose write threw, is the user's own Serato edit and wins. A failed segment fails all of its rows together
and blocks their dependents; a row whose target becomes conflicted at the write
boundary is blocked alone with its dependents, and the rest of the segment applies.

A file with a queued rename is observed at the path Serato still holds: the
record at the oldest pending rename's old path supplies that file's saved
metadata, so a Serato edit made there is kept rather than overwritten by the
rename. When Serato holds records at both the old and the new path, the rename
is a path conflict: it appears in **Review conflicts** and its writes stay queued.

When no baseline was observed, a queued edit takes the pre-edit values its event
journaled (`previousMetadata`) as the baseline for the fields it writes; a field
an earlier queued edit still owes takes that edit's baseline instead. A queued
edit whose baseline is still unknown learns the fields of an earlier edit of ours
once that edit lands, so it applies instead of being dropped as uncertain. An interrupted cleanup Trash finishes on restart only when its last
attempt left no error; a failed Trash attempt is not proof the audio moved.

A metadata update whose path the parsed `database V2` has no entry at, or a
rename whose track neither `database V2` nor any crate holds at its final path
afterwards, completes as `noSeratoRecord` in the transaction that removes its
row, and does not advance the external baseline: the Rust batch writers report
each unmatched path, so a write with nothing to change is told apart from one
with no entry, and Re-sync counts it as not written (#105). A missing
`database V2` is not evidence that a track is absent and keeps its tolerant
behavior.

The ready summary reports each dropped change by disposition (superseded,
uncertain, interrupted, malformed, legacy unrecoverable, or no Serato entry) once, and turns to a
warning. An outcome this version does not recognize, such as one recorded by a
newer build, is counted as not applied rather than blocking readiness. History marks a batch with the number of its changes that were not
applied.
After repair, normal membership revision, physical identity, and external metadata
baseline rules determine which retained intent is still applicable. Unrelated V2,
Subcrates, and SmartCrates rewrites preserve duplicate records and opaque TLVs.

**Review conflicts** opens a dedicated list and detail screen. Details remain
visible while another sync is pending or fails. **Copy conflict details** exports
only on click. **Show in Finder** rechecks the selected occurrence's physical
identity; **Open Serato** is also explicit. Guidance distinguishes no verified
live file, aliases of one physical file, distinct files, and inaccessible or
unknown locations. Restore access before declaring a reference stale; preserve
intended audio, metadata, and crate membership. Remove only verified unwanted
library references without deleting audio, save and close Serato, then retry.
Counts clear only after a current validated snapshot proves repair.

Direct strict scanner/reconciler callers derive and install protection but cannot
open global readiness. The legacy scanner rejects ambiguous records rather than
choosing a winner; use the strict session for partial synchronization.


## Incremental checkpoint

Schema-only migrations add versioned saved occurrences, file evidence, a slim stat
projection, dirty-row tracking, durable physical-move fences, and the durable Serato write queue. Raw path bytes
and occurrence multiplicity are preserved. SQLite triggers advance a revision for
relevant file changes; fingerprint progress alone does not invalidate the cache.

An unchanged pass reads the header and slim stat projection, validates entry/target
identity and volume UUID, checks source identity and the database revision, and
opens readiness under the serialized writer. It does not parse V2 or reread audio.
Symlink targets are checked even outside watched roots. Uncertain files use strict
verification. Prior conflicts always receive fresh analysis.

Changed sources are compared with the last external metadata projection, separate
from local metadata. Metadata-only observations use the mutation/event/inverse
chokepoint with precise file evidence and a commit-time metadata check. Unchanged
external fields preserve local edits, including during forced refresh. Audio-derived
values record their evidence basis; a successful absent bitrate is distinct from a
failed probe. Probe failures remain visible and are retried instead of being cached
as success. A later local Serato write loads its original baseline by file token
without loading the complete metadata cache. Unknown interrupted-write baselines
remain unknown.

Publication checks the expected local revision, current source authorization,
unfinished physical-move fences, and the Serato write queue: it requires an empty
queue, and opening readiness without publishing allows only the rows the drain left
blocked by path conflicts. Per-session accounting identifies its own observation
writes; unrelated concurrent changes invalidate the candidate. Unresolved durable
fences surface an explicit Retry Sync / History recovery error and are never cleared
merely because a read succeeded. Pre-upgrade `event:<id>` fences are recovered at
the start of each sync: a replayable event is rebuilt into queue rows from its
journal, a destructive one is recorded as `legacyUnrecoverable`, and the fence is
deleted in the same transaction. The checkpoint is derived evidence; queued intent
lives in the queue.
