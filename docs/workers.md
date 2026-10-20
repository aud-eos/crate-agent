# Workers

**Workers** is the operational view of background work. It separates three things
that are easy to confuse:

- **Job progress**: the current run of a service-owned job. Fingerprinting
  (`FingerprintWorker`) starts automatically. File-info scanning
  (`SeratoLibrarySyncSession`) runs at startup, when Serato closes, from **Retry Sync**,
  and from **Re-scan File Info**. Workers reads the same published state as every
  other surface, so a job started elsewhere shows up here, and navigating away
  neither stops nor resets it.
- **Library coverage**: whole-library counts from one SQL aggregate over `files`.
  No rows or fingerprint blobs are decoded. Fingerprint coverage counts only
  eligible files: active members of the Serato library that are available. A
  fingerprint is *usable* when it is `done` and its bytes decode as a Chromaprint
  fingerprint: not null, not empty, and a whole number of 32-bit values. A `done`
  label without such bytes is reported as **invalid**, not as coverage. Files that
  are unavailable, still awaiting Serato confirmation, or removed from Serato are
  counted separately as not eligible.
  Byte-twin copying uses only usable fingerprints, so an invalid result is never
  copied to another file. A decoder that returns no hashes is recorded as a failure.
- **Deferred Serato writes**: the durable write queue, with why it is waiting.
- **Library checklist facts**: the Serato crates and beatgrid locks read from
  Serato's database, cue points read from each file's Serato tags (read,
  pending, failed and unsupported counts, and the files that couldn't be read,
  faults before unsupported formats), and the duplicate checklist. Each shows
  its failure in red. See the [library checklist](library-checklist.md#where-the-facts-come-from).
- **MusicBrainz works**: **Record Works** looks up the MusicBrainz work of each
  matched recording that has none, for [Find Versions](song-families.md#musicbrainz-works).

## Files needing attention

The drill-down lists up to 200 files per category, ordered by path: **Failed**,
**Invalid results**, **Pending** and **Unavailable**. Failed rows show the
decoder's reason, which the worker records in `files.fingerprint_failure`; rows
that failed before that column existed say so. **Show in Library** opens Library
filtered to the file's path. **Show in Finder** is offered for available files.

**Retry All Failed and Invalid** and **Retry Selected** return only eligible failed
or invalid rows to `pending`. Usable fingerprints and unavailable files are left
alone. A running worker picks them up on its next poll, and a worker that stopped
on an error is started again. Fingerprint status is worker-derived processing
state written through `FingerprintPersistence`, like the worker's own results; it
is not a track mutation and has no History entry.

## MusicBrainz works

`MusicBrainzWorkBackfill` is the job's API. It looks up only matched recordings
a library file links to that still have no work, one MusicBrainz recording at a
time, through the client Auto-Tag uses, so it shares its one-request-a-second
limiter and lookup cache.

- **Writes.** Each work is a journaled `recordMusicBrainzWork` mutation, committed
  in History batches of up to 50 recordings while the run continues, so undo
  reverts a batch. Inside the transaction it is refused when the recording no
  longer names the looked-up MusicBrainz recording, or a work was recorded
  since, so it only ever fills an empty work and never touches tags, titles or
  Serato.
- **Stop and resume.** **Stop** cancels the lookup in flight, ends the run and
  records the works found so far. **Resume** starts a new run over the
  recordings still without a work; recordings looked up before answer from the
  cache.
- **Errors.** The first lookup or write error stops the run and shows the
  reason in the card; works found before it are kept.
- **Coverage.** Library coverage counts the matched recordings a library file
  links to, and how many have a work. Recordings MusicBrainz relates to no work
  stay without one.

## Responsiveness

Coverage refreshes when Workers appears and then every two seconds while it is
visible. It does not observe every commit, because an initial scan commits once
per file. `WorkerCoverageTests` measures the aggregate on 30,000 files against a
250 ms budget (`WORKER_COVERAGE` log line).

## Not in this iteration

There is no job queue or scheduler, no persistence of job history across restarts,
no pause/resume beyond starting Record Works again, and no monitoring of Organize,
Library Cleanup or Auto-Tag batches.
