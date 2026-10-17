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

## Responsiveness

Coverage refreshes when Workers appears and then every two seconds while it is
visible. It does not observe every commit, because an initial scan commits once
per file. `WorkerCoverageTests` measures the aggregate on 30,000 files against a
250 ms budget (`WORKER_COVERAGE` log line).

## Not in this iteration

There is no job queue or scheduler, no persistence of job history across restarts,
no pause/resume, and no monitoring of Organize, Library Cleanup or Auto-Tag batches.
