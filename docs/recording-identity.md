# Recording identity

A recording is a `tracks` row (Invariant 4). Its key, `tracks.fingerprint_hash`,
is normally the SHA-256 of one file's stored 120-second Chromaprint. Different
versions that share their opening (Clean and Dirty edits, intro and outro
edits, radio and extended edits) therefore collapse into one recording. That
means they can't be separate song-family versions, and they share MusicBrainz
identity (#205).

Two features split such recordings. Both are explicit user actions, journaled
through `OperationEngine` and undoable from History.

## The key

`RecordingIdentity.key(of:in:)` is the single source of a file's key
(`keys(ofFiles:in:)` applies the same rule to many files in one query):

- The SHA-256 of its current 120 s fingerprint, by default.
- The SHA-256 of that hash followed by a discriminator, while
  `recording_discriminators` holds a row for the file with that same
  fingerprint hash. The discriminator is the file's full-length fingerprint
  digest (`source = full_fingerprint`), or a per-file token when the user
  grouped it as a different recording (`source = grouping`).

A row whose hash no longer matches the file's fingerprint (the audio was
replaced) has no effect, so no observation has to clear it. AcoustID lookups
still send the 120 s fingerprint, as fpcalc does.

Every path that finds "the recording this file's audio identifies" uses the
key: Auto-Tag's lookup baseline (and therefore the #182 collision preflight),
grouping's link rule, Find Versions' placement, and Serato conflict targets.

## Full-length fingerprint, only on collision

Only files whose 120 s fingerprint another processable file shares need a
full-length fingerprint. They are exactly the perceptual duplicate clusters
(`DuplicateFinder.clusterMemberSQL(.perceptual)`), and
`DuplicateEvidenceVerifier.verifyPendingFiles(mode: .perceptual)` already
decodes them once into `file_audio_digests`, whose `full_fingerprint_sha256` is
the full-length Chromaprint digest from the Rust core's
`decoded_audio_digest`. **Cleanup → Duplicates** and **Cleanup → Shared
Openings** share that cache. No library-wide re-fingerprinting happens.

## Splitting: Cleanup → Shared Openings

`RecordingIdentityService` is the API:

| Call | Effect |
| --- | --- |
| `checkCollidingFiles()` | Computes missing full-length fingerprints for colliding files. |
| `scan()` | Read-only preview: each collision whose full-length fingerprints differ (`RecordingSplitCandidate`), and how many are still being checked. |
| `separate(_:)` | Applies one preview as one History batch. |

Each candidate groups its files by full-length fingerprint into versions. One
version keeps the shared recording: the one with the most files linked to it,
so the fewest links move, and on a tie the version with the oldest file. Every
other version gets a recording of its own. Files already separated, and files
whose digest failed, are left out of the preview.

The preview names each file whose recording link moves. Such a file leaves the
shared recording along with its MusicBrainz match and song family, which stay
on the shared recording for the files that keep it, as when an identity change
moves a file off a family member (song-family rule 4). The Shared Openings
panel asks for confirmation when links move. Files that are not linked only
stop being identified with the shared recording.

### Why splitting is explicit

Splitting changes which recording existing matches, families and History
describe. A whole-library automatic pass would do that to production rows
without the user seeing it. Clean and Dirty edits are about 99.9 % similar, so
a differing full-length fingerprint is strong evidence, but the user still
confirms which files become separate recordings. Nothing is split at startup or
during a scan; the background work is limited to digests.

### The mutation

Each moved file is one `.recordingIdentity(.separate(.fullFingerprint(...)))`
mutation and one `recording_separated` event with `file_id` set, so it shows in
the file's History. Inside the transaction the mutation rechecks that the file
is still processable at the previewed revision and fingerprint, has no
separation for that fingerprint yet, still has the previewed full-length
digest, and still shares its 120 s fingerprint with a file whose full-length
fingerprint differs. A file whose link was the shared recording is linked to
the recording for its new key, which is created bare if it doesn't exist.

Undo (`recording_rejoined`) restores the previous discriminator and link only
while the separation is unchanged and no live MusicBrainz match of the file was
applied since. Otherwise it is refused, so the later match is undone first.
Redo requires the file to be exactly where undo left it. Recording rows a split
creates are left in place on undo, as grouping and match undo do.

## Grouping as different recordings

Files whose full-length fingerprints are identical too (the owner's library had
4 such groups among 16 genuinely different ones) can't be split by audio. When
**Group Selected as Song Family** or **Add Selected to This Song Family** is
refused with `fingerprintCollision`, Library offers **Group as Different
Recordings** or **Add as Different Recordings**
(`SongFamilyService.createAsDifferentRecordings` and
`attachAsDifferentRecordings`).

Before the usual links, in the same batch, each targeted file is given a
grouping-owned recording of its own while it shares its recording. That holds
when another library file is linked to its recording, when MusicBrainz already
identifies the recording it would link to, or when an unlinked file grouped
with it has the same key. Unlinked files are separated first, so a file already
linked to the shared recording, usually the matched one, keeps it and its
match. Each separation is a `recording_separated_for_grouping` event.

Its undo follows the grouping-link rule (song-family rule 3): it removes the
separation only while grouping still owns it. A file retired since, or one a
later match claimed, keeps its own recording, so undoing a group never waits on
either. Its redo takes the general replay guard.

## Guards on other paths

- **Auto-Tag.** The lookup records the file's key. Applying a match whose key
  is not the file's current separated key is refused with
  `identityChangedSinceLookup`, so a lookup made before a split cannot land on
  the shared recording.
- **Match undo.** Undoing a match is refused with `undoSupersededByLaterMatch`
  once the file is no longer linked to the recording the match linked it to,
  as after a split moved it.
- **#182 and #195.** The collision preflight and the canonical-row ownership
  are unchanged; they see the key, and a separation writes no match fields.

## Measurements

`DuplicateScanPerformanceTests.testSharedOpeningPassSelectsOnlyCollidingFilesAndPreviewsAndSplitsWithinBudget`
uses the 30,000-file duplicate fixture: 24,000 fingerprinted files, 3,300 of
them in 1,650 colliding pairs, 150 of which differ over their full length. It
holds three budgets: selecting the files that need a full-length fingerprint
(only the 3,300) under 500 ms, the preview under 1,000 ms (the budget for
opening Duplicates on the same fixture), and one split's write under 100 ms.
Measured: selection about 130 ms locally and 165 ms on CI, the preview 220 ms
and 505 ms, and a split under 20 ms.
