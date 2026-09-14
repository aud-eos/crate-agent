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
content identity and a missing old location. Ambiguous paths, hard links with the
original still present, and conflicting candidates throw an actionable sync
error instead of choosing an association. Same-path replacements use a journaled
identity observation: the previous complete file record is retained in the inverse
payload, the file's recording link and fingerprint cache are cleared, and its
membership revision advances. Shared recording rows remain intact. Identity and
membership observations are informational History entries with no Undo or Re-sync
permission to write obsolete content.

`lastProjectionInvalidationRevision` permanently fences unversioned historical
projections after either retirement or replacement. Initial legacy activation
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

The session installs a closed readiness gate before service startup. It invalidates
the gate's generation before stopping work or reading a new snapshot. Ordinary
mutation transactions and fingerprint completions verify the captured generation;
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
