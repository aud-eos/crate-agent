# Saved-library reconciliation

`SeratoMembershipReconciler` consumes the records from one strict, stable
`database V2` snapshot. Missing/corrupt sources are errors, never empty libraries.
An encoded valid empty library can retire online members owned by that library.
Crate membership does not participate in this decision.

Only `read_database_records_strict` (`DatabaseV2::strict_track_records`) may supply
evidence that something is absent from Serato. The permissive
`read_database_records` / `track_records` path silently skips `otrk` entries without
a `pfil`, and the legacy `LibraryScanner.scan(progress:)` turns a missing
`database V2` into an empty record list. Both are acceptable for display-only imports and
wrong for retirement, duplicate cleanup or any other decision that a track is no
longer in Serato.

The reconciler reads identity projections in pages of 256, without fingerprint
blobs, and checks only indexed locations and paths in the saved snapshot. It does
not enumerate a music folder. It lists a volume's Trash at most once per pass, and
only for a row whose indexed path is gone with no verifiable recorded Trash item
(see below). Ownership mismatches and offline volumes
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

Because owned tag writes leave the mirrored columns alone, undo and redo of a
MusicBrainz match guard their audio-tag inverse by the file itself
(`MatchUndoTagGuard`). Before the transaction, each matched file's tags are read
under an `AudioFileReadIdentity`. Every field the match wrote must still hold the
matched value or the pre-match value; any other value is a later edit, and the undo
is refused for those fields only. The transaction rechecks that identity, so a file
that changes after the read fails the undo, and nothing commits. A queued apply that
never reached the file still undoes, because its file holds the pre-match value.

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
V2 rename target. The verified Trash item (path, volume, inode, size, mtime and sampled
content hash) is persisted in `file_trash_locations` by the same journaled
library-state mutation. Without Full Disk Access a Trash item can be stat-able but
unreadable; it is then recorded by its stat identity alone, and later checks compare
only the fields that were captured, so a permission failure never reads as an
emptied Trash. Verification lives in `FileTrashLocation`: stat identity (volume,
inode, size, mtime) is compared first, so a replaced or emptied item is `missing`
without being read. Content is compared only when a hash was recorded and the item
can be opened, and it is hashed through that open descriptor after confirming the
descriptor is the stat-checked item, so a replacement between stat and read is
never hashed in its place; an item that vanishes mid-check is `missing`. Only `EACCES`/`EPERM` fall back to stat identity; any other read
failure is an error. An item whose identity cannot be read reports `inaccessible`,
never `missing`. Stat-only identity relies on APFS/HFS+ file IDs, which are not
reused. The mutation clears the item when the row becomes available or missing
(restore, re-import, replacement). It keeps the item through offline and
inaccessible, which say nothing about whether the item still exists, and accepts a
location with those states so every logged inverse can be applied. A write that
repeats the row's state and supplies no new location is a no-op and verifies
nothing. A change to `.trashed` rechecks existence and stat identity inside the
transaction, because Trash can be emptied while the caller awaits the commit. A
row whose own indexed path is in Trash counts as trashed only while that path holds
the row's volume and inode, both when reconciling and under the lock; otherwise the
recorded item, if any, decides. Callers pass the
item they verified, so the event records which item justified it. A failed recheck
is row-level staleness (`FileTrashLocationError.itemChanged`): the filesystem
coordinator requests reconciliation, and the reconciler counts the row in the sync
summary ("changed in Trash, checked next sync") and leaves it out of the published
checkpoint evidence, so the next sync re-checks it instead of taking the fast path;
neither fails its batch. A known path that now holds a
different file requests reconciliation; a missing or trashed row keeps its state
until then, and an available row becomes `unknown`. A removal
event at that Trash path, or any reconciliation that finds the indexed path
missing, keeps the row trashed only while that exact item still verifies;
otherwise it becomes missing. Events are not the only evidence of a Trash move. A
volume attached with `-nobrowse` (or any volume without an FSEvents store) keeps no
event history, so a move made while crate-agent was not running is never replayed.
A trashed folder reports only a directory rename, which requests reconciliation.
So when reconciliation finds an indexed path gone and no recorded item verifies,
`NativeTrashIndex` lists that volume's Trash recursively, once per pass. An item
with the row's inode that `FileTrashLocation.capture` verifies marks the row trashed
(#234). A Trash that cannot be fully listed, for example without Full Disk Access,
leaves the row missing but counts it in `trashUncheckedFileIDs`: the sync banner
reports it with a warning, and the row stays out of the checkpoint so a later sync
searches again. A trashed row
without a persisted item (recorded before this table existed) cannot be verified
and also becomes missing. An unrelated Trash item's removal never matches the row. Root derivation and stream creation/start failures fail startup
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
worker database errors appear in the Library header, Workers, and activity log without
changing file-info scan state; **Retry Fingerprinting** in Workers restarts only that worker. Initial
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
`serato_write_queue` row and reports a pending-sync import result. A drop journals
each file in its own batch, so each stays separately undoable, then applies all of
the drop's queued adds in one scoped pass. Consecutive adds share one `database V2`
rewrite per 200 files, and each file's result comes from its own queue rows and
dispositions (#187). A file that changes before its add runs is reported as not
added and stays pending, with no Retry Sync, since nothing is left to retry;
dropping it again observes the changed file and starts a new import. Only an
import that never finished (pending or legacy-unverified) adopts a changed file
this way: a retired or removed row still refuses a replacement at its path. When
readiness is closed, that observation is refused and the file is reported with
the readiness reason. A file listed twice in one drop, such as a folder and a
file inside it, is imported once, and a file a still-running drop is importing
is reported as already being imported by an overlapping drop, as a notice
rather than an error. A file whose import mutations fail is never counted as
skipped: one that changed between its stat and its import is reported as not
added, and any other failure, such as an ambiguous legacy identity, is listed
with its reason (#229). The Library drop
flow publishes a failed add through the shared sync status and Retry Sync action. Retry performs
the external add and normal confirmation without repeating import intent or
changing the original event payloads/inverses. Failed or unattempted adds are
retained once per event; already completed adds are not queued again. The normal
membership, physical-target, and Serato-running checks still apply, so changed,
retired, or removed audio supersedes the old request. A new explicit drop can
establish new intent under the existing membership-revision rules; the older row
it supersedes no longer blocks the new import. This work does not change shared
recording ownership rules (#113).

### Serato History play counts

`serato_play_counts` is derived external evidence, like the fingerprint and
audio-digest caches. It is not a mutation and does not bypass invariant 1: there
is no user intent to journal and nothing to undo. `SeratoPlayCountService` only
reads `_Serato_/History`, and never writes `files`, tags or any Serato file.

- **When it refreshes:** each sync reaching `.ready` (at startup, after Serato
  quits, and after filesystem-driven reconciliations) asks for a refresh, but
  History is parsed again only when its inputs changed since the last read: the
  `Sessions` files' names, sizes and modification times, or the library's path
  history (file count, highest file id, and highest path-change event id). A
  failed read records its inputs too, so a corrupt session is not re-parsed on
  every sync; it is retried once History or the library changes. While Serato
  runs, the refresh is skipped and the last table kept. A read during which the
  watchdog's lifecycle revision changed is discarded, so a session Serato may be
  appending to is never trusted.
- **How it parses:** the Rust parser (`read_serato_history`) reads
  `History/Sessions/*.session` strictly. The parse needs the `vrsn` header, then
  only `oent` records with one `adat` each. Each `adat` needs a played flag
  (field 50), and played entries also need a UTF-16 path (field 2) and a start
  time (field 28).
  - Loaded-but-unplayed entries are counted and skipped.
  - Entries whose path is not absolute, such as streaming tracks
    (`_783160.beatsource`), are skipped by that rule and counted as non-file.
  - AppleDouble sidecars (`._*.session`) hold Finder metadata, not sessions,
    and are skipped by name.
  - A session file over 64 MiB fails the read before it is loaded.
  - Any other structure fails the whole read, naming the session file. Workers
    shows the error, Duplicates notes that play counts may be out of date with
    the same reason, and the previous table is kept.
- **How plays are attributed:** a play counts for the file that was at its path
  when it started. Each file's past paths come from its `file_renamed`,
  `file_location_observed` and `file_identity_observed` events, chained in
  journal (`event_id`) order. Each event's old path covers the time since the
  previous change, and the current path covers the time since the last one.
  - Event times are when crate-agent applied or noticed a change, not when the
    file moved on disk: a move made while crate-agent was not running is dated
    at the next scan, so plays between the move and that scan count at the old
    path.
  - A file's first-seen path covers all earlier time, so plays from before the
    file was indexed count for it if it was at that path then.
  - Paths are compared by `SeratoPath.normalized`, so History's absolute paths
    match V2's root-relative ones, and NFD matches NFC. Comparison is
    case-sensitive, like the rest of the app's path matching: on a
    case-insensitive APFS volume, a play Serato logged under different letter
    case than the file's path is unattributed (a known undercount).
  - A play at a path no file held then, or that two files claimed at that
    moment, is unattributed. It is counted in the Workers summary and the log,
    and never guessed.
- **How it is stored:** parsing runs off the database, and attribution (the
  event fetch, decode and per-play lookup) runs in a read transaction. The write
  transaction only re-checks the library path signature and applies the
  difference: rows for files whose count changed, and deletions for files that
  no longer have plays. When the counts equal the stored ones, nothing is
  written, so open views observing the table, such as Duplicates, do not
  rescan. If the library's paths changed between attribution and the write,
  the write is skipped and the refresh runs again. On 30,000 files with 65,000
  path-change events, no writer wait exceeds the 500 ms budget
  (`SeratoPlayCountPerformanceTests`).
- **How it is used:** `DuplicateKeeperPicker` ranks most plays between the
  bucket match and the oldest mtime. Duplicates rows show "N plays".

## Physical effects and duplicate cleanup

Queued effects retain their original file identity and membership revision. The
shared final writer boundary resolves a verified move to the current audio target,
checks the actual target and original content intent, and rechecks after journal
lookups under writer serialization. Ordered reference renames retain their explicit
path transition; an unrelated occupant of an old path cannot authorize rewriting
or removing that occupant's V2/crate references. The one exception is a chain or
swap within one drain pass: when a later rename moves a different file into an
earlier rename's old path, the earlier rename skips the old-path occupancy check,
even when the two land in different bounded segments. It keeps every other
identity check. A rename that some store already took also skips that check, so
it finishes in the rest. When a rename is dropped, the same transaction drops every
later queued rename into its old path, because the record there never moved
(#199), and the same file's later queued writes that reference the dropped
rename's new path, because another file's record may still sit there. Each
drop is transitive, compared by `SeratoPath.normalized`, and records its own
disposition; an indexed `rename_new_path_key` keeps the cascade linear in the
queue. The exception is an old path that the same file's latest earlier rename
never reached, because that rename was dropped while another record still held
its new path (`new_path_held`): no record waits there. A rename that V2 took counts as
arrived. Expected supersession removes only
the obsolete queued work and records a `serato_write_dispositions` row so the drop
stays visible after a restart; unexpected I/O failure stays visible and retryable.

Coalesced metadata and consecutive rename groups retain each physically rejected
event's identity. The engine rebuilds the FFI payload from the still-eligible,
ordered survivors and rechecks them at the serialized writer boundary. Valid
survivors stay coalesced; a Serato restart queues them for guarded completion.
Rejecting one target never discards or reports supersession for its valid siblings,
and retrying the external subset does not repeat the local mutation journal.
`serato_rename_progress` records, in each store's writer transaction, which
queued renames V2 and each crate already took. A retry after supersession,
failure or restart rewrites only the stores a rename has not reached. Applying a
landed chain or swap a second time would move its records again. A store rewrite
that lands just before a crash, ahead of its transaction's commit, is applied
again on restart. With WAL and `synchronous=NORMAL`, a power loss can also drop
a committed progress row while the rewritten store survives.

File removal runs one durable four-step sequence. `resolveDuplicate` starts it
with a `.duplicateOf` keeper and evidence requirement, and
`OperationEngine.removeFile(target:batchID:)` starts it with `.ownerChoice`, for a
file the owner removes with no keeper. Each queued step write carries its intent's
`RemovalAuthority`; a write whose intent is gone is orphaned, keeper or not.
Duplicate cleanup retains the original keeper and target authority for every step.
V2 removal, both crate forms, and Trash must actually complete before it reports
completion. The row remains while external work is pending or failed; its final
audited deletion runs in the successful Trash writer transaction. A failed crate
does not prevent attempts on other crates, but any failed crate blocks Trash.
An immediate external failure retains the already-journaled guarded write in the
existing queue and publishes the existing Sync failure/Retry Sync surface. Normal
sync leaves it failed; explicit Retry Sync resumes after fresh strict authorization,
without re-journaling the mutation or renewing the original plan.

Duplicate cleanup needs full evidence, not the scan's candidate key. A byte-level
group (same size, same first and last megabyte) is confirmed only by
`OwnedAudioIdentity`'s SHA-256 of every byte, cached in `file_content_digests`.
Files sharing a 120 s fingerprint can be different versions (Clean and Dirty
edits), so perceptual groups need decoded audio: `decoded_audio_digest` caches, in
`file_audio_digests`, a SHA-256 of the native PCM sample bytes (integers widened
losslessly to 32 bits, floats kept at their width, each tagged with its sample
format, plus the sample rate and channel count, and a marker with the packet
timestamp for every packet the decoder skipped), its container/codec, its decoded
duration and a hash of its full-length fingerprint.

Play, Open and Reveal also cache a file's decoded-audio digest, in the background,
once they have confirmed the file is still its row's recording. When a later
access finds the file's bytes changed but the change not yet synced (Serato
writing tags into it, for example), the file is used only when it decodes to
exactly that cached PCM; with no cached digest, or different audio, it is refused
as replaced until sync records it. This reads and fills the cache only; it records
no identity, which sync still observes as usual.

`DuplicateEvidenceVerifier` computes digests lazily off the main actor. A second
caller joins the running pass instead of starting another, the pass is cancelled
only when every caller has gone, and finished digests are saved before
cancellation is honoured. A row counts only while the file's size, mtime and
inode still match and, on the cleanup recheck, its nanosecond mtime and ctime
match exactly. Deterministic decode failures are cached and shown; transient
failures (I/O, permission, unmounted volume) are dropped and retried on the next
rescan.

Identical contents or PCM is the only basis for pre-selecting a group. Files whose
PCM differs (another format, or another encoding of one format such as MP3 320
and MP3 128) but that share a full-length fingerprint and decode within 0.5 s of
each other are grouped but never pre-selected, because Clean and Dirty edits can
pass that test; the user checks each file by hand after listening. Files that
differ in full contents, or in full-length fingerprint or duration, are kept and
cannot be checked. Files that fail to decode, and groups still being checked,
offer nothing. The cleanup's first step rechecks the cached evidence against the
live file inside its writer transaction, for the exact identities it was
authorized with: identical contents or PCM, or a fingerprint match only for a file
the user selected. If that transaction rolls back on a conflict, the recheck runs
again when the step resumes.

A confirmed group whose titles name different `VersionLabel`s (the one version
vocabulary, shared with `TitleMatcher` and song-family suggestions) is a label
review. It is never pre-selected, and the panel chooses no keeper for it. Giving
the keeper another copy's title is `OperationEngine.applyMetadataEdit`, the
same row, V2 and tag batch as Cleanup's fixes. Keeping every copy is the
`duplicateLabelReview` mutation. It records the group's signature (a digest of the
member file ids and their content or PCM digests) in `duplicate_label_reviews`,
after rechecking in the transaction that those files are still identical and still
disagree. Its inverse deletes the row. Any changed, removed or added copy changes
the signature, so the review is shown again.

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

A removal batch is undoable from History. The V2 and crate steps record in
`serato_removal_captures` the exact records each checked store lost, and the Trash
step records in `removal_trash_destinations` the item it landed at. Undo first
checks that this item is still in the Trash and unchanged and that nothing now
sits at the original path; otherwise it refuses and changes nothing. It then moves
the item back, re-indexes the file, and queues the record restores behind the
Serato-running guard. A crate deleted since the removal is reported as not
restored, and the other stores are still restored. Undoing a removal that has not
finished drops its queued steps. Undoing that undo is not supported yet (#270).

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
Swift `String` equality, `Set<String>` and `String`-keyed dictionaries compare by
canonical equivalence, so an NFC and an NFD spelling of one path collapse to a
single key. Code that must keep Serato occurrences distinct keys them by
`Data(path.utf8)` or by occurrence index, as `SeratoConflictAnalyzer` and
`LibraryRefreshPlan` do. It applies `SeratoPath.normalized` only after conflict
analysis has run.

The Rust writers for `database V2`, Subcrates and SmartCrates use the same rule:
a rename, metadata update, removal, addition or held-path check matches a stored
path by its NFC form, so a decomposed spelling Finder stored matches a composed
request, and the reverse. Matching never rewrites a path field's bytes; only a
rename replaces the matched field, with the requested destination. Two records whose
spellings are equivalent form a conflict, which the scope above
keeps away from those writers. When both spellings reach a writer anyway, a record
stored in the requested spelling wins: a metadata update writes that record, and
equivalent rename sources bound for different destinations match only exactly. A
metadata batch that sends equivalent paths different updates is refused, and a crate
renamed from both spellings keeps one entry.

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
made during another pass on the same file waits for that pass instead. Its database
transaction can still commit, moving the file, after the pass resolved a row's
path and before that row's I/O. The pass then resolves and retries those rows
at the file's current path instead of dropping them as superseded (#260).

The pass groups eligible rows into segments in queue order. Every V2 metadata
edit joins one rewrite unless a rename, add, or V2 removal queued since that
rewrite opened touches the same file or path; then it starts a new rewrite after
that row. Consecutive renames share one path batch, which applies them in order:
a rename of an earlier rename's destination (old → middle → new) lands the record
at the final path. Consecutive adds of different files share one registration:
Serato's existing paths are read once, every add lands in one V2 rewrite, and
each import is confirmed in the same transaction; a second add of the same file
starts a new registration. Every other write is its own segment. A batched
segment holds at most 200 rows, since its I/O, verification and confirmations
share one writer transaction; a larger backlog continues in the next segment
(#189). Edits to the same record are merged in queue order before the batch
writer, which keeps only one update per path. A strict observation also treats a
saved value equal to a later queued edit of the same file as our own coalesced
write, so it is neither reapplied nor reported. Both landed-write rules apply only
to rows whose write may have landed. The writer boundary commits an `io_started`
mark before its I/O transaction. It clears the mark only when no write for the
row returned from its I/O: the attempt stopped at the boundary, failed before
reaching it, or every I/O call threw. A writer that validates or records after
its I/O (Trash, audio tags, V2 removal, imports) reports the moment that I/O
returns, so a later throw keeps the mark. A later attempt keeps an earlier
attempt's mark (`may_have_landed`), and an attempt never clears a mark it did not
set. Rows queued before migration 016 start with the marker unset, which is
acceptable because no install had a populated queue when 016 shipped. A saved value matching an edit that
never reached I/O, or whose every I/O call threw, is the user's own Serato edit
and wins. That a thrown I/O call did not land holds because every Serato
library write (`database V2`, Subcrates and SmartCrates) replaces its file
atomically: the bytes go to a temporary file in the same directory, which is
flushed and then renamed over the target, so a write that throws before the
rename leaves the previous bytes in place (#193). If only the directory flush
after the rename fails, the writer throws `LandedNotDurable`: the new bytes are
in place, so the engine records the I/O as returned before rethrowing, and the
row stays visible and retries the same bytes. Each rewrite first removes
`.crate-agent-*.tmp` files a crashed rewrite left in that directory. A failed segment fails all of its rows together
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
once that edit lands, so it applies instead of being dropped as uncertain. An interrupted cleanup Trash finishes on restart only when its
write may have landed by that rule; a failed Trash attempt is not proof the audio moved.

A metadata update whose path the parsed `database V2` has no entry at, or a
rename whose track neither `database V2` nor any crate holds at its final path
afterwards, completes as `noSeratoRecord` in the transaction that removes its
row, and does not advance the external baseline: the Rust batch writers report
each unmatched path, so a write with nothing to change is told apart from one
with no entry, and Re-sync counts it as not written (#105).

A missing `database V2` is not evidence that a track is absent (#192), and
crate-agent never creates it. While it is missing, every queued Serato library
write waits: adds and imports, metadata updates, renames, and removals from
`database V2` and crates, with the later rows that depend on them. Audio-tag
writes and Trash, which touch no Serato library file, still drain. No
`Subcrates` or `SmartCrates` file is rewritten either, so the three file sets
never disagree about a track. The check runs per drain segment, after
readiness and conflict deferral, and again at each writer; once a pass finds
the file missing, the rest of its Serato library writes wait too. Every held row
records one `seratoDatabaseMissing` error naming the path and how many changes
the pass held, and the drain or Re-sync fails with it, so the sync status shows
it and **Retry Sync** applies the rows once the file is back. On a Mac where
Serato has never run, sync itself reports `sourceMissing`: open Serato once to
create its library. A queued change that cannot apply can instead be discarded
from History, as described below.

The ready summary reports each dropped change by disposition (superseded,
uncertain, interrupted, malformed, legacy unrecoverable, or no Serato entry) once, and turns to a
warning. An outcome this version does not recognize, such as one recorded by a
newer build, is counted as not applied rather than blocking readiness. History marks a batch with the number of its changes that were not
applied and one reason line per disposition. Its Show files button pages the
affected files through `EventHistoryQuery.loadNotAppliedFiles`, each with its
own reasons; a file whose events project onto Serato or audio-tag writes can be
re-synced alone through `OperationEngine.resyncSeratoForBatch(_:fileID:)`.
Dispositions stay append-only. When a later write for the same event and kind
completes, the queue records it in `serato_write_resolutions`, which History reads to
show that change as applied by a later re-sync rather than deleting its record.
The file list pages by `(path, entry)` keyset, so a change recorded between page
loads cannot skip or repeat a file.

A queued change that cannot apply, because one of its writes failed or it waits
behind one that did, is listed on its History batch, one entry per file, with
**Discard this change…** (#163). The confirmation names the file and the values
the discard puts back. Confirming runs `OperationEngine.discardQueuedChange(batchID:fileID:)`,
which in one `discard:` batch drops the change's queued rows with a `discarded`
disposition through the `discardQueuedSeratoChange` mutation and applies the
inverses of the change's events, as undo would, with undo's guards. A write that
never reached its I/O is not written back, since Serato or the file still holds
the old value. A write that completed, or whose row may have landed
(`io_started` or `may_have_landed`), is written back with the old value through
the queue, and the confirmation says so. A write recorded as not applied is left
alone, except an interrupted one, which may have landed. Undoing the discard
batch applies the reverted events' inverses, which queue the change again.
The discard is refused while a drain holds the change's rows, and while a later
queued change waits behind it (any row the drain would hold behind it, not only
the same file), which the confirmation lists; discard those first. The rows,
their attempts and landed marks, the file's membership revision, and the later
changes are checked again inside the transaction. Changes without an inverse,
such as imports, removals, Trash and cleanup steps, cannot be discarded.
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
The invalidation triggers created by `AddSyncCheckpointMigration`
(`011_add_sync_checkpoint`) name the relevant `files` columns explicitly. A new
`files` column that affects membership, identity, availability, Serato-mirrored
metadata or recording links must ship with a migration that recreates those triggers
to include it. Otherwise an unchanged launch keeps stale cached state. Columns that
only record fingerprint progress stay out of the list.

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

Publication is staged so that no writer transaction grows with the library
(#238). WAL checkpoints run on a connection of their own (`WALCheckpointer`),
never inside a writer commit: while an open Library page's snapshot holds the
WAL, frames accumulate, and SQLite's automatic checkpoint would copy and sync
the whole backlog inside the next commit after it closes (#259). Every row of `sync_saved_occurrences`, `sync_file_evidence` and
`sync_file_stats` carries a `generation`, and only the generation the
`sync_checkpoint` header names is current; every reader filters on it.
`SyncCheckpointStore.publish` checks publishability in a read, removes rows
outside the current generation, and writes the next generation in transactions of
1,000 rows (`defaultChunkSize`). A final short transaction re-checks the
revision, effect fences and queue, verifies that the current generation is still
the one staging started from and that every staged row is present, then points
the header at the new generation and clears `sync_dirty_files`. Readiness opens
only after that commit. The superseded generation is deleted afterwards, in
chunks. Until the flip, readers and the fast path see the previous checkpoint
whole. A crash or cancellation mid-staging leaves it current, with the same
meaning as a crash before publishing, and the next publish deletes the orphaned
rows first. A library change during staging moves the revision, so the flip
fails with `changed` and the sync re-runs. One store publishes at a time.
Any code that performs a physical or Serato-side effect records its fence with
`SyncCheckpointStore.beginEffect` in a transaction that commits before the effect
starts. It clears the fence only after the effect completes or is explicitly
superseded. A fence written inside the effect's own rollback transaction does not
survive a crash, so the next launch could take the clean fast path over a
half-applied write. `PhysicalFileMoveTransaction` and the engine's guarded Serato
write paths follow this pattern.
