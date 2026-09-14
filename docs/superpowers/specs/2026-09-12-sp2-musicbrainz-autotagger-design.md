# SP-2 — MusicBrainz Auto-Tagger — Design

**Status:** Approved design, pre-implementation
**Date:** 2026-09-12
**Depends on:** SP-1 (foundation), SP-1.5 (tag write path, hygiene UI patterns)
**Unblocks:** Pillar D Spotify matching (#94), Soulseek Phase 2 (#92) — both want clean MBID/ISRC metadata

## Goal

Identify a track by its audio fingerprint and correct its metadata against
MusicBrainz, under human review. A DJ selects tracks, the app looks each one up
(AcoustID → MusicBrainz), and presents a review queue where the DJ confirms or
rejects per-track and per-field. Confirmed matches write clean metadata to the
audio file tags and record the recording's canonical identity (MBIDs, AcoustID,
ISRC) in crate-agent's database.

This is where the track-identity model (Invariant #4) gets its first writer: the
`tracks` table has existed since the initial schema but nothing populates it
today.

## Frozen decisions

These were settled during brainstorming and are not re-litigated during
implementation without explicit discussion.

1. **Always review.** No auto-apply in v1. Every candidate match is confirmed or
   rejected by a human before anything is written. Threshold auto-apply is a
   deliberate future enhancement, not part of SP-2.
2. **On-demand over a selection.** A tagging pass is triggered explicitly from a
   browser selection (or "select all"), mirroring the SP-1.5 hygiene panels.
   No background/continuous lookup worker in v1.
3. **HTTP in Swift.** `URLSession` + `Codable` clients. The Rust core gains
   exactly one new function (`encode_fingerprint`) plus a `year` field on the
   existing tag writer. No `reqwest`/`tokio` in the uniffi FFI core.
4. **Fields written to file tags:** artist, title, album, year ("core DJ set").
   Identifiers (recording/release/artist MBID, AcoustID, ISRC) go to the
   `tracks` DB row, not the file tags.
5. **Year = original release year**, taken from the MusicBrainz **release
   group's `first-release-date`**, not the picked release's date. Decoupled from
   album (which comes from the picked release).
6. **One new mutation type** (`applyMusicBrainzMatch`), fully undoable. Identity
   is always applied on confirm; display fields (artist/title/album/year) are
   cherry-picked.
7. **Per-field cherry-picking**, with a title-preservation model grounded in the
   real library (see § Title matching).

## Architecture overview

```
Browser selection
      │  "Auto-tag…"
      ▼
AutoTaggerService  ──(per track)──►  encode_fingerprint (Rust FFI)
      │                                     │  base64url fingerprint
      │                              read_audio_tags (Rust FFI) ──► duration
      ▼                                     ▼
AcoustIDClient  ──POST /v2/lookup──►  ranked [recording MBID + score]
      ▼
MusicBrainzClient ──GET /ws/2/recording/<mbid>?inc=releases+release-groups+artist-credits+isrcs──►
      │                                 releases, release-group first-release-date, artist-credit, ISRC
      ▼
Candidate  (score, proposed fields, chosen release, title tier)
      ▼
AutoTaggerView review queue  ──confirm N──►  OperationEngine.applyBatch([
                                                 .applyMusicBrainzMatch(...) × N
                                             ], batchId:)   ← one Undo unit
```

`AcoustIDClient`, `MusicBrainzClient`, the rate-limiter, the disk cache, and the
title/candidate logic are pure, independently testable units. Network I/O is
isolated behind an injectable URL-loading seam (the same mocking pattern
`FingerprintWorker` uses for `FingerprintFunction`).

## Data model & migration

### Migration `007_add_musicbrainz_columns` (additive only)

Adds three columns to `tracks`:

- `musicbrainz_release_id TEXT`
- `musicbrainz_artist_id TEXT`
- `isrc TEXT`

`acoustid_id`, `musicbrainz_recording_id`, `artist`, `title`, `album`, `year`
already exist on `tracks`. No `files` columns change.

### What a confirmed match writes

| Destination | Fields |
|---|---|
| `tracks` row (upsert by `fingerprint_hash`) | AcoustID, recording/release/artist MBID, ISRC, and canonical artist/title/album/year — **always**, on confirm |
| `files.track_id` | linked to that `tracks` row (greenfield file→track linkage) |
| `files` Serato-metadata columns + Serato `database V2` + file ID3 tag | the **applied** subset of artist/title/album |
| file ID3 tag + `tracks.year` only | year (if applied) |

### `tracks.fingerprint_hash`

Defined here for the first time: **SHA-256 of the serialized `[UInt32]`
Chromaprint fingerprint** stored in `files.chromaprint_fingerprint`. An
exact-match identity key.

- Byte-identical fingerprints share one `tracks` row.
- A FLAC and an MP3 of the same recording are perceptually close but **not**
  byte-identical, so they get **separate** `tracks` rows. This is acceptable:
  SP-2 only needs a stable per-recording identity to hang identifiers on.
- **Perceptual dedup** ("group these as one recording / one work") is explicitly
  **out of scope** — that is the Duplicates panel (SP-1.5) and Pillar C
  work-identity concern.

### Year: original vs reissue

`year` is read from the recording's **release group** `first-release-date`
(`inc=release-groups` on the MB query), giving the original release year
independent of which specific release the user picks for `album`. Picking a
different release changes album but not year. Caveat: `first-release-date` is
MusicBrainz community data and occasionally imperfect; it is the standard
"original" signal and remains a cherry-pickable/overridable field.

### Year and Serato database V2 — known limitation

The existing `SeratoMetadata` model and Serato write FFI have **no year field**,
so SP-2 writes year to the audio file tag and `tracks.year` but **not** to
Serato's `database V2` cache. Serato re-reads year from the file tag on analyze,
so the data is not lost; the DB cache just won't reflect the corrected year
until Serato re-imports. Wiring year through the Serato write path ripples across
`SeratoMetadata` and the Serato FFI — tracked as a **follow-up issue**, not
folded into SP-2. artist/title/album go through the full Serato path and update
immediately.

## The mutation: `applyMusicBrainzMatch`

Per Invariant #1, SP-2 adds exactly one `TrackMutation` case. It does not compose
the existing `setMetadata`/`writeFileTags` mutations because those are
`files`-only, year-less, and carry no identity payload.

### New enum case

```
case applyMusicBrainzMatch(ApplyMusicBrainzMatchPayload)
```

### `ApplyMusicBrainzMatchPayload` (Codable, Sendable, Equatable)

- `fileId: Int64`
- **identity** (always applied on confirm): `acoustidId`, `mbRecordingId`,
  `mbReleaseId`, `mbArtistId`, `isrc`, `fingerprintHash: Data`
- **appliedFields**: the cherry-picked subset of { artist, title, album, year }
  with the resolved values to write (fields the user left unchecked are absent)
- **previous…** snapshot fields, filled by the engine at apply time for the
  inverse: previous `files.track_id`, previous `files` Serato-metadata, previous
  file ID3 tags (for the applied fields), and previous `tracks`-row identifier
  values if the row already existed

### New `EventType` (append-only, stable string)

`music_brainz_match_applied`

### Apply logic (inside the existing `executeAndLog` transaction)

1. Upsert `tracks` row keyed by `fingerprintHash`; write identifiers + canonical
   artist/title/album/year.
2. Set `files.track_id` → that row.
3. Update `files` Serato-metadata columns for the applied artist/title/album.
4. Return a Serato pending-write (`.metadataUpdate` for applied artist/title/album)
   and a file-tag write (applied artist/title/album/year), reusing the existing
   `applySeratoWrite` / `applyFileTagWrite` mechanics. Per "share the mechanic,
   not the shape", extract a small shared helper rather than duplicating those
   bodies.

### Inverse (Invariant #2 — undo is part of the spec)

- Restore previous `files.track_id`, previous `files` metadata, and previous file
  ID3 tags from the captured snapshots (only the fields this mutation changed).
- If the `tracks` row pre-existed, restore its previous identifier values. If
  SP-2 **created** the row, the inverse nulls its identifiers and all initialized
  display fields, including kept on-disk values used to seed the new row, and leaves
  the now-orphaned row in place (keyed by fingerprint, harmless, reused on
  re-match; deleting risks FK churn).
  Reusing a completely empty, unreferenced fingerprint row seeds kept fields
  from the new apply's captured tags, so redo restores them too. Occupied or
  nonempty existing rows retain their kept canonical values.

Undo therefore returns the file to its exact prior tag/Serato/DB state, for both
the new-track-row and pre-existing-track-row cases.

### Application path

The review UI confirms N tracks → one `operationEngine.applyBatch([...],
batchId:)` call, exactly like `LibraryHygiene.applyMergedMetadata`. A batch of
confirms is a single Undo unit and a single Serato-running check.

The selection search associates its published rows, match count, and errors with
the query that produced them. Editing the query hides the previous results
immediately, including from Select All Results, throughout debounce and the DB read.
Existing checkbox selections persist across searches.
Changing the normalized query invalidates the completed outcome, so revisiting
an earlier query or returning through New Scan waits for fresh results.
The empty-library state observes the database row count throughout the panel's
lifetime, including scans after startup. Each lookup pass replaces the service's
result collection with its selected file IDs, releasing candidates from prior scans.
Strong classification requires an unambiguous recording: a distinct recording in
another AcoustID result forces review when that result also scores at least 0.9
or lies within 0.05 of the selected result. Repeated IDs for the same recording
do not create ambiguity; distant weak results do not downgrade the winner.

Re-sync decodes all replayable payloads and relevant field-ownership history before
issuing external writes. An undecodable event fails recovery with its event ID,
batch ID, event type, and decoding diagnostic; it is never reported as an empty
successful replay.
Undo and redo use the same throwing decoder for their forward-payload safety
checks; a malformed payload cannot silently bypass protection of later edits.
Metadata imports claim V2 field ownership only when they are Serato-authoritative.
Local hygiene snapshots and undo snapshots carry an explicit false authority flag;
their paired commit events retain ownership of outbound V2 writes. Legacy undo
journals without the flag are recognized by the engine's `undo:` batch namespace.
This keeps a failed hygiene undo recoverable through Re-sync.

A failed fingerprint recompute clears the stale completed fingerprint only if its
stored bytes, status, freshness basis, path, and indexed size/mtime still match the
snapshot that failed. The comparison and update share a transaction, preserving a
concurrent successful fingerprint. Failure to persist the error is surfaced in the row.

**Open correctness constraint:** freshness snapshots retain only whole-second
modification times, so same-size edits within one second can evade cached
fingerprint and apply validation. [#118](https://github.com/aud-eos/crate-agent/issues/118)
tracks subsecond identity throughout persisted fingerprints and journaled
candidates, including migration and legacy-data trust rules.

**Open correctness constraint:** queued audio-tag writes capture paths that can
become stale after Finder renames, blocking the drain or writing to a replacement
file at the old path. [#117](https://github.com/aud-eos/crate-agent/issues/117)
tracks stable target identity together with removal/undo/retry lifecycle rules.
Resolving only a live file ID is insufficient: removing an indexed row can strand
its queued writes even when the physical file remains.

**Open correctness constraint:** final Serato-session edits are not reconciled
before queued metadata drains. This can overwrite a newer Serato edit; [#115](https://github.com/aud-eos/crate-agent/issues/115)
tracks the required baseline/current/queued reconciliation design. Simply scanning
first would misclassify unchanged external values as edits against queued intent.

## Lookup pipeline

### Rust FFI additions (the only Rust changes)

- `encode_fingerprint(raw: sequence<u32>) -> string` — `rusty_chromaprint::encode_fingerprint`
  → base64url. Swift reads the stored `files.chromaprint_fingerprint` bytes,
  deserializes to `[UInt32]` (existing `deserializeHashesFromBytes`), and calls
  this. No audio re-decode.
- Extend `AudioTagUpdate` (UDL dict + `tags.rs` writer) with a `year` field →
  ID3v2.4 `TDRC` / Vorbis `DATE` / iTunes `©day`.

Duration for AcoustID comes from `read_audio_tags().duration_seconds`
(full-track, already available). If a selected file has no stored fingerprint, it
is routed through the existing `FingerprintWorker` before lookup.

### `AcoustIDClient.swift`

- `POST https://api.acoustid.org/v2/lookup` with `client=<key>`, `duration`,
  `fingerprint`, `meta=recordings+recordingids`.
- Returns ranked `[AcoustIDResult]`, each with a `score` (0–1) and one or more
  MusicBrainz recording IDs.

### `MusicBrainzClient.swift`

- `GET https://musicbrainz.org/ws/2/recording/<mbid>?inc=releases+release-groups+artist-credits+isrcs&fmt=json`
- Resolves a recording → releases (album), release-group (`first-release-date` →
  year), artist-credit (name + artist MBID), ISRC.

### Rate limiting & caching

- A shared serial async rate-limiter: **≤1 request/second** to MusicBrainz, with
  a required descriptive `User-Agent`: `crate-agent/<version> ( <contact-url> )`.
  AcoustID goes through the same limiter conservatively.
- **Disk cache** keyed by fingerprint (AcoustID responses) and by recording MBID
  (MusicBrainz responses), under Application Support, so re-running a pass over
  the same tracks costs zero network. Backed by `URLCache` + a small keyed
  on-disk store.
- Exponential backoff on `429`/`503`. The pass is cancellable mid-flight.
  Both backoff and proactive rate-limit waits propagate cancellation, so cancelling
  a scan while it waits for a request slot prevents that request from being sent.

### Default release selection

Among a recording's releases, prefer one whose title/year matches the file's
**existing album tag** if present; otherwise the **earliest official** release.
Fully overridable in the UI ("pick a different release"). Year is unaffected by
this choice (it comes from the release group).

### Confidence score

Shown per track = the AcoustID `score` (0–100%). This is the honest signal — the
fingerprint-match confidence. Release/title disagreements are shown as diffs, not
folded into the number.

## Review UI

### Placement

A new `MainWindowView.Section` case `autoTag` ("Auto-Tag", sidebar entry) —
following the rule that new sub-projects add a sidebar entry, not a window. The
view follows the `LibraryHygieneView` **scan → preview → apply** skeleton
(`@EnvironmentObject` services + `seratoWatchdog`, `SeratoRunningBanner`, per-row
diff list, footer apply button).

### Entry point

Select tracks in the Library browser → context-menu / toolbar **"Auto-tag…"** →
the Auto-Tag panel populates a review queue as lookups complete (rate-limited,
async, cancellable). Reuses the Combine progress-reporting pattern from
`FingerprintWorker`.

### Review row

One row per track:

- Confidence % (AcoustID score) and a status chip: `strong match` / `weak match`
  / `no match` / an explicit failure reason.
- Per-field diff `current → proposed` for artist, title, album, year (unchanged
  muted, changes highlighted).
- The chosen release, with a disclosure to **pick a different release** (album ·
  year · country/label); re-picking updates the album diff live.
- **Per-field apply toggles** (artist / title / album / year). Unchecked fields
  keep their current value. Defaults: artist/album/year on when they differ;
  title per the tier logic below.
- **Confirm / Reject** per row. Reject = skip, no write. `no match` rows are not
  confirmable.

### Footer / batch controls

"Confirm all strong matches", select-all/none, and **Apply** → a single
`applyBatch` of `applyMusicBrainzMatch` mutations for confirmed rows under one
`batchId`. `SeratoRunningBanner` shows when the Serato-DB portion will queue
(file-tag writes still proceed; artist/title/album Serato-DB updates defer, per
Invariant #3).

### Out of scope for the v1 panel (YAGNI)

- Cover-art fetching.
- Multi-recording disambiguation beyond picking a release (SP-2 takes AcoustID's
  top-scored recording; a wrong one is rejected).
- Threshold auto-apply.

## Title matching (grounded in the real library)

A scan of the user's 32,351 titled tracks confirmed the conventions this must
handle:

- **52% of titles carry a `()` annotation** — the dominant convention.
- `[]` brackets (~321) and ` - ` dash tails (~782) also occur, sometimes
  combined (`- clean)`, `- acap out)`).
- Real vocabulary: `dirty` (3,613), `clean` (3,508), `remix`, `intro`, `edit`,
  `instrumental`, `outro`, `radio edit`, `extended`, `original mix`, `main`,
  `flip`, `acapella`, `bootleg`, `redrum`, `transition`, …
- Nuances a fixed vocabulary would miss: compound flags (`(intro outro)`,
  `(intro clean)`), abbreviations (`(instr)`, `(acap out)`), and — critically —
  **curator/editor credits** (`(mm edit)`, `(nick bike edit)`,
  `(paul mond flip)`, `(prod by lord finesse)`) that identify *which* edit.

MusicBrainz's canonical title strips all of this. Losing a version flag or edit
credit silently corrupts a DJ library, so the title field is treated specially.

### Tiered detection

Compare MB's proposed title against the current one, normalized (case-folded,
whitespace-collapsed):

1. **Exact match** (modulo case/spacing) — nothing to preserve. Default:
   **take MB** (adopts proper capitalization). Low stakes.

2. **Base-match with remainder** — normalized MB title is a **prefix** of the
   current title, leaving a remainder. Example:
   - MB: `Foo Song Title`
   - Current: `foo song title [DJ foobar remix - radio version]`
   - base `foo song title` matches; remainder ` [DJ foobar remix - radio version]`
     is preserved.
   - Three-way title control on the row:
     - **Keep** — current title unchanged
     - **Merge** (default) — MB clean base + the remainder →
       `Foo Song Title [DJ foobar remix - radio version]`
     - **Take MB** — `Foo Song Title` (drops the tag)
   - Merge is computed by locating MB's title case-insensitively in the current
     string and appending everything after it, with the remainder's original
     formatting/delimiter preserved. Works for `[]`, `()`, `- `, or bare
     remainders alike.

3. **Annotation present, no clean base-match** — the current title has a
   `()`/`[]`/`- ` annotation segment (or a bare trailing DJ-vocabulary token)
   that MB's title lacks, but MB also changed the base (so the remainder is not
   cleanly separable and Merge is disabled). Default: **Keep**, offer **Take MB**.
   Detection: structural annotation-segment extraction across all three
   delimiter styles, plus a confirmed-vocabulary check as a fallback for the
   rare bare, undelimited case.

4. **No annotation, MB differs** — a plain correction. Default: **take MB**.

### Identity is separate from display fields

Confirming a match **always** writes the identifiers (recording/release/artist
MBID, AcoustID, ISRC) to the `tracks` row and links `files.track_id`, regardless
of which display fields are applied — "yes, this is that recording" is a
different assertion from "overwrite my title".

## Settings & secret handling

- New **Settings → Auto-Tag pane** with an AcoustID application API key field.
- The key is stored in the **macOS Keychain** — never in the SQLite DB, the event
  log, or logs.
- No key → the Auto-Tag panel shows a clear "add your AcoustID key in Settings"
  empty state with a link to acoustid.org; the feature is inert, not a silent
  no-op.
- MusicBrainz needs no key, only the descriptive `User-Agent`.

## Error handling (no silent failures)

Every failure surfaces in the UI; never a `log + continue`.

- **Per-track lookup failure** (no fingerprint, decode error, no AcoustID result,
  MB fetch failed) → that row renders with an explicit reason chip
  (`no fingerprint`, `no match`, `lookup failed: <reason>`) and is
  non-confirmable. The pass continues for other tracks.
- **Systemic failure** (bad/expired key → 401, network down, sustained 503) → a
  panel-level banner halts the pass with an operator-useful message, not 200
  silent empty rows.
- **Apply failure** (a mutation throws mid-batch) → the whole `applyBatch`
  transaction rolls back (existing behavior); the UI reports which batch failed
  and why. No partial write.

## Edge cases

- **Serato running:** file-tag + `tracks`/`files` DB writes proceed; the
  artist/title/album Serato-DB portion queues via the watchdog (Invariant #3).
- **Track already matched** (has an MBID): re-matching is allowed and overwrites,
  as a normal undoable mutation; the diff shows against current.
- **File with no stored fingerprint:** routed through `FingerprintWorker` first;
  unfingerprintable/corrupt files surface as `no fingerprint`.
- **Large selection:** just takes time (≤1 req/s to MB); cancellable and
  cache-backed, so a cancelled/re-run pass resumes cheaply.

## Testing

### Rust (`cargo test`)

- `encode_fingerprint` — round-trip a known `[UInt32]` against a golden base64
  string derived from `fpcalc` output for a fixture file (proves genuine
  AcoustID compatibility, not just self-consistency).
- Extended tag writer — writing `year` produces the correct ID3v2.4 `TDRC`
  (and Vorbis `DATE` / iTunes `©day`) frame and round-trips through
  `read_audio_tags`.

### Swift — clients (pure, no network)

- `AcoustIDClient` / `MusicBrainzClient` parse recorded fixture JSON (real
  captured responses) into the model types: multi-release recordings, missing
  ISRC, empty results, error bodies. Injectable URL-loading so tests never hit
  the network.
- Rate-limiter: ≥1s spacing and correct backoff on injected 429/503.
- Default-release heuristic: match-existing-album vs earliest-official.
- Cache: a warm cache serves without a second network call.
- **Title tier logic** (its own focused suite): exact / base-match+remainder
  (Keep, Merge, Take computed correctly across `()`/`[]`/`- `/bare) /
  annotation-no-basematch / plain; compound flags; abbreviations; curator
  credits; year decoupled from release choice.

### Swift — the mutation (correctness core)

- `applyMusicBrainzMatch` apply: upserts the `tracks` row, links
  `files.track_id`, updates the applied files metadata, emits the right Serato +
  file-tag writes, writes an event with a correct inverse.
- **Undo round-trip** (load-bearing, Invariant #2): apply → undo → assert file
  tags, `files` metadata, `files.track_id`, and Serato snapshot are byte-for-byte
  back to prior state — for both the new-track-row and pre-existing-track-row
  cases, and with partial (cherry-picked) field sets.
- **Serato gating** (Invariant #3): with Serato "running", the Serato-DB write
  queues while file-tag/DB writes proceed; drains on "quit".
- `applyBatch` of N confirms = one `batchId` = one Undo unit.

### No end-to-end network test in CI

Would be flaky and rude to the APIs. Recorded fixtures cover parsing/logic
deterministically. A manual smoke test (real key, a handful of real tracks) goes
in the plan's verification steps.

## Follow-up issues to file

- Wire `year` through the Serato `database V2` write path (extend
  `SeratoMetadata` + Serato FFI) so the Serato cache reflects corrected years
  without a re-import.
- (Future enhancement, not scheduled) Threshold auto-apply above a configurable
  confidence.
- (Future) Perceptual/work-identity dedup so FLAC+MP3 of one recording share a
  `tracks` row (Pillar C).
