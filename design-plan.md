# crate-agent — Design Plan

## Context

`crate-agent` is a macOS-native application that augments [Serato DJ](https://serato.com/dj) library management. Serato is the user's primary DJ software, but its library management has structural weaknesses that bite working DJs hard:

- Serato stores absolute file paths in its binary library files (`~/Music/_Serato_/`). When the user renames or moves a file in Finder, Serato silently loses access to it.
- Serato has no public API, no plugin system, and no exposed mechanism to manage the library programmatically.
- Common library-hygiene needs (auto-tagging, metadata cleanup, format conversion that preserves DJ-prep work, cross-tool playlist linking, gap analysis against charts) are unmet by Serato itself and unmet by third-party tools that don't know Serato's format.

The opportunity: a tool that sits alongside Serato, reads and writes its on-disk library format directly, watches the filesystem, and offers the missing library-management features as a coherent app. This is the same template Lexicon, Rekordbuddy, and Hazel use for their respective domains.

The first concrete pain point — and SP-1's success criterion — is "Serato no longer loses my files when I rename them in Finder."

## Frozen scope

**16 features grouped into 6 pillars on a shared foundation:**

| Pillar | Features |
|---|---|
| **A — Sync** | reactive rename/move sync (Finder → Serato), manual single-file rename UI |
| **B — Tagging & enrichment** | file metadata read/write, MusicBrainz auto-tagger (AcoustID + Chromaprint), lyrics, custom metadata fields |
| **C — Organization** | track grouping (radio/extended/instrumental as one work), specialized search by metadata, mood/vibe/style tagging, **placeholder/wishlist tracks** |
| **D — External bridges** | Spotify playlist matching, library gap analysis vs charts/DJ pools |
| **E — Backup & sync** | file backup to cloud/disk (Flavor 1, rsync/rclone), sidecar DB sync across user's own Macs (Flavor 3, iCloud Drive) — explicitly **not** multi-machine library portability |
| **F — Format conversion** | re-encoding WAV/FLAC/AIFF/ALAC → MP3 320kbps with Serato analysis preservation (cue points, beatgrid, hot cues carried into the new MP3's ID3v2 GEOB tags) |

**Plus:** library hygiene tools (whitespace, case normalization, find-and-replace, missing-field detection) as a focused follow-up to SP-1.

### Sub-project sequencing

| SP | Scope | Why this slot |
|---|---|---|
| **SP-1** | Foundation + Pillar A | Ships the original pain point. Builds the load-bearing primitives (FFI bridge, fingerprinting, DB, FSEvents, event log) that everything else reuses. |
| **SP-1.5** | Library hygiene tools | Generalizes SP-1's rename primitive into the broader "apply track mutation" primitive. Cleans tag inputs *before* SP-2 auto-tags against them — improves SP-2 quality. |
| **SP-2** | Pillar B (MusicBrainz auto-tagger) | Unlocks every other feature that depends on good metadata. Track-level identity (MBID, AcoustID Recording ID) populates here. |
| **SP-3** | Rule engine for proactive auto-rename | Drives SP-1's rename primitive automatically from templates against SP-2's clean metadata. |
| **SP-4+** | Pillars C, D, E, F | Order TBD when we get there — by then there will be 3 milestones of real-world feedback to inform prioritization. |

## Foundational architecture (locked in via brainstorming)

These decisions are the load-bearing choices that shape every sub-project. They are recorded here so we don't re-litigate them later.

### App shape: Hybrid window + menu bar
- SwiftUI main window for the library browser, tagging, search, grouping UI
- Menu bar status item shows watch state ("crate-agent · watching 14,231 files")
- FSEvents watching continues when the main window is closed
- Idiomatic for macOS utilities that need both real UI and always-on background work (Things, Bear, NotePlan pattern)

### Implementation stack
- **Swift app shell** — SwiftUI primary, AppKit hooks where needed for menu bar / window lifecycle
- **Rust core crate** — wraps community libraries, exposed to Swift via [`uniffi-rs`](https://mozilla.github.io/uniffi-rs/) (auto-generates Swift bindings from `.udl` interface file, no hand-written C shims)
- **SQLite** via [`GRDB.swift`](https://github.com/groue/GRDB.swift) — mature Swift wrapper with migrations, type-safe queries, change observation
- **Distribution** — universal binary (arm64 + x86_64), code-signed, notarized, Sparkle for updates (deferred to post-SP-1)

### Rust core dependencies
- [`triseratops`](https://github.com/Holzhaus/triseratops) — Serato library reader/writer (MIT license, statically linkable)
- `chromaprint` (libchromaprint Rust bindings) — audio fingerprinting from day one
- [`lofty-rs`](https://github.com/Serial-ATA/lofty-rs) — broad-format tag reader/writer (MP3 ID3v2, M4A, FLAC, OGG, WAV)
- LAME (CLI binary, shelled out) — deferred to Pillar F

### Track identity model — three layers, build incrementally

| Layer | Identifies | Populated when |
|---|---|---|
| **File identity** | "Is this the same file on disk as before?" | SP-1 (foundation) |
| **Track identity** | "Is this the same recording as a file I knew about?" | SP-1 (fingerprint from day 1) for Chromaprint hash; SP-2 fills AcoustID + MBID |
| **Work identity** | "Is this the same song across radio/extended/instrumental versions?" | Pillar C |

**Approach 3 was selected:** path + inode + Chromaprint fingerprint computed at index time. Initial scan is parallelized across CPU cores − 2; library browser is usable before scan completes (tracks "promote" from file-identity to track-identity as fingerprints land).

### Folder organization — hardcoded for v1
- **Hardcoded artist buckets**: single-letter alphabetical buckets plus `_0123456789` for normalized leading ASCII digits: `<MusicFolder>/<Bucket>/<filename>.mp3`
- Normalization rules: strip leading articles ("The", "A", "An"); group numeric-leading names ("2Pac", "03 Greedo", "10,000 Maniacs" → `_0123456789`); strip leading symbols ("$uicideboy$" → "S")
- User can override the chosen letter per-track via UI
- **No** configurable folder template in v1 — that's a Pillar C consideration if anyone other than the primary user ever uses this
- Rationale: tags > folders for library organization (genre crossover makes hierarchical folder structures structurally unsolvable for DJ music); flat alphabetical bucketing is constant-bounded depth and ergonomic

### Filename templating — Beets-style
- Templates use `$artist - $title ($mixtype).mp3` syntax compatible with [Beets path format](https://beets.readthedocs.io/en/stable/reference/pathformat.html)
- Sanitization for filesystem-illegal characters
- Uniqueness enforcement (suffix with disambiguator if collision)
- User-configurable in Settings

### Database schema (foundation)

```
files
  file_id PRIMARY KEY
  path TEXT NOT NULL UNIQUE
  volume_uuid TEXT NOT NULL
  inode INTEGER NOT NULL
  file_size INTEGER
  mtime INTEGER
  lightweight_hash BLOB    -- first-1MB + last-1MB SHA-256 (for cross-volume move detection)
  chromaprint_fingerprint BLOB
  fingerprint_status TEXT  -- 'pending' | 'done' | 'failed'
  track_id FOREIGN KEY → tracks(track_id)  -- NULL until fingerprint resolves

tracks
  track_id PRIMARY KEY
  fingerprint_hash BLOB UNIQUE   -- canonical track identity (from Chromaprint)
  acoustid_id TEXT NULL          -- populated by Pillar B
  musicbrainz_recording_id TEXT NULL  -- populated by Pillar B
  artist TEXT
  title TEXT
  album TEXT
  -- additional metadata fields...
  work_id FOREIGN KEY → works(work_id) NULL  -- populated by Pillar C
  is_placeholder BOOLEAN DEFAULT FALSE  -- TRUE when 0 files linked (Pillar C wishlist)

works
  work_id PRIMARY KEY
  -- user-curated grouping; populated by Pillar C (radio/extended/etc.)

events  -- append-only event log; powers undo + per-file history
  event_id PRIMARY KEY AUTOINCREMENT
  batch_id TEXT NOT NULL   -- groups events from a single user-initiated operation
  timestamp INTEGER NOT NULL
  file_id FOREIGN KEY → files(file_id) NULL
  track_id FOREIGN KEY → tracks(track_id) NULL
  event_type TEXT NOT NULL  -- 'track_imported' | 'file_renamed' | 'tag_set' | ...
  payload_json TEXT NOT NULL  -- old/new values, encoder params, etc.
  inverse_payload_json TEXT NOT NULL  -- reverse mutation for undo
```

### The "apply track mutation" primitive

The architectural keystone. Every state-changing operation in the app goes through this:

```
applyMutation(mutation: TrackMutation) async throws -> EventID
  1. Validate mutation against current state
  2. Check Serato-running guard (block-and-queue if running)
  3. Apply mutation:
       - filesystem operation if needed (rename, write file, etc.)
       - Serato library file update via Rust core
       - SQLite row updates
  4. Append event log entry (with inverse payload for undo)
  5. Atomic: all-or-nothing via SQLite transaction
```

**Mutation types per sub-project:**
- SP-1: `RenameFile`, `IndexNewFile`, `RemoveFile`
- SP-1.5: `SetTagField`, `NormalizeWhitespace`, `ApplyFindReplace`
- SP-2: `ApplyMusicBrainzMatch`
- SP-3: (no new mutation type — rule engine drives existing mutations)
- Pillar F: `ReplaceFile` (re-encoding swaps file bytes)

This is the SOLID/DRY way to design it: one primitive, growing set of mutation types, each new feature adds a mutation type rather than a new mechanic.

### Event-sourced undo + per-file history

Single `events` table powers both:

- **Undo last batch:** `SELECT * FROM events WHERE batch_id = ? ORDER BY event_id DESC` → apply `inverse_payload_json` for each in reverse order
- **Per-file history:** `SELECT * FROM events WHERE file_id = ? ORDER BY timestamp DESC` → render as timeline in SwiftUI

Same data, two queries.

## SP-1 detailed design

**Goal:** Ship "Serato doesn't lose my files anymore" with a foundation general enough to support every subsequent sub-project.

### Components

1. **Swift app shell** — `CrateAgentApp.swift`
   - Main window: library browser + status footer
   - Menu bar `NSStatusItem` with popover (recent events, pause/resume, open window, quit)
   - LSUIElement: false; closing window does NOT quit (override `applicationShouldTerminateAfterLastWindowClosed` → false)
   - Onboarding flow: pick music folder → confirm scope → start scan
   - Settings panes: General, Filename Template, Watch Folders, About

2. **Rust core** — `rust-core/src/`
   - `serato.rs` — `read_database()`, `read_crate(path)`, `rewrite_path_in_database(old, new)`, `rewrite_path_in_crate(crate_path, old, new)`
   - `fingerprint.rs` — `fingerprint_file(path) -> Chromaprint` (decodes audio via `symphonia`, fingerprints via `chromaprint-rs`)
   - `tags.rs` — `read_tags(path) -> Tags`, `write_tags(path, tags)` via `lofty`
   - `ffi.rs` — `uniffi` exports
   - `crate-agent-core.udl` — interface definition file

3. **Database layer** — `CrateAgent/Database/`
   - `Database.swift` — singleton, GRDB connection at `~/Library/Application Support/crate-agent/library.sqlite`
   - `Migrations/` — versioned schema migrations (`001_initial.swift`, etc.)
   - Models: `FileRecord`, `TrackRecord`, `EventRecord`

4. **FSEvents watcher** — `Services/FSEventsWatcher.swift`
   - Wraps `FSEventStreamCreate` for the configured music folder(s)
   - Translates raw events into semantic operations: rename-same-volume (FSEvents native), move-cross-volume (delete+create within 5s window + matching size + matching lightweight hash), new-file, deleted-file
   - Persistent: stores `lastEventID` so app restarts resume from the right place (`FSEventStreamCreateRelativeToDevice`)
   - Posts semantic events to the operation queue

5. **Operation engine** — `Services/OperationEngine.swift`
   - Single serial `DispatchQueue` for writes; reads unrestricted
   - Receives mutations from FSEvents watcher and from UI
   - Implements `applyMutation()` for SP-1's three mutation types
   - Defers writes when Serato is running (queues, drains when Serato closes)
   - Wraps each mutation in a SQLite transaction

6. **Fingerprinting pipeline** — `Services/FingerprintWorker.swift`
   - `TaskGroup`-based worker pool, `N = ProcessInfo.processInfo.activeProcessorCount - 2`
   - Polls `files` table for `fingerprint_status = 'pending'`, fingerprints in parallel, writes results
   - Reports progress via `Combine.PassthroughSubject` to UI
   - Resumable across app restarts (state lives in DB)

7. **Library browser UI** — `Views/LibraryBrowserView.swift`
   - `Table`-based view sortable/filterable on artist, title, year, fingerprint status
   - Right-click context menu: "Rename…", "Show in Finder", "Reveal in Serato", "Show History"
   - Onboarding state machine: `.noLibrary` → `.scanning(progress)` → `.ready`

8. **Menu bar item** — `Views/MenuBarStatusView.swift`
   - Status string: "Watching N files" / "Scanning… X%" / "M pending (Serato running)" / "Paused"
   - Click opens popover: recent events list, pause/resume toggle, open main window, quit

9. **Serato watchdog** — `Services/SeratoWatchdog.swift`
   - Observes `NSWorkspace.shared.runningApplications` for Serato bundle ID
   - On Serato launch: signals operation engine to defer writes to Serato library files (filesystem renames still proceed; only Serato `.crate` / database updates queue)
   - On Serato quit: signals engine to drain the deferred queue
   - UI shows banner: "Serato is open — N changes queued"

10. **History / undo UI** — `Views/HistoryView.swift`
    - Global recent-activity timeline
    - Per-track history (filtered by `file_id` or `track_id`)
    - "Undo last operation" / "Undo last N operations" controls

### Critical files to create

```
crate-agent/
├── CrateAgent.xcodeproj
├── CrateAgent/
│   ├── CrateAgentApp.swift                # App entry, scene config
│   ├── App/
│   │   ├── AppDelegate.swift              # LSUIElement, lifecycle
│   │   └── Onboarding/
│   ├── Views/
│   │   ├── LibraryBrowserView.swift
│   │   ├── MenuBarStatusView.swift
│   │   ├── HistoryView.swift
│   │   ├── RenameDialogView.swift
│   │   └── SettingsView.swift
│   ├── ViewModels/
│   │   └── LibraryViewModel.swift
│   ├── Models/
│   │   ├── FileRecord.swift
│   │   ├── TrackRecord.swift
│   │   └── EventRecord.swift
│   ├── Services/
│   │   ├── FSEventsWatcher.swift
│   │   ├── OperationEngine.swift
│   │   ├── FingerprintWorker.swift
│   │   ├── SeratoWatchdog.swift
│   │   ├── FilenameTemplateEngine.swift
│   │   └── ArtistLetterNormalizer.swift
│   ├── Database/
│   │   ├── Database.swift
│   │   └── Migrations/
│   │       └── 001_initial.swift
│   └── Resources/
├── rust-core/
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs
│   │   ├── serato.rs
│   │   ├── fingerprint.rs
│   │   ├── tags.rs
│   │   └── ffi.rs
│   └── crate-agent-core.udl
├── scripts/
│   ├── build-rust.sh                      # cross-compile universal Rust static lib
│   └── codesign.sh
├── .gitignore
├── README.md
└── CLAUDE.md                              # project-level Claude instructions
```

### Out of scope for SP-1 (explicit)

- MusicBrainz / AcoustID API integration (SP-2)
- Tag *writing* (SP-1.5 — SP-1 reads tags for filename templating but doesn't yet expose hygiene operations)
- Rule engine for automatic renames (SP-3)
- Track grouping, search, mood tagging, placeholders, Spotify, charts, backup, re-encoding (SP-4+)
- Configurable folder structure (hardcoded artist-first-letter in v1)
- Sparkle update framework (post-SP-1)
- App Store distribution (post-SP-1; ship as direct-download notarized DMG initially)

## Sketches: SP-1.5, SP-2, SP-3

Brief — full design specs to be written when each sub-project starts. Included here only to validate the SP-1 architecture absorbs them cleanly.

### SP-1.5 — Library hygiene

- Adds `SetTagField` mutation type to operation engine
- Adds tag *write* path to Rust core's `tags.rs` (Lofty supports it)
- New `LibraryCleanupView.swift` with panels: Whitespace, Case, Find-and-Replace, Missing Fields
- Find-and-replace requires preview pane: shows diffs for every matched row with per-row checkboxes (Mp3tag pattern)
- All operations route through `applyMutation()` and gain undo + history automatically

### SP-2 — MusicBrainz auto-tagger

- Adds HTTP client (`URLSession` based, with disk cache and polite rate limiting per [MusicBrainz etiquette](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting))
- New `Services/AcoustIDClient.swift` (fingerprint → Recording IDs)
- New `Services/MusicBrainzClient.swift` (Recording ID → release metadata)
- New `ApplyMusicBrainzMatch` mutation type
- New `AutoTaggerView.swift` with candidate list, confidence scoring, manual confirm/reject
- Populates `tracks.musicbrainz_recording_id` and `tracks.acoustid_id` columns (already in schema)
- AcoustID API key configurable in Settings

### SP-3 — Rule engine for proactive auto-rename

- Template parser (Beets path format compatible subset)
- New table `rules(rule_id, name, scope_query, template, enabled, created_at)`
- Rule execution hook in `OperationEngine` import path
- Rule UI: `RulesView.swift` with template editor, preview pane (apply against N sample tracks), enable/disable toggle
- No new mutation type — rules drive existing `RenameFile` mutations

## SP-4+ pillar roadmap (order TBD)

Brief enumeration. Each gets its own design spec when prioritized.

- **Pillar C (Organization):** Track grouping (works), specialized search (DB-backed query builder), mood/vibe tagging (manual first; automated mood detection deferred), **placeholder tracks** (tracks with zero linked files; manual entry + drag-drop fill-in)
- **Pillar D (External bridges):** Spotify OAuth + Web API + ISRC-or-fuzzy-match algorithm; chart/DJ-pool gap analysis (Beatport, Billboard, DJ City) auto-populating placeholders
- **Pillar E (Backup & sync):** `rclone` orchestration UI for cloud backup (Flavor 1); iCloud Drive placement for sidecar SQLite DB (Flavor 3)
- **Pillar F (Format conversion):** Bundled LAME CLI; per-track or bulk re-encode; **Serato analysis preservation** (read cue points + beatgrid + hot cues from source via triseratops, write into output MP3's ID3v2 GEOB tags); originals archived to configurable archive folder

## Verification (SP-1)

### Unit tests (Rust core)
- Read a known Serato `.crate` file from `test-fixtures/` → verify expected track list
- Rewrite a path in a `.crate` file → byte-compare against expected output
- Fingerprint a known audio file (e.g., a public-domain track committed to the repo) → verify expected Chromaprint value

### Integration tests (Swift)
- Build a test music library with 50 files in `tmp/test-library/`
- Run a full index → verify all expected rows in DB and all files have fingerprints
- Simulate rename via `FileManager.moveItem` → verify Serato `.crate` reflects the new path
- Simulate move across volumes (use two test volumes via `hdiutil`) → verify cross-volume move is detected (not duplicated as new + delete)
- Apply rename → undo → verify state is fully restored (file path AND Serato refs AND DB row)
- Simulate Serato-running state → verify operations queue → simulate Serato quit → verify queue drains

### Manual end-to-end test
1. Install crate-agent on a real Mac with a real Serato install
2. Point at user's actual music folder (or a backup copy of it)
3. Wait for initial scan to complete (record duration as benchmark)
4. With Serato closed: rename a file in Finder → open Serato → confirm track still appears in its crate at new path
5. With Serato open: rename a file in Finder → confirm crate-agent shows "1 pending" → quit Serato → confirm queue drains → reopen Serato → confirm path updated
6. Use the manual rename UI to rename a single track via template → confirm filesystem + Serato + DB all consistent
7. Trigger undo → confirm full reversal

### Performance gates (SP-1)
- Initial scan: ≤ 30 minutes for 10,000-track library on M-series Mac
- Steady-state memory: ≤ 200 MB resident
- FSEvents → Serato library update latency: ≤ 2 seconds for single rename (when Serato is closed)
- UI responsiveness: library browser scroll remains 60fps with 50,000 rows

## Open questions deferred to implementation time

These are real questions but don't block design approval — they get resolved during SP-1 build:

- Exact Serato bundle ID for runningApplications observation (need to verify: `com.serato.dj` vs `com.serato.djpro` vs others depending on Serato version)
- `uniffi` vs `swift-bridge` for the FFI layer — both viable; pick whichever has smoother Xcode integration when we get hands on it
- Whether to support `~/Music/_Serato_/` *and* per-drive `_Serato_/` folders in v1 or only the home directory location
- Whether to ship a one-time "import existing Serato library" assistant or just observe the existing files in place (probably the latter — less risky)

## What's not in this document

- Implementation details below the "what file does what" level (those are for SP-1's implementation plan, written via `superpowers:writing-plans` after this design is approved)
- Detailed UI mockups (handled in implementation)
- CI/release pipeline (post-SP-1)
- Licensing / pricing / distribution strategy (post-SP-1; this is a personal tool first)
