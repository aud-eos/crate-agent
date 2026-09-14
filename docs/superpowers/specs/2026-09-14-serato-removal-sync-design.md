# Serato removal reconciliation

## Intended behavior

Serato's saved main library determines membership for files managed through that
library. Removing a track there automatically retires its entry in crate-agent,
whether the audio remains on disk or has been sent to Trash. Retirement preserves
the file row, recording link, fingerprint, and event history. It never deletes,
moves, restores, or re-imports audio.

Removing a track from one crate while it remains in database V2 does not retire
it. Missing audio still referenced by V2 remains a library member with an
unavailable-file status. It can be inspected but cannot be processed.

Restoring audio alone does not reactivate a retired library entry. A subsequent
deliberate Serato re-add, or an explicit crate-agent import, can reactivate it.
Same-file reactivation retains its file ID and history. A replacement at the same
path must pass file-identity checks; it must not inherit an unrelated fingerprint
or recording match.

## Confirmed current gaps

- LibraryScanner only imports and refreshes metadata; it never reconciles absence.
- Its missing-database branch currently returns an empty list. That is unsuitable
  as evidence that the user removed every track.
- OperationEngine.removeFile deletes the row, setting historical file references
  to null. It is not the retirement mechanism.
- SeratoSyncCoordinator drains queued writes before scanning Serato's saved state.
- FSEvents checkpointing happens before asynchronous handling completes.
- FilesystemSyncCoordinator handles existing destinations flagged as file renames;
  it has no Trash exclusion or removal reconciliation.
- Browsers and workers generally query all file rows without membership filtering.

These findings do not establish why the 22 reported paths became unavailable or
prove that crate-agent restored any of them to Serato.

## State and ownership

Add explicit persisted membership state per file: legacy-unverified, active,
pending-import, or retired. Record the owning Serato library identity, retirement
time, and a monotonically increasing membership revision. Fresh local imports
remain pending until their explicit add succeeds or a saved snapshot confirms
membership. Absence must not cancel a newly requested import simply because it
has not reached V2 yet.

Membership transitions, deliberate new import requests, and confirmed replacement
of a file's physical/content identity advance the revision. Replacement invalidates
prior queued work and cached file associations while preserving the file row and
shared recording history. Same-file location/availability observations do not
advance the revision.
Retirement and replacement also set a permanent projection-invalidation revision,
so unversioned historical work cannot regain permission through a new identity.
An explicit retry uses a dedicated begin-import mutation, verifies the same file's
identity, and advances the revision even for pending-import to pending-import.
It cancels older queued adds without manufacturing an intermediate membership
state. Ordinary unchanged observations remain no-ops. A successful add confirms
active membership; failed adds remain pending and can be explicitly retried.

Store availability independently: unknown, available, missing, trashed, offline,
or inaccessible. Missing means the recorded file could not be found on an online
volume; it is not a claim of deletion. Trashed requires positive Trash evidence.
Permissions and unavailable volumes must not be classified as deletion.

Use a dedicated OperationEngine membership mutation with forward and inverse
payloads, stable file IDs, expected prior state/revision, and no outbound writes
for observed Serato changes. Repeated scans of unchanged state produce no events.
Automatic observation batches are informational in History, not an Undo action
that silently reverses the user's external Serato decision. Explicit restoration
is a separate import action. Old metadata undo/re-sync cannot revive membership.

Retiring one file must not retire sibling files sharing its track_id. Keep shared
recording rows and existing canonical ownership rules unchanged.

## Authoritative snapshots

Removal inference requires a fully and strictly decoded, stable database V2 from
the configured supported Serato library, while Serato is closed. A missing file,
read failure, parse failure, changing snapshot, or unavailable source prevents
removal reconciliation and displays a sync error or waiting status.

A structurally valid empty library is distinct from a missing or corrupt database
and can retire all previously managed members. If the current decoder silently
skips malformed track records, add a strict snapshot-reading API for this flow;
partial decoding must never masquerade as a complete membership set.

The existing locator supports the home Serato library. Do not infer removal for
files on an offline volume or for membership owned by an unsupported external
Serato library. This change does not introduce portable-library support.

On first reconciliation, legacy rows on the supported online volume are compared
against the validated snapshot. Account for explicit pending imports and verified
pending renames before classifying absence. Existing rows still in V2 become
active even if their audio is missing; absent managed rows become retired.

Normalize Serato's leading-slash representation and macOS-equivalent Unicode paths
consistently. A missing old path plus an identity-verified current path is a move,
not an automatic removal/new-file pair. Path equality alone is insufficient to
transfer fingerprints to replacement files.

## Ordering and stale work

Startup while Serato is closed: read and validate membership, commit reconciliation,
then permit normal worker scheduling and external writes. Startup while Serato is
running may display the existing index, but does not infer removals from its
potentially stale on-disk library.

On Serato exit, serialize reconciliation before draining queued external writes.
Do not overwrite newly observed membership with an older concurrent scan. Recheck
Serato's running state before each external write; if it restarts, keep writes
queued and obtain a fresh snapshot on the next closed interval.

Use current membership and its revision at mutation, worker completion, queue
drain, and History re-sync boundaries. Retired files reject new processing. A
completed background lookup cannot apply results after retirement. Cancelled
queued work is reported as superseded by removal, not successfully synchronized.

Carry file identity and the membership revision with queued work. Re-adding the
same file must not make an old queued add, rename, metadata change, or audio-tag
write eligible again. Preserve explicit pending-import intent separately so a
legitimate new import can still create its requested V2 entry.

Reconciliation must recognize pending same-file renames whose saved Serato path
has not caught up with crate-agent's path. Validate that association from current
identity and applicable pending intent; never use mere historical event presence
as membership evidence.

## Filesystem events and Trash

Identify Trash locations using native filesystem facilities and volume-aware
locations, not a substring match on a folder name. A move into Trash never emits
a normal Serato path rewrite. Keep the last non-Trash location for inspection.
Record positive Trash evidence, invalidate processing, and let the next valid
Serato snapshot determine membership.

Removing a file in Finder while V2 still references it leaves an active but
unavailable entry. Moving it back out of Trash can refresh availability and its
verified location, but cannot reactivate retired membership or rewrite Serato
on behalf of a retired file.

Process FSEvents batches serially and advance the checkpoint only after handling
finishes. Failed processing must remain replayable and visibly report failure.
Dropped/coalesced events trigger bounded reconciliation rather than inferring
deletion from an incomplete event stream. Filesystem observations alone are never
proof that Serato membership was removed.

## Presentation and performance

Default Library, Auto-Tag, Organize, and Cleanup views exclude retired rows.
Provide a bounded Library status filter for Removed from Serato and Missing files,
showing filename, last-known location, and availability. History remains accessible
for retired entries. Show a concise reconciliation result and visible failures.

Missing active entries remain visible for diagnosis but are excluded from automatic
fingerprinting and modification batches. Refresh eligibility at execution time so
already-open screens cannot act on retired entries. Reuse shared SQL eligibility
predicates across counts, pages, and worker queries, preserving parentheses around
existing OR filters.

Read membership and file identity in batches. Perform filesystem checks and parsing
off the main actor, support cancellation, and retain existing bounded UI pagination.
Do not add a recursive full-library scan on every filesystem event or screen visit.

## Verification

Use temporary SQLite databases, synthetic audio/files, and real encoded Serato V2
and crate fixtures. Do not launch normal AppServices or access the personal library
from tests. Independent GPT-6 Astra review must scrutinize state transitions,
external-write ordering, shared recording identity, and test integrity.

Required regressions, each demonstrated failing without its fix:

- Library-only removal with audio present retires the row without changing audio.
- Removal plus Trash movement retires it and never writes a Trash path to Serato.
- Missing audio still referenced in V2 remains active/unavailable and is skipped.
- Crate-only removal leaves main-library membership active.
- Missing/corrupt/changing V2 and offline sources cause no false retirement;
  a valid empty snapshot does reconcile removal.
- Retirement preserves stable file ID, recording link, and per-file history;
  repeated snapshots are idempotent and sibling files remain active.
- Pending rename and pending explicit import survive legitimate reconciliation.
- Queued writes and delayed worker completions cannot act after retirement,
  including after subsequent reactivation.
- Serato restart during reconciliation/drain prevents external writes.
- Restoring audio alone does not reactivate membership; an explicit re-add does.
- Reused paths cannot acquire stale fingerprints or matches.
- Failed event handling does not advance the FSEvents checkpoint.
- Normal counts and every processing query exclude retired rows; diagnostic views
  are bounded and show unavailable paths clearly.

Update README and the Auto-Tag guide with membership/availability behavior. Run
appropriate isolated Swift and Rust checks, production build, scoped formatting,
and independent review before opening the implementation PR. No live-library
mutation is part of implementation verification.

### Task 6 execution refinement: physical Organize moves

Inspection found that Organize moved audio before entering OperationEngine. Filtering
its query or validating a revision after the move could not protect an already-open
plan. Organize plans and hygiene projections therefore retain the original membership
revision; Organize also retains the original source path.

Physical renames opt in through the existing RenameFilePayload and journal the same
opt-in in their inverse. OperationEngine validates lifecycle, revision, source path,
and physical identity before moving audio inside its serialized writer transaction.
Apply, batch apply, and Undo share a compensated transaction wrapper, including actual
SQLite COMMIT failures. Organize reports per-file failures and coalesces Serato writes
after its successful per-file transactions. This trades the old single SQLite batch
for coherent per-file filesystem compensation without multiplying Serato rewrites.

Cross-volume moves retain the original file at its original path until COMMIT and
copy to the destination. Both identities are verified before committing. Rollback
removes only the verified copy; COMMIT cleanup removes the original only after
revalidating both files. Cleanup failure surfaces the committed batch and retained
source path through externalSyncIncomplete. Abrupt process termination may leave
duplicate copies, but the DB-referenced source or destination remains available.
This is in-process compensation, not a crash-durable filesystem transaction. General queue durability (#110) and
shared recording-row redesign (#113) remain outside this change.

Task 8 must complete pending/legacy/unavailable status projections in BrowserRow and
status badges in Library and Auto-Tag selection. Task 6 provides read-only Auto-Tag
review reasons and original-token approval/application guards; it does not claim the
final diagnostics UI or startup readiness integration is complete.

The single-file Rename dialog uses the same physical rename primitive with its
captured file revision and source path. It performs no pre-engine filesystem move
or post-move FSEvents deduplication read. A committed rename with incomplete cleanup
or external sync remains visible as an error; History retries external writes.
