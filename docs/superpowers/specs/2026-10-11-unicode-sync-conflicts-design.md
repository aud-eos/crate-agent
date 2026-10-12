# Isolate Unicode-equivalent Serato path conflicts

Issue: https://github.com/aud-eos/crate-agent/issues/130

Status: approved by the owner on 2026-10-11. Guided repair in Serato is the
first-release direction; implementation has not started.

## Outcome and scope

A stale or ambiguous Serato record must not prevent the rest of the library from
synchronizing. At the owner's approximately 30,000-file scale, navigation remains
usable, unaffected records reconcile normally, and eligible unaffected files can
be fingerprinted and processed after source validation finishes. Conflicted
files remain visible, unchanged, and explicitly blocked from processing.

The first release diagnoses conflicts and guides repair in Serato. It does not
remove Serato records, rewrite Unicode spellings, consolidate SQLite rows, or
choose metadata on the owner's behalf. No new repair mutation, database migration,
or dependency is required. General incremental startup work remains a separate
issue: https://github.com/aud-eos/crate-agent/issues/129.

## Current behavior and risk

`SeratoPath.normalized` standardizes absolute paths and produces NFC. The scanner
inserts the results into a dictionary and throws `ambiguousIdentity` when a second
record occupies the same key. The reconciler separately builds a saved-path set;
that set discards record multiplicity. `SeratoLibrarySyncSession` catches the
scanner error, invalidates the global `LibrarySyncReadiness` gate, and stops all
processing. The status banner therefore reports a global failure even when only
one stale path is affected.

Catching the scanner exception alone is unsafe: the earlier reconciler can already
have changed a conflicted file, and marking the global gate ready would allow
queued writes and other consumers to touch it. Queue draining currently removes
ineligible work as superseded or stops at a deferred first item. A path conflict
must do neither to unrelated queued work.

## Chosen approach

Build one immutable conflict analysis from each validated saved snapshot before
reconciliation begins. Share it across reconciliation, metadata scanning, readiness,
and presentation. Extend the existing epoch-based readiness authorization with
file/target conflict checks; do not create a parallel mutation engine.

Alternatives considered:

- Catch collisions only in the scanner: smallest edit, but loses end-to-end safety
  and does not reliably resume unaffected processing.
- Automatically merge or remove equivalent records: requires proving losslessness
  across metadata, unknown Serato fields, and all library files. This is outside
  the approved guided-repair scope.

## Conflict representation and detection

Group saved records by the existing normalized absolute path. Preserve every
original record occurrence and its original path bytes. Swift String equality
already treats canonically equivalent spellings as equal, so raw representations
must use byte-backed identity or occurrence indices rather than a String-keyed
set. Do not normalize before retaining the original representation.

A group with more than one saved record becomes one conflict. Byte-identical
repeated records are also represented, with multiplicity, rather than silently
collapsed. Even apparently identical stale entries stay a targeted conflict in
this release: projected metadata cannot prove that unknown Serato fields agree.

Each conflict exposes:

- The canonical grouping path and each raw spelling, with Unicode scalar/UTF-8
  details that make otherwise identical-looking strings distinguishable.
- All associated indexed file IDs, without selecting a representative row.
- Saved metadata per occurrence and the fields that differ.
- Per-spelling filesystem observations: missing, accessible, inaccessible,
  offline/unknown, or inspection error. A lookup failure is not evidence of absence.
- Whether successful observations resolve to the same physical file or distinct
  files, using volume/device and inode evidence rather than text equality.

Filesystem diagnostics inspect only conflict spellings and remain off the main
actor. Two successful path lookups can refer to one physical file on APFS; the
presentation must not call that two files. Diagnostic results never authorize a
mutation or override strict file-identity verification.

The analysis contains blocked normalized paths and associated file IDs, tied to
the snapshot generation and library identity. Include indexed aliases and any
verified identity associations that would otherwise allow move resolution to
connect an unaffected spelling to a conflicted file. If isolation cannot establish
an unambiguous boundary, retain the existing explicit failure instead of guessing.
Unrelated SQLite identity collisions remain existing failures; this change does
not attempt general database repair.

## Synchronization and authorization

1. Read and validate the complete saved V2 snapshot using the existing reader.
2. Analyze conflicts and install the immutable exclusions for that readiness
   epoch before any reconciler/scanner mutation or queued-write drain.
3. Keep all saved paths as presence evidence. Separately skip conflicted records,
   indexed files, and move candidates. Never treat an excluded record as absent
   and retire its file. Do not refresh its metadata, identity, membership, or
   fingerprint basis as a side effect of this sync.
4. Reconcile and scan unaffected entries normally, through `applyMutation` and
   the existing snapshot and physical-identity guards.
5. Drain unrelated queued writes while retaining conflict-blocked entries.
6. Validate the source again and publish ready-with-conflicts status. Start
   eligible unaffected background work.

The existing epoch/lifecycle guard still invalidates authorization on a new sync,
source change, cancellation, or Serato transition. A file-specific conflict error
is distinct from a global synchronization failure. Conflict publication and
readiness publication must not leave an interval in which a file becomes writable
before its exclusions are installed.

Audit every processing path, including apply/batch apply, undo, historical re-sync,
imports, filesystem observations, Auto-Tag, background fingerprinting and queued
external effects. Check affected IDs and all source/destination/reference paths,
not only the file's current path. Newly imported IDs and rename destinations cannot
bypass a blocked path. Recheck inside serialized database commits and immediately
before external I/O after suspension. Shared-recording mutations must not alter
protected file state indirectly; conservatively block the affected operation when
its complete write set intersects a conflict.

Readiness/eligibility failures are visible per file. Preview and selection flows
must explain blocked targets; service guards remain authoritative if a preview is
stale. Workers skip blocked files without retry loops or globally stopping the
unaffected queue. Fingerprint persistence rejects results that became conflicted
while decoding and leaves them retryable after repair.

Conflict state is session-scoped, like the current validated snapshot. On restart,
the global gate begins closed until fresh analysis completes. During a retry,
retain the previous conflict details as stale/read-only until a new validated
result replaces them; never clear exclusions merely because retry began.

## Queue semantics and Serato round trips

Conflict-blocked writes are retained, counted, and explained. They are neither
applied nor marked superseded solely because of the conflict. A bounded drain pass
can process independent later items without spinning on a blocked entry. Preserve
ordering and dependencies within each file/event/duplicate-cleanup chain, including
keeper references; never run a later dependent step ahead of a blocked prerequisite.

When a subsequent validated snapshot resolves the conflict, retry retained work
through the normal revision, physical-identity, and external-baseline checks. The
repair may legitimately supersede an old intent; unblocking alone grants nothing.
This change does not add restart persistence to the existing queue.

Unrelated Serato writes must preserve the conflicted records, their raw path
spellings, metadata and opaque fields when round-tripping V2, Subcrates and
SmartCrates. Tests must prove this at the existing Rust/FFI write boundary. If a
particular writer cannot preserve an ambiguous group, defer that affected write
with a visible reason rather than rewriting or dropping the group.

## User flow

After synchronization, show an amber status such as “Library synced · 2 path
conflicts · 3 changes waiting for repair”. The main window and menu bar expose a
clearly labeled **Review conflicts** action. Normal browsing remains available.
This is visibly different from a completely successful sync and a source-wide
failure. Conflict-aware rows/actions explain why a particular file is blocked.

**Review conflicts** opens a dedicated navigable detail screen with a bounded
conflict list and an always-visible selected-conflict detail area. Show both raw
paths, Unicode differences, saved metadata and file availability without disclosure
triangles, expandable rows, or hidden details. Label inspection errors explicitly.

Actions:

- **Copy conflict details** copies the displayed evidence and instructions.
- **Show in Finder** is available for a currently verified existing target; failure
  to reveal it is shown rather than silently ignored.
- **Open Serato** launches Serato only on the owner's click, using the existing
  watchdog to suspend synchronization/writes as usual.
- **Retry Sync** reuses the existing retry flow after Serato is saved and closed.
  While Serato runs, show the waiting state.

Guidance distinguishes stale entries with no verified live file from aliases of
one file and distinct-file conflicts. Ask the owner to inspect the listed entries
in Serato, preserve the intended file and metadata/crate membership, remove only
verified unwanted library references without deleting audio, save and close Serato,
then retry. Unknown/inaccessible locations require restoring access before deciding
that an entry is stale. The app never claims to have repaired anything until the
next validated snapshot proves the conflict is gone.

## Validation and performance

Use the fewest integrated tests that exercise each behavior through real public
boundaries. Extend existing sync, queue and eligibility fixtures where possible.
Use real temporary SQLite/Serato files and controlled filesystem observations only
where the host filesystem cannot represent the required Unicode case.

Required evidence:

- NFC/NFD pairs with zero, one and two distinct live physical targets; aliases of
  one physical target are distinguished from two files. Test conflicting metadata,
  byte-identical repeated entries, and preservation of original representations.
- An unrelated row reconciles while associated conflicted rows retain all state;
  no false retirement, import, move, metadata choice, or identity reassignment.
- Ready-with-conflicts allows unaffected work but rejects conflicted direct apply,
  indirect/shared-row writes, undo/re-sync and suspended fingerprint persistence.
- A blocked queue head does not starve unrelated work, discard intent, break a
  dependent chain or spin. Repair plus retry revalidates rather than blindly applies.
- Unrelated Serato writes round-trip conflicted entries and opaque data without loss.
- Source changes, cancellation, restart initialization and Serato-running transitions
  cannot publish stale readiness or remove necessary exclusions.
- Status/detail presentation keeps diagnostics and repair actions visible; repair
  updates conflict counts and restores eligibility only after validated sync.

Use a deterministic 30,000-record fixture with a small conflict set. Measure the
new analysis separately from existing startup scanning: target under 100 ms of
analysis and no new main-actor segment above 50 ms on the reference Mac. Navigation
must respond within 500 ms during the conflict-analysis/diagnostic phase. Do not
claim the separate incremental-startup issue is solved. Keep row projections free
of fingerprint blobs, diagnostics proportional to conflict size, and list rendering
bounded. Report timings and limitations alongside strict safety assertions.

Run the documented isolated Swift suite and appropriate Rust checks, format changed
sources, and inspect the conflict UI in the owner's running app without starting a
dev server. Update README usage and the reconciliation guide with the final flow.

## Review handoff

This spec is approved. Review the implementation plan and confirm its execution
method before implementing.
