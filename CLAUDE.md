# CLAUDE.md — crate-agent

Project-level guidance for Claude Code working on this repository.

## What this project is

A macOS-native Serato DJ library management companion. Read [`README.md`](./README.md) and [`design-plan.md`](./design-plan.md) before making non-trivial changes — the design plan documents architectural decisions that are *intentional and not up for re-litigation* without explicit discussion.

## Invariants — the load-bearing rules

These are the rules whose violation has bitten (or would bite) someone writing different code in this repo. Following them is not optional. If a change requires breaking one, raise it in the PR — do not silently work around.

### 1. All state changes go through `applyMutation`

The "apply track mutation" primitive in `OperationEngine` is the single chokepoint for every state-changing operation: rename, tag set, find/replace, MusicBrainz match, re-encode. Each new feature **adds a mutation type**, it does not add a new code path.

Why this exists: without the chokepoint, every feature reinvents (a) the Serato-running guard, (b) the SQLite transaction, (c) the event log entry. Two of those three would always get forgotten. The chokepoint guarantees consistency.

How to apply: when adding a new feature that modifies tracks, add a `TrackMutation` case and implement its apply / inverse logic. Do not write a parallel path that goes around `OperationEngine`.

Async validation is not authorization for a later commit: another actor can retire
the file, replace its identity, or supersede a saved snapshot during suspension.
Recheck the relevant revision, identity, and snapshot/lifecycle generation inside
the serialized transaction or external-write boundary (removal-sync Tasks 3 and 5).

### 2. Every mutation logs an event with an inverse payload

The `events` table is append-only and serves two queries:

- Undo: `SELECT * FROM events WHERE batch_id = ? ORDER BY event_id DESC` → apply inverse_payload in order
- Per-file history: `SELECT * FROM events WHERE file_id = ? ORDER BY timestamp DESC`

Every mutation MUST write both `payload_json` (forward) and `inverse_payload_json` (reverse). Without the inverse, undo is broken. Without the event, history is broken.

How to apply: when writing a new mutation, the inverse computation is part of the spec, not an afterthought. If the inverse is hard (e.g., re-encoding loses data), state explicitly how undo works (e.g., "restore from archive folder if still present, else fail").

### 3. Serato library files are never written while Serato is running

`SeratoWatchdog` observes Serato's running state. When Serato is running, writes to Serato's library files MUST queue, not proceed. Filesystem-level operations (moving files) can still proceed. Serato library updates **and audio file-tag writes** are deferred: Serato keeps its own copy of each track's tags and writes its analysis, cues, and edited fields back into the audio files, so a tag written while it runs can be silently reverted (#106; asserted by `testWriteFileTagsQueuesWhileSeratoIsRunning`).

**The full set of Serato library files this rule applies to** — any new mutation that touches Serato MUST round-trip every file in this list, not just the first one or two. (`SeratoLibraryLocator.enumerateCrateFiles` already enumerates the crate-shaped ones together.)

- `~/Music/_Serato_/database V2` — main library; source of truth for the "All" view
- `~/Music/_Serato_/Subcrates/*.crate` — user-curated playlists; reference `otrk`/`ptrk` records
- `~/Music/_Serato_/SmartCrates/*.scrate` — rule-based dynamic playlists. **These are not pure rules — they cache a materialized otrk list** that Serato uses to auto-re-import paths missing from V2 on next launch. Forgetting this directory caused PR #65 (paths kept restoring even after correct V2 rewrites).

Why this exists: Serato caches the library in memory and overwrites the disk version when it saves. Any write we make while Serato is running gets silently overwritten when Serato next saves. From the user's perspective: their changes vanish at random.

How to apply: anything touching the files above goes through `OperationEngine`, which routes through `SeratoWatchdog`. In the UI, every control whose action writes those files uses `.seratoWriteGated(help:runningHelp:)` and its view places a `SeratoRunningBanner`; never hand-roll an `isSeratoRunning` check. Never write directly to `_Serato_` files from another code path. When adding a new Serato-side operation, audit every directory in the list above — silent omissions surface as "the rewrite kept getting undone" mysteries (see PR #65).

### 4. Track identity is Chromaprint, not path

`tracks.fingerprint_hash` is the canonical track identity. `files.path` is just a label — it's how humans refer to files; it's how Serato refers to files; it is not how `crate-agent` refers to recordings.

Why this exists: paths change (rename, move, re-encode); fingerprints don't (within Chromaprint's perceptual tolerance). If we used path-as-identity, every feature past sub-project 1 would break the moment a user renamed a track.

How to apply: new features that need to refer to "the same recording" should use `track_id`, not `path` or `file_id`. The `files ←→ tracks` relationship is many-to-one (multiple files can encode the same recording — FLAC and MP3 of the same song); use the right side of that relationship.

Physical I/O must verify that its actual target still matches the original authorized file; a current row or reused path alone is insufficient. `SeratoWriteEligibility` shares this check across queued effects, while destructive move compensation requires `OwnedAudioIdentity`'s complete digest and precise change identity. See [physical effects and cleanup](docs/serato-membership-reconciliation.md#physical-effects-and-duplicate-cleanup).

Successful owned tag-only writes journal a verified physical identity and fingerprint-basis refresh without changing recording association, membership revision, or Serato-mirrored metadata. New writers must use the shared engine path, or the next strict scan will mistake their own edit for replacement. See the [observation consumer contract](docs/serato-membership-reconciliation.md#consumer-contract).

Keep queued local intent separate from the last authorized external metadata baseline, per file revision and write target. Unchanged saved values preserve queued intent; changed or cleared Serato fields supersede only affected V2 ownership, independently of audio tags—even when SQLite already displays the external value. See the [baseline and History contract](docs/serato-membership-reconciliation.md#consumer-contract).

### 5. The folder layout is artist-first-letter, hardcoded

`<MusicFolder>/<Bucket>/<filename>.ext` — single-letter buckets by the normalized first letter of the artist, with the hardcoded `_0123456789` bucket for normalized leading ASCII digits (`0`–`9`, #132). **No configurable folder template in SP-1.** The normalizer (strip articles, normalize numerics, strip symbols) lives in `ArtistLetterNormalizer.swift` and is the single source of truth for bucket assignment.

Why this exists: the project owner's personal organizational scheme, and a deliberate YAGNI — building a full folder-template engine is real work, building artist-first-letter bucketing is a 100-line function. Multi-user configurability is a Pillar C concern, not a foundation concern.

How to apply: do not introduce a path-template system in SP-1, SP-1.5, SP-2, or SP-3. When `ArtistLetterNormalizer` edge cases arise (Unicode normalization, hieroglyphic artist names, etc.), extend the normalizer rather than escaping the bucketing scheme.

### 6. Filename templates are user-configurable (separate from folder layout)

Filename portion only — Beets-style `$artist - $title ($mixtype).mp3`. The folder portion (rule 5) is not part of this template. Sanitization for filesystem-illegal characters happens in `FilenameTemplateEngine`.

### 7. No multi-machine library portability

Backup (Flavor 1) and sidecar-DB sync (Flavor 3) are in scope. **Cross-machine library portability (Flavor 2) is explicitly out of scope** — we do not build path translation layers, drive-relative path rewrites, or USB-stick portable libraries. Serato's absolute-path model is accepted as a constraint.

Why this exists: a path-translation layer is a major engineering effort that would bloat the foundation. The project owner is one person on one main Mac with an external backup. Solve the actual problem, not the abstract one.

### 8. Large-library plans include interaction budgets and measured fixtures

For startup, navigation, scans, and bulk operations, define the user journey,
expected library size, readiness/interaction budgets, and what remains usable
before implementation. Use a production-scale fixture, compare baseline and final
results with identical data/build settings, and include an actual-screen smoke
checklist. Keep committed browsing available while processing authorization is
closed; never weaken identity or write guards to improve a timing result.

Evidence: [Organize responsiveness](https://github.com/aud-eos/crate-agent/pull/151)
and [incremental startup](https://github.com/aud-eos/crate-agent/issues/129).
See [testing guidance](docs/testing.md#planning-large-library-work) and
`LibraryStartupPerformanceTests` for the 30,000-file fixture and hard budgets.

## Conventions

Universal rules (descriptive variable names, no lint-suppression comments, strict env vars with module-level asserts, no silent failures, etc.) live in `~/.claude/CLAUDE.md` and are hook-enforced. The bullets below are crate-agent-specific only.

- **Comments:** default to none. Only when the *why* is non-obvious. Never explain *what* the code does.
- **Run formatter before committing.** `cargo fmt` for Rust, `swiftformat` (or Xcode's built-in) for Swift.

## Build commands

```
# Rust core (run from repo root)
./scripts/build-rust.sh         # universal static lib for arm64+x86_64
cargo test --manifest-path rust-core/Cargo.toml   # Rust unit tests

# Xcode project
xcodegen generate                # regenerate .xcodeproj from project.yml
xcodebuild -scheme CrateAgent test  # run Swift tests
```

## Where things live

- **Design plan:** [`design-plan.md`](./design-plan.md) — read before significant changes
- **Architectural primitives:** `CrateAgent/Services/OperationEngine.swift` (mutation primitive), `CrateAgent/Services/SeratoWatchdog.swift` (running-state guard), `CrateAgent/Database/Database.swift` (event log + schema)
- **Rust FFI surface:** `rust-core/crate-agent-core.udl` (interface definitions), `rust-core/src/ffi.rs` (implementations)
- **Sub-project sketches:** see `design-plan.md` § "Sketches: SP-1.5, SP-2, SP-3"
