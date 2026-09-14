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

The consumer should read one snapshot, reconcile it, and call
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

`reconcileRequestedFilesystemChanges()` supplies one bounded reconciliation pass
for a coalesced filesystem request. The filesystem consumer owns retaining a
failed request/batch and advancing its checkpoint only after success. This stage
does not enable automatic scheduling or replace the application error UI.

Successful explicit adds and snapshots use the same volume UUID plus canonical
directory ownership identifier. Add confirmation remains the engine's existing
`import-confirmed:<eventID>` transaction. Failed adds retain pending membership.
This work does not implement the general durable queue (#110) or change shared
recording ownership rules (#113).
