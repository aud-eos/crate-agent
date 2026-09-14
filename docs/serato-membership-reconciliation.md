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

Pending explicit imports survive absence. A saved old path also protects a
currently applicable rename when its membership revision still matches, its
destination is the verified indexed file, and its original location is missing.
Prior-membership rename events do not grant permission after reactivation.

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

The engine retains the last successfully authorized external metadata observation
per file/revision for the lifetime of its in-process queue, including unchanged
observations. Each queued V2 edit captures that baseline separately from SQLite's
local intended values. Saved `A` followed by queued `B` and unchanged saved `A`
allows `B`; a later saved `C` or clear supersedes only affected older V2 fields.
Unknown baselines report uncertainty/conflict rather than inventing newer external
ownership. The observation journals affected `uncertainV2Fields` separately from
proven raw external changes. History fences older V2 projections across those
fields and visibly counts their supersession; retry does not grant them fresh
authority. Independent fields and audio-tag writes retain their own authority.
Successful own V2 writes advance the external baseline; a real drain is followed
by a fresh strict read and metadata scan before readiness can reopen.

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
application routes these requests through the same serialized session as startup
and Serato exit, including snapshot-authorized scanning and outbound drain. The
session never waits on the filesystem processor. A filesystem failure remains
latched across automatic Serato-exit requests. Retry Sync permits only strict
read/reconcile/scan while the retained processor head is being recovered; it cannot
drain queued writes, reopen normal readiness, or start the worker in that scope.
Only successful replay and checkpoint clear the latch. A fresh normal session then
drains and schedules work, avoiding both a cyclic wait and a premature ready state.

At startup the watcher captures events immediately, but its processor buffers
delivery and checkpoints until `initialSyncComplete` and the session is idle.
This establishes migrated legacy membership from the saved old V2 paths before
replaying renames. Waiting for Serato or a failed initial pass leaves the buffer
paused; a successful retry opens it once. AppServices owns and cancels the startup
wait task; cancellation is checked again after the session becomes idle, before
any buffered replay. The processor owns pending delivery,
so startup does not wait for a filesystem handler that can itself request sync.

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
the gate's generation before stopping work or reading a new snapshot. Ordinary
mutation transactions and fingerprint persistence verify the captured generation
before and after their transaction work; invalidation during an update rolls back
the transaction. Decoder failure persistence uses the same guard, and supersession
remains a stopped result rather than a new row failure. Together these checks mean
a close/reopen cannot authorize old work. Explicit import intent and verified local
filesystem observations remain possible, while external writes queue. Only the
session's scoped drain authorization can write before normal readiness opens.
Serato launch during a sync cancels it and leaves queued intent intact. After an
already validated session, Serato being open permits local processing with outbound
writes queued; initial startup while Serato is open never enables processing.

Main window and menu bar share waiting, reconciliation, result, and failure status
with Retry Sync. Missing or corrupt source errors retain queued writes. Unexpected
worker database errors stop processing and publish a monitored failure. Readiness
supersession is cancellation, not a decoder or database failure. A successful retry
starts a new worker generation. Initial completion becomes true only after the
whole sequence succeeds.

Synchronization acknowledgements belong to the latest requested generation, not
an earlier successful pass in a coalesced task. Scheduling must finish with the
same authorization and no newer request before publishing initial completion or
ready. A later failed pass cannot acknowledge a required filesystem reconciliation
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
This work does not implement the general durable queue (#110) or change shared
recording ownership rules (#113).

## Physical effects and duplicate cleanup

Queued effects retain their original file identity and membership revision. The
shared final writer boundary resolves a verified move to the current audio target,
checks the actual target and original content intent, and rechecks after journal
lookups under writer serialization. Ordered reference renames retain their explicit
path transition; an unrelated occupant of an old path cannot authorize rewriting
or removing that occupant's V2/crate references. Expected supersession removes only
the obsolete queued work; unexpected I/O failure stays visible and retryable.

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
This bookkeeping is in-process and does not implement durable queue recovery.

Physical move rollback and retained-source cleanup use `OwnedAudioIdentity`:
precise device/inode/size/mtime/ctime plus a streaming SHA-256 digest of every byte.
Native copying remains bound to the opened source and exclusively created
destination. Changed or unowned files are retained with an error, including middle
edits within the same timestamp second. Digest reads use bounded memory on the
writer's execution context and only touch files participating in a move; browse
and full-library snapshots do not hash every audio byte.
