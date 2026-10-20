# Library Readiness Checklist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Library row shows what its file still needs before the library is finished, and the owner can sort, filter and count by those needs, mark keepers and combine all of it with search and new genre, BPM and key filters, within the 30,000-file budgets.

**Architecture:** External observations that are costly to read (Serato crate membership, V2 beatgrid lock and date added, cue points from audio tags, confirmed duplicate groups) are cached in derived tables keyed by `file_id`. Each table is written only by its own service, in short transactions. The checklist itself is not stored. It is computed in SQL inside the existing Library projection (`LibraryBrowseQuery.placedSQL`) from those tables and the indexed `files` columns. Chips, sort columns and facet filters are fields of `LibraryBrowseQuery`, and live counts come from the same snapshot. Keeper is a new `TrackMutation` with inverse payloads.

**Tech Stack:** Swift 6 / SwiftUI and AppKit (`PagedNSTableView`), GRDB (WAL `DatabasePool`), Rust `crate-agent-core` over UniFFI 0.28, `lofty` 0.24, `base64` 0.22.

**Spec:** `docs/superpowers/specs/2026-10-17-library-readiness-design.md` (approved). This plan covers its first suggested delivery step only: Goal 1, Goal 5, the Goal 3 columns Still needs, Date added and My plays, the Goal 3 chips, and the combination with search and the facet filters. Popularity, Hot, Prepare, version attributes (#137), Add to crate and batch removal are later phases.

## Rulings made without the owner

Each ruling lists its reason and what it costs if it turns out to be wrong.

1. **Cue points come from `Serato Markers2` `CUE` entries in the audio file's tags.** An in-house Rust parser follows the Holzhaus/serato-tags format documentation, which `serato.rs` already cites. The project chose in-house Serato parsing over `triseratops` (see the `rust-core/Cargo.toml` comment), and no other maintained Rust parser exists, so the only new dependency is `base64`. The parser covers ID3v2 `GEOB` frames (MP3, AIFF, WAV), MP4 freeform `----:com.serato.dj:markersv2` and Vorbis `SERATO_MARKERS_V2` (FLAC, Ogg). A file with no Markers2 has 0 cues. An unsupported container or a malformed payload is *unknown*, never "No cues", and its reason appears in Workers. *If wrong:* some formats show wrong counts or unknown. The fault is confined to one Rust module and its byte-level tests.
2. **"Beatgrid checked" is the V2 `bbgl` (beatgrid locked) flag.** It is read from `database V2` with no audio reads, as Mixxx's Serato importer reads it. The audio reader also returns `beatgrid_marker_count` from `Serato BeatGrid`, which the tooltip uses to say "No beatgrid" rather than "Grid not locked". The smoke checklist confirms that locking a grid in Serato flips the flag. *If wrong:* the Grid unchecked chip is wrong for everyone. The honest fallback is one SQL expression in `LibraryChecklist`: `beatgrid_marker_count > 0`, labelled "No beatgrid".
3. **Crate membership counts Subcrates only (`Subcrates/*.crate`; SmartCrates excluded).** It is read through the existing `read_crate_paths` and cached in `serato_crate_memberships` by `file_id`. `SeratoLibraryFactsService` refreshes it after each completed sync, while Serato is closed, and only when the persisted crate stamps or the library path signature changed. It is not computed inside `SeratoLibrarySyncSession`. That session's checkpoint fast path rebuilds records from `SeratoMetadata` and would drop these facts, and coupling to it puts the most delicate code at risk. *If wrong:* membership changed in Serato appears only after Serato closes, the same lag as every other Serato fact.
4. **Date added is `uadd` from V2, else `tadd`, else the file's first journaled event time.** `uadd` is the binary form of the same date as `tadd`. The fallback is labelled "First indexed". Every active file gets a facts row, including files absent from V2, which get `indexed` and NULL grid facts. It is computed once per facts refresh, not per query. *If wrong:* if `uadd` and `tadd` disagree in real libraries, swap their order in one Rust function.
5. **Quality passes at 256 kbps or more (`LibraryChecklist.minimumLossyBitrateKbps = 256`).** It also passes when the bitrate is unknown and the extension is lossless (`flac`, `wav`, `aif`, `aiff`). It is unknown when the bitrate is unknown and the format is lossy. Lossless files carry a bitrate of 256 or more, so the extension matters only when the bitrate is missing. *If wrong:* the threshold is one constant.
6. **Too many versions means more than 4 distinct versions in the song family (`LibraryChecklist.maximumFamilyVersions = 4`), counted by `SongFamilyMutation.versionKeySQL` as families already are.** Files whose version key equals the main row's are exempt, including other encodings of the main version. Four covers a common DJ-pool set (dirty, clean, instrumental, acapella), so a fifth version suggests filler. The item applies only to files in a family. *If wrong:* it over- or under-flags until the constant changes.
7. **Keeper storage is `keeper_marks(file_id PK, marked_revision, marked_at)`, scoped by the recording key `KeeperMarks.recordingKeySQL = COALESCE(SongFamilyMutation.versionKeySQL, 'file:' || files.id)`.** That key is the MusicBrainz recording ID, else the `tracks` row, else the file itself. A shared `track_id` alone is not used: under Invariant 4 a FLAC and an MP3 normally have separate `tracks` rows, and a shared MusicBrainz ID is the cross-encode signal.
   - A file is *protected* when it has a valid mark, or when it shares its recording key with a file that has one. A mark is valid while `marked_revision >= COALESCE(files.last_projection_invalidation_revision, 0)`, so content replacement or retirement drops it.
   - Marking a file that holds an invalid stale row replaces that row in the same transaction.
   - Clearing a keeper clears every valid mark that shares the key. Conflict targets include every file and `track_id` sharing it.
   - This differs from the spec's own call ("My calls", open to change) that the flag *moves* when a file gains a recording. Every path that changes a file's recording key (match, song-family link, recording separation, rejoin, restore) is already a journaled mutation, so protection follows each change and its undo, and nothing has to move.
   - *If wrong:* if MusicBrainz IDs are wrongly shared, a keeper over-protects siblings, which is visible and undoable. If the owner wants an explicit "keeper moved" History event, it can be added to the link mutations later without a schema change.
8. **The checklist is computed in SQL from stored facts, not stored as a mask.** Its inputs change through at least ten writers: metadata mirroring, tag edits, family mutations, recording identity, keeper, duplicate digests, crates, V2 facts, analysis and play counts. A stored mask would need invalidation in every one of them. Primary-key joins inside the existing projection are cheap, and Task 5's 30k test is the gate. SQL is the only source of the rule: it projects `is_finished` and `still_needs_count`, and Swift reads them rather than recomputing. *If wrong:* if that test misses 500 ms, the fallback is a `file_checklist` table maintained by a `LibraryChecklistService` on the same observation regions. The query contract (Task 5 Interfaces) does not change.
9. **Duplicates come from `DuplicateFinder.findDuplicates`, both modes, using cached digests only.** It never decodes and runs in about 0.17 s at 30k. Groups with `check == .confirmed` and no kept label review are recorded. Needs-listening groups are not. Members are cached in `checklist_duplicate_members` and refreshed on `DuplicateScanObservation` changes. Only the file's *own* valid keeper mark suppresses the flag. Recording-level protection does not, so the worse copy of a kept recording still shows Duplicate and stays removable, as the spec says.
10. **Chips and facets filter the way search does.** A family's main row shows when any member matches, and matching alternates are revealed. Alternate reveal switches from `LibraryBrowseQuery.isSearching` to a new `isFiltering` (search or chip in Task 5; Task 6 adds facets), and the "hidden by search" copy becomes "hidden by search or filters". Chips are single-select. A chip's count is the number of *files* in the current scope (status, search and facets, with no chip) that the chip matches.
11. **Genre, BPM and key filters do not exist on main, so Task 6 builds them.** Genre is a multi-select of stored values. BPM is an inclusive numeric range over `CAST(bpm AS REAL)`, and empty or 0 never matches. Key is Camelot-compatible: the same key, ±1 in the same mode, or the relative major or minor. Musical, Camelot and Open Key notations are all accepted. Keys and genres are matched through stored strings resolved in Swift from the distinct values (`json_each`), never through a per-row Swift SQL function. `ListSearch` records that per-row Swift calls broke the 30k budget.
12. **Unknown is not failing.** An unread fact shows as unknown (for example "Cues unknown"). Definite-failure chips exclude it. It blocks Finished, so the file counts toward Needs work.
13. **Keeper and Finished.** A protected file is Finished, and protection suppresses the versions item. Only the file's own mark suppresses the duplicate item (Ruling 9). A kept file's preparation tags (crate, cues, grid, metadata, quality) still show.
14. **My plays is in scope, because `serato_play_counts` exists on main (migration 022).** A file with no row has 0 plays, and Never played means no row. The Never played chip is disabled, with help text, until `SeratoPlayCountService` reaches `.refreshed` in this session.
15. **Readiness table changes refresh the Library at most every 2 s (`LibraryChecklist.refreshThrottle`).** Without the throttle, the analysis backfill's batch writes would reopen the snapshot continuously. `files` and family changes keep their immediate refresh.

## Global Constraints

- Invariants 1–4 and 8 in `CLAUDE.md`. Keeper is a `TrackMutation` with a complete `SeratoConflictTargets.mutation` case (it writes no Serato file, so its targets are every file and `track_id` sharing the recording key of Ruling 7). Derived observation tables are written by their services, never through `applyMutation`, like `serato_play_counts`.
- Every V2 and crate read runs while Serato is closed (`watchdog.isClosed(atRevision:)`). Nothing in this plan writes Serato files.
- Migrations are 030, 031 and 032. They are schema-only and registered in `CrateAgent/Database/Database.swift` after `AddSeratoRemovalCapturesMigration`.
- **Naming.** "Readiness" already means sync readiness (`LibrarySyncReadiness`), so checklist code uses `Checklist`: `ChecklistItem`, `FileChecklist`, `ChecklistChip`, `LibraryChecklist` and `LibraryChecklistMessages`.
- No single-character identifiers, closure parameters included. No `as` casts that bypass checking; decode with `guard let` or typed `Row` access.
- Every user-facing string used more than once goes in `CrateAgent/Constants/LibraryChecklistMessages.swift`.
- No chevron, triangle or caret disclosures. A SwiftUI `Menu` uses `.menuIndicator(.hidden)` and a text label that shows its state ("Genre: House", "Key: Any").
- Writer transactions stay under 500 ms. Derived writes are capped at 1,000 rows per transaction, and analysis batches at 200.
- Write the fewest tests, and each must fail first on its assertion. There are no tests for constants, copy or view wiring.
- At most two test suites, builds or container jobs run at once.
- Run `make format`, then `git diff --stat`, and restore any formatter drift outside the task's files before each commit (owner memory).
- Commit messages are sentence-style, like `git log`, with no attribution lines.

## Invariant 8: journeys, budgets, fixtures, evidence

**User journeys, with a 30,000-file library.**
1. *Live idea hunt:* open Library, type an artist, choose genre "House", BPM 124–128 and Key compatible with 8A, then sort by My plays or Date added.
2. *Prep pass:* choose the Needs work chip, sort by Still needs, read the tags, and fix in Serato or Auto-Tag. The row updates after the next sync or analysis pass.
3. *Noise review:* choose Too many versions, mark gems as keepers, and confirm they move to Finished. Undo the keeper from History.
4. *First launch after upgrade:* browsing works at once. Checklist cells read "Checking" until facts and analysis fill in, with no blocking and no writer stalls.

**Budgets.** These are hard assertions, measured with the optimized Test command in `docs/testing.md`.
- Opening a snapshot plus its first page for any sort (including Still needs, Date added and My plays), any chip, or chip, search and facets combined: under 500 ms each.
- Loading chip counts for a snapshot: under 500 ms. The counts load after the first page, so they never delay it.
- Longest writer wait during a facts refresh, an analysis batch or a duplicate-member refresh: under 500 ms (`WriterHoldProbe`).
- While facts and analysis compute, production Library rendering and sidebar navigation stay under 500 ms. That is the browse-availability budget.

**Fixtures.**
- Query budgets: `PagedLibraryFixture` (30,000 rows), used by `LibraryPagingTests`, with checklist facts seeded in SQL. Task 5 sets this up and Task 6 extends it.
- Background budgets: `LibraryStartupPerformanceFixture` (30,000 real WAVs plus encoded V2), used by `LibraryStartupPerformanceTests`. Tasks 2 and 3 extend it with `bbgl` and `uadd` fields and 20 Subcrates of 1,000 paths.

**Baseline versus final.** Task 1 Step 1 records `SONG_FAMILY_PAGING_METRICS` and `STARTUP_*` on the unmodified branch. Task 8 reruns them with identical settings and records both in `docs/testing.md`. Existing interactions (sort, search, expand and include alternates) must not regress by more than 20%, or Task 8 stops and reports.

**On-screen smoke checklist (owner, in the running app).** This is in Task 8.

## Review Focus

Each of the five conditions below is pinned by a test in its owning task.

1. **Crate paths in a different Unicode form** (NFD in the crate, NFC in `files`) still count as in a crate. Pinned in Task 2, `testCrateMembershipMatchesUnicodeFormsAndFollowsRenames`.
2. **A file renamed by crate-agent after facts were read** keeps its membership: crates are rewritten, so the stamp changes and the facts are remapped by file. Pinned in the same test.
3. **BPM text variants** ("128.000", "128", "", "0", "126.5") filter numerically, and empty or zero never matches a range. Pinned in Task 6, `testFacetsCombineWithChipAndSearch`.
4. **Unparseable keys** ("", "Unknown", "o", "H#m") never match a compatible-key filter and never crash. Pinned in Task 6, `testCamelotParsingAndCompatibilityAcrossNotations`.
5. **A kept recording whose encodings are later separated** (they stop sharing a recording key) leaves protection only on the marked file. Pinned in Task 4, `testSeparatingAKeptRecordingLeavesProtectionOnTheMarkedFileOnly`.

---

### Task 1: Rust readers for Serato analysis and V2 track facts

**Files:**
- Create: `rust-core/src/serato_analysis.rs`
- Modify: `rust-core/src/serato.rs` (track-facts extraction beside `extract_track_record`), `rust-core/src/lib.rs`, `rust-core/src/ffi.rs`, `rust-core/src/crate-agent-core.udl`, `rust-core/Cargo.toml` (`base64 = "0.22"`)

**Interfaces:**
- Produces (UDL):
  ```
  dictionary SeratoTrackFacts { string path; boolean? beatgrid_locked; u32? added_at; };
  dictionary SeratoAnalysis { u32 cue_count; u32 beatgrid_marker_count; };
  [Throws=CoreError] sequence<SeratoTrackFacts> read_database_track_facts(string database_path);
  [Throws=CoreError] SeratoAnalysis read_serato_analysis(string file_path);
  ```
  Swift sees `readDatabaseTrackFacts(databasePath:)` and `readSeratoAnalysis(filePath:)`. The module function and the FFI function share the name `read_serato_analysis`, so qualify the module path in `ffi.rs`. `added_at` is Unix seconds from `uadd` (u32 BE), else `tadd` parsed as a decimal string. `beatgrid_locked` is the first byte of `bbgl` being non-zero. A missing field is `None`.
- `read_serato_analysis` fails with `CoreError` for an unsupported container, an unreadable file or a malformed payload. The error message names which, because Workers shows it.

- [ ] **Step 1: Record the baseline before any change.** Run the optimized Test command from `docs/testing.md` § Incremental startup fixture, once with `-only-testing:CrateAgentTests/LibraryStartupPerformanceTests` and once with `-only-testing:CrateAgentTests/LibraryPagingTests/testSongFamilyProjectionStaysWithinPagingBudgetsAtThirtyThousandFiles`. Save the `SONG_FAMILY_PAGING_METRICS` and `STARTUP_*` lines and the commit hash to `$SCRATCHPAD/library-checklist-baseline.txt` (not committed). Expected: both pass.

- [ ] **Step 2: Write the failing Rust tests in `serato_analysis.rs`.** Build the inputs from the serato-tags layouts. Markers2 decoded body: `0x01 0x01`, then entries of `NUL`-terminated type, a u32 BE length and data. `CUE` data is 13+ bytes plus a NUL-terminated name. The ID3 GEOB payload is `0x01 0x01` plus base64 text with line breaks every 72 characters and no padding. The MP4 and Vorbis value is base64 of `application/octet-stream\0\0Serato Markers2\0` plus that GEOB payload. BeatGrid: `0x01 0x00`, a u32 BE marker count, the markers, then one footer byte.
  ```rust
  #[test] fn markers2_counts_cue_entries_and_ignores_color_bpmlock_and_loops() {
      let body = markers2_body(&[cue(0), cue(1), entry("COLOR", &[0, 0xff, 0xff, 0xff]), entry("BPMLOCK", &[1]), loop_entry(0)]);
      assert_eq!(count_markers2_cues(&decode_markers2_geob(&geob_payload(&body)).unwrap()).unwrap(), 2);
  }
  #[test] fn markers2_base64_tolerates_newlines_missing_padding_and_a_dangling_character() { /* same body, three encodings, all → 2 */ }
  #[test] fn vorbis_and_mp4_envelopes_unwrap_to_the_same_markers2_body() { /* envelope(body) → 2 cues */ }
  #[test] fn malformed_markers2_is_an_error_not_zero() { assert!(count_markers2_cues(&[0x01, 0x01, b'C', b'U']).is_err()); }
  #[test] fn wav_with_id3_geob_reads_cues_and_grid_and_untagged_wav_reads_zero() {
      // write_silent_wav + lofty WavFile id3v2 GEOB "Serato Markers2" (2 cues) and "Serato BeatGrid" (1 marker)
      assert_eq!(read_serato_analysis(&tagged).unwrap(), SeratoAnalysis { cue_count: 2, beatgrid_marker_count: 1 });
      assert_eq!(read_serato_analysis(&untagged).unwrap(), SeratoAnalysis { cue_count: 0, beatgrid_marker_count: 0 });
  }
  ```
  In `serato.rs` tests:
  ```rust
  #[test] fn track_facts_read_bbgl_and_uadd_with_tadd_fallback() {
      // three otrks: {pfil, bbgl=[1], uadd=1_700_000_000}, {pfil, tadd="1600000000"}, {pfil}
      assert_eq!(facts, vec![(Some(true), Some(1_700_000_000)), (None, Some(1_600_000_000)), (None, None)]);
  }
  ```

- [ ] **Step 3: Run the tests to verify they fail.** Run `cargo test --manifest-path rust-core/Cargo.toml -- serato_analysis track_facts`. Expected: FAIL, because the functions are not defined.

- [ ] **Step 4: Implement.**
  - `serato_analysis.rs`: `pub fn read_serato_analysis(path: &Path) -> Result<SeratoAnalysis, AnalysisError>`. Dispatch on `lofty::file::FileType` from `Probe::open(path)?.guess_file_type()`, and parse with `ParseOptions::new().read_properties(false)`. MPEG, AIFF and WAV read `id3v2()` frames whose ID is `GEOB`, through `GeneralEncapsulatedObject::parse`, matched by descriptor `Serato Markers2` and `Serato BeatGrid`. MP4 reads `ilst()` freeform atoms with mean `com.serato.dj` and names `markersv2` and `beatgrid`. FLAC and Ogg read Vorbis `SERATO_MARKERS_V2` and `SERATO_BEATGRID`. Any other type returns `AnalysisError::UnsupportedFormat`.
  - Base64 decoding strips ASCII whitespace and `=`, drops one dangling character when `len % 4 == 1`, and decodes with a `GeneralPurpose` engine configured with `decode_allow_trailing_bits(true)` and `DecodePaddingMode::Indifferent`.
  - `serato.rs`: `pub fn read_database_track_facts(path) -> Result<Vec<SeratoTrackFacts>, SeratoError>`. It walks top-level `otrk` records with `walk_nested_fields` and reads only `pfil`, `bbgl`, `uadd` and `tadd`. A record without `pfil` is skipped, as `extract_track_record` does.

- [ ] **Step 5: Run the tests to verify they pass.** Run `cargo test --manifest-path rust-core/Cargo.toml`, then `./scripts/build-rust.sh`. Expected: PASS, and the bindings regenerate.

- [ ] **Step 6: Commit.**
  ```bash
  cargo fmt --manifest-path rust-core/Cargo.toml
  git add rust-core
  git commit -m "Read Serato cue points, beatgrid markers and V2 track facts in the Rust core"
  ```

### Task 2: Serato library facts service (V2 facts and Subcrates membership)

**Files:**
- Create: `CrateAgent/Database/Migrations/AddChecklistFactsMigration.swift` (`030_add_checklist_facts`), `CrateAgent/Services/SeratoLibraryFacts.swift` (plan and apply), `CrateAgent/Services/SeratoLibraryFactsService.swift`
- Modify: `CrateAgent/Database/Database.swift`, `CrateAgent/App/AppServices.swift` (construct the service and refresh it in the existing `session.$state` `.ready` sink beside `playCountService`), `CrateAgent/Services/SeratoPlayCountService.swift` (generalize `SeratoHistorySessionStamp` into the shared `SeratoDirectoryStamp`; History passes `historyDirectoryUrl/Sessions` and `"session"`), `CrateAgent/Services/SeratoPlayCounts.swift` (make `SeratoLibraryPathSignature` `Codable`)
- Test: `CrateAgentTests/SeratoLibraryFactsTests.swift`, `CrateAgentTests/LibraryStartupPerformanceTests.swift`, `CrateAgentTests/Support/LibraryStartupPerformanceFixture.swift`

**Interfaces:**
- Consumes: `readDatabaseTrackFacts(databasePath:)` from Task 1, the existing `readCratePaths(cratePath:)`, `SeratoPath.normalized`, `SeratoPlayCounts.librarySignature(in:)`, and `SeratoLibraryLocator.subcratesDirectoryUrl` and `databaseV2Url`.
- Schema (migration 030):
  ```sql
  CREATE TABLE serato_track_facts (file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
      beatgrid_locked INTEGER, added_at INTEGER, added_source TEXT NOT NULL CHECK (added_source IN ('serato', 'indexed')));
  CREATE TABLE serato_crate_memberships (file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      crate_name TEXT NOT NULL, PRIMARY KEY (file_id, crate_name)) WITHOUT ROWID;
  CREATE TABLE checklist_source_stamps (source TEXT PRIMARY KEY, stamp TEXT NOT NULL);
  CREATE TABLE checklist_duplicate_members (file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE, group_key TEXT NOT NULL);
  ```
  Task 3 fills `checklist_duplicate_members`. It is created here so that 030 holds all the checklist fact tables.
- Produces:
  ```swift
  struct SeratoDirectoryStamp: Codable, Equatable, Sendable { let name: String; let size: Int; let modified: Date
      static func all(in directory: URL, pathExtension: String) throws -> [SeratoDirectoryStamp] }   // History uses it too
  enum ChecklistSource: String, Sendable { case databaseV2 = "database_v2", subcrates }
  enum DateAddedSource: String, Codable, Sendable, DatabaseValueConvertible { case serato, indexed }   // decoded strictly; unknown text throws
  struct SeratoLibraryFactsSummary: Equatable, Sendable { let trackFactCount: Int; let crateCount: Int; let membershipCount: Int; let unmatchedPathCount: Int }
  enum SeratoLibraryFacts {
      static let factsTable = "serato_track_facts", membershipTable = "serato_crate_memberships", stampTable = "checklist_source_stamps"
      static func plan(facts: [SeratoTrackFacts]?, crates: [String: [String]]?, stamps: [ChecklistSource: String], in database: GRDB.Database) throws -> SeratoLibraryFactsPlan
      static func apply(_ plan: SeratoLibraryFactsPlan, to writer: any DatabaseWriter) async throws -> Bool  // false = library paths changed; retry
  }
  @MainActor final class SeratoLibraryFactsService: ObservableObject {
      enum Status: Equatable { case notRefreshed, refreshing, refreshed(SeratoLibraryFactsSummary), skippedWhileSeratoRunning, failed(String) }
      @Published private(set) var status: Status
      init(database: LibraryDatabase, seratoLocator: SeratoLibraryLocator, watchdog: SeratoWatchdog,
           readFacts: @escaping @Sendable (String) async throws -> [SeratoTrackFacts] = { path in try readDatabaseTrackFacts(databasePath: path) },
           readCrate: @escaping @Sendable (String) async throws -> [String] = { path in try readCratePaths(cratePath: path) })
      func refresh() async   // coalesces like SeratoPlayCountService.refresh()
  }
  ```
  Each source's stamp is the JSON of its inputs plus `SeratoLibraryPathSignature`. For V2 that is its `SeratoSourceIdentity`. For Subcrates it is `SeratoDirectoryStamp.all(in: subcratesDirectoryUrl, pathExtension: "crate")`. A source is read only when its stored stamp differs, so an unchanged restart reads nothing.
- `plan` maps paths to `file_id` by `SeratoPath.normalized` over `files.path` for non-retired files. A path two files claim, or none, counts as unmatched. Every non-retired file gets a facts row: one with no V2 record gets `added_source = indexed` and NULL `beatgrid_locked`. The plan holds only rows that differ from storage. `apply` checks the library signature in each transaction and writes at most 1,000 rows per transaction. It writes the stamp in the last transaction, so an interrupted refresh reruns. The "indexed" fallback for `added_at` is `MIN(events.timestamp) / 1000` per file, taken in one grouped read.
- A failed read keeps the previous rows and stamp, and sets `.failed(reason)`. Task 7 shows that reason in Workers.

- [ ] **Step 1: Write the failing tests.** Use a temporary WAL `LibraryDatabase` with `SeratoTestEncoding` V2 and crate files, as `SeratoRemovalFixture` does, and a real `SeratoWatchdog` reporting closed.
  ```swift
  func testFactsRefreshMapsV2FactsAndSubcratesButNotSmartCrates() async throws {
      // files A, B, C; V2: A {bbgl 1, uadd 1_700_000_000}, B {}; C absent from V2; Subcrates/Warmup.crate: A; SmartCrates/Recent.scrate: B, C
      await service.refresh()
      XCTAssertEqual(try facts(A), .init(beatgridLocked: true, addedAt: 1_700_000_000, addedSource: .serato))
      XCTAssertEqual(try facts(B).addedSource, .indexed)           // first event time
      XCTAssertEqual(try facts(C), .init(beatgridLocked: nil, addedAt: firstEventSeconds(C), addedSource: .indexed))
      XCTAssertEqual(try memberships(), [A: ["Warmup.crate"]])     // B and C only in a SmartCrate
  }
  func testUnchangedSourcesAreNotReadAgainByAFreshService() async throws {
      await service.refresh()
      let reopened = SeratoLibraryFactsService(database: database, ..., readFacts: countingFacts, readCrate: countingCrate)
      await reopened.refresh()
      XCTAssertEqual(readCounts, .init(facts: 0, crates: 0))
  }
  func testFailedReadKeepsPreviousFactsAndReportsTheReason() async throws { /* second refresh with a throwing reader */
      XCTAssertEqual(service.status, .failed("…reader message…")); XCTAssertEqual(try memberships(), previous)
  }
  func testCrateMembershipMatchesUnicodeFormsAndFollowsRenames() async throws {
      // crate holds the NFD spelling of A's NFC path → A is a member;
      // then OperationEngine renames A (crate rewritten), refresh → A still a member under its new path, no orphan row
  }
  ```
  In `LibraryStartupPerformanceTests`, add a step `verifyWriterHoldWhileRefreshingSeratoFacts(fixture)`. It runs the first facts refresh over 30,000 records with `bbgl` and `uadd`, plus 20 crates of 1,000 paths, under `WriterHoldProbe`. Assert `XCTAssertLessThan(longest.duration, .milliseconds(500))` and print `CHECKLIST_FACTS_WRITER_HOLD files=30000 longest=… refresh_ms=…`.

- [ ] **Step 2: Run the tests to verify they fail.** Run `xcodebuild … -configuration Test -only-testing:CrateAgentTests/SeratoLibraryFactsTests test`. Expected: FAIL, because the types are not defined.

- [ ] **Step 3: Implement the migration, `SeratoDirectoryStamp`, `SeratoLibraryFacts` and the service, then wire it in `AppServices`.** The service skips with `.skippedWhileSeratoRunning` unless `watchdog.isClosed(atRevision:)` holds before and after the read, the same pattern as `SeratoPlayCountService.refreshOnce`. It reads off the main actor with `Task.detached`.

- [ ] **Step 4: Run the tests to verify they pass.** Run the same command, then the startup test with the optimized command. Expected: PASS, with `CHECKLIST_FACTS_WRITER_HOLD` longest under 500 ms.

- [ ] **Step 5: Commit.**
  ```bash
  git add CrateAgent CrateAgentTests
  git commit -m "Cache Serato crate membership, beatgrid lock and date added per file"
  ```

### Task 3: Serato analysis worker and confirmed-duplicate members

**Files:**
- Create: `CrateAgent/Database/Migrations/AddSeratoAnalysisMigration.swift` (`031_add_serato_analysis`), `CrateAgent/Services/SeratoAnalysisWorker.swift`, `CrateAgent/Services/ChecklistDuplicates.swift`
- Modify: `CrateAgent/Services/DuplicateEvidence.swift` (extract the fresh-join SQL into a shared `DerivedFileCache.freshJoinSQL(table:alias:)` that `DuplicateDigestStore` and analysis both use), `CrateAgent/Services/WorkerCoverage.swift` (add `SeratoAnalysisCoverage`), `CrateAgent/App/AppServices.swift` (start the worker beside `startFingerprinting()`; start the duplicate refresher)
- Test: `CrateAgentTests/SeratoAnalysisWorkerTests.swift`, `CrateAgentTests/ChecklistDuplicatesTests.swift`, `CrateAgentTests/LibraryStartupPerformanceTests.swift`

**Interfaces:**
- Consumes: `readSeratoAnalysis(filePath:)` (Task 1), `DigestBasis`, `SeratoSourceIdentity.read`, `LibrarySyncReadiness` (start only after readiness, the way `FingerprintWorker` does), `DuplicateFinder.findDuplicates(in:mode:)`, `DuplicateScanObservation.start`, and `checklist_duplicate_members` (Task 2).
- Schema (031): `file_serato_analysis(file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE, file_size, mtime, inode, modified_nanoseconds, changed_seconds, changed_nanoseconds INTEGER NOT NULL, cue_count INTEGER, beatgrid_marker_count INTEGER, failure TEXT, CHECK ((failure IS NULL) = (cue_count IS NOT NULL)))`.
- Produces:
  ```swift
  enum SeratoAnalysisStore { static let table = "file_serato_analysis"
      static func freshJoinSQL(as alias: String = "analysis") -> String   // via DerivedFileCache.freshJoinSQL
      static func pending(limit: Int, in database: GRDB.Database) throws -> [DigestCandidate]   // processable, no fresh row
      static func save(_ results: [SeratoAnalysisResult], in database: GRDB.Database) throws   // only while basis still matches
      static func coverage(in database: GRDB.Database) throws -> SeratoAnalysisCoverage        // library-wide, processable files
      static func failures(limit: Int, in database: GRDB.Database) throws -> [WorkerFileRow] }  // reason in `detail`, for Workers
  struct SeratoAnalysisResult: Sendable { let fileID: Int64; let basis: DigestBasis; let outcome: Result<SeratoAnalysis, SeratoAnalysisFailure> }
  struct SeratoAnalysisCoverage: Equatable, Sendable { let read: Int; let pending: Int; let failed: Int }
  public actor SeratoAnalysisWorker {
      static let batchSize = 200
      init(database: LibraryDatabase, readiness: LibrarySyncReadiness,
           readAnalysis: @escaping @Sendable (String) throws -> SeratoAnalysis = { path in try readSeratoAnalysis(filePath: path) })
      func start(); func stop(); func waitUntilStopped() async
      func processAllPendingOnce() async throws -> SeratoAnalysisCoverage }
  enum ChecklistDuplicates { static let table = "checklist_duplicate_members"
      static func confirmedMembers(in database: GRDB.Database) throws -> [Int64: String]   // file_id → group key
      static func replace(with members: [Int64: String], in writer: any DatabaseWriter) async throws }  // diff, ≤1,000 rows/txn
  @MainActor final class ChecklistDuplicateRefresher { init(database: LibraryDatabase); func start(); func stop(); func refresh() async throws }
  ```
- The worker stats each file (`SeratoSourceIdentity.read`) before and after reading it. If the stat changed, it skips the file this pass. It writes one transaction per batch. It re-polls after `files` changes, because a Serato cue edit changes the file's stat, which the next sync records, which leaves the analysis row stale.
- The refresher runs `refresh()` at start and on `DuplicateScanObservation` changes, debounced by 1 s. `confirmedMembers` takes groups whose `check == .confirmed` and whose `labelReview?.keptBoth != true`.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  func testWorkerRecordsCuesAndReadsTheFileAgainAfterItChanges() async throws {
      // file at a real temp path; reader stub returns 3 cues
      _ = try await worker.processAllPendingOnce(); XCTAssertEqual(try analysis(file).cueCount, 3)
      // touch the file and update files.mtime as a sync would; stub now returns 5
      _ = try await worker.processAllPendingOnce(); XCTAssertEqual(try analysis(file).cueCount, 5)
  }
  func testUnreadableFileIsRecordedAsAFailureNotAsNoCues() async throws {
      // reader stub throws CoreError for this file
      XCTAssertNil(try analysis(file).cueCount); XCTAssertNotNil(try analysis(file).failure)
      XCTAssertEqual(try coverage(), SeratoAnalysisCoverage(read: 0, pending: 0, failed: 1))   // SeratoAnalysisStore.coverage(in:)
      XCTAssertEqual(try failures().map(\.id), [file])                                          // SeratoAnalysisStore.failures(limit:in:)
  }
  func testConfirmedMembersExcludeNeedsListeningAndKeptLabelGroups() throws {
      // ConfirmedDuplicateGroup support: one confirmed byte-level pair, one needs-listening perceptual pair, one kept-label pair
      XCTAssertEqual(Set(try ChecklistDuplicates.confirmedMembers(in: connection).keys), [confirmedA, confirmedB])
  }
  ```
  In `LibraryStartupPerformanceTests`, add `verifyBrowsingWhileChecklistFactsCompute(fixture)`. It starts `SeratoAnalysisWorker` over the 30,000 WAVs and a facts refresh, then reuses the production content and sidebar measurement from `verifyNavigationDuringSync` while `WriterHoldProbe` runs. Assert that rendering, navigation and the longest writer wait are each under 500 ms, and that at least one analysis batch persisted. Print `CHECKLIST_BACKGROUND render_ms=… navigation_ms=… longest_writer_wait=… analysed=…`.

- [ ] **Step 2: Run the tests to verify they fail.** Run with `-only-testing:CrateAgentTests/SeratoAnalysisWorkerTests -only-testing:CrateAgentTests/ChecklistDuplicatesTests`. Expected: FAIL, because the types are not defined.

- [ ] **Step 3: Implement the migration, store, worker, duplicate members and refresher, and the shared fresh-join helper.** Wire them in `AppServices` and stop them in `deinit`, as is done for `fingerprintWorker`.

- [ ] **Step 4: Run the tests to verify they pass**, including `DuplicateScanPerformanceTests` and `DuplicateCheckTests` after the helper extraction, and the startup test with the optimized command. Expected: PASS, with every `CHECKLIST_BACKGROUND` measure under 500 ms.

- [ ] **Step 5: Commit.**
  ```bash
  git add CrateAgent CrateAgentTests
  git commit -m "Read Serato cue points in the background and cache confirmed duplicate members"
  ```

### Task 4: Keeper mutation

**Files:**
- Create: `CrateAgent/Database/Migrations/AddKeeperMarksMigration.swift` (`032_add_keeper_marks`), `CrateAgent/Services/KeeperMutation.swift`
- Modify: `CrateAgent/Services/OperationEngine.swift` (`TrackMutation.keeper`, dispatch near `.duplicateLabelReview`, `decodeInverseMutation`, the exhaustive `EventType` switches, and the public `setKeeper` API), `CrateAgent/Models/EventRecord.swift`, `CrateAgent/Services/SeratoConflictTargets.swift`, `CrateAgent/Services/EventHistoryQuery.swift`, `CrateAgent/Services/QueuedChangeDiscard.swift`, `CrateAgent/Constants/HistoryMessages.swift`
- Test: `CrateAgentTests/KeeperMutationTests.swift`

**Interfaces:**
- Schema (032): `keeper_marks(file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE, marked_revision INTEGER NOT NULL, marked_at INTEGER NOT NULL)`.
- Produces:
  ```swift
  public struct KeeperMark: Codable, Sendable, Hashable { public let fileId: Int64; public let markedRevision: Int64; public let markedAt: Int64 }
  public struct KeeperTarget: Codable, Sendable, Equatable { public let fileId: Int64; public let expectedRevision: Int64 }
  public enum KeeperOperation: Sendable {
      case mark(KeeperTarget), clear(KeeperTarget)          // forward, from the UI
      case restore([KeeperMark]), remove([KeeperMark])      // inverses, from decodeInverseMutation only
  }
  // TrackMutation: case keeper(KeeperOperation)
  // EventType: keeperMarked = "keeper_marked" (inverse .remove), keeperCleared = "keeper_cleared" (inverse .restore)
  enum KeeperMarks { static let table = "keeper_marks"
      /// Over `files LEFT JOIN tracks ON tracks.id = files.track_id`: MBID, else 'track:' || id, else 'file:' || files.id.
      static let recordingKeySQL = "COALESCE(\(SongFamilyMutation.versionKeySQL), 'file:' || files.id)"
      /// A valid mark: marked_revision >= COALESCE(files.last_projection_invalidation_revision, 0).
      static let validMarkSQL: String
      /// CTE body selecting every protected file id: a valid own mark, or a recording key shared with a validly marked file.
      static let protectedFilesSQL: String
      /// CTE body selecting files with a valid mark of their own (suppresses the duplicate item).
      static let ownMarkFilesSQL: String
      static func isProtected(fileID: Int64, in database: GRDB.Database) throws -> Bool }
  public extension OperationEngine {
      /// Marks or clears the keeper of `token`'s file and its recording; returns the batch id for History.
      func setKeeper(_ isKeeper: Bool, for token: FileMembershipToken) async throws -> String }
  public enum KeeperError: LocalizedError, Equatable { case alreadyKept, notKept, superseded }
  ```
- Rechecks happen inside the writer transaction (Invariant 1).
  - `.mark`: the file exists and is not retired, else `.superseded`; its `membership_revision == expectedRevision`, else `.superseded`; and it is not already protected, else `.alreadyKept`. An invalid stale row for the file is replaced in the same transaction, and the inverse `.remove` deletes the row.
  - `.clear`: the same file checks, then delete every valid mark whose file shares `recordingKeySQL` with the target, else `.notKept`.
  - Journal one event per changed mark, with `fileId` set and `trackId` set to the file's `track_id`, so per-file History lists it.
  - `.restore` and `.remove` require each mark's current row state to match, else `.superseded`.
- The `SeratoConflictTargets.mutation` case has `fileIDs`: the target, or the marks' files, plus every file sharing their recording key, with `include(file)` for each. `sharedTrackIDs` holds those files' non-nil `track_id`s. Keeper writes no Serato file.

- [ ] **Step 1: Write the failing tests.** Use a temporary WAL database and an `OperationEngine` as `UndoableRemovalTests` does. FLAC and MP3 have *separate* `tracks` rows that share one `musicbrainz_recording_id` (the normal Invariant 4 shape). File Z is standalone with `track_id == nil`.
  ```swift
  func testMarkingAKeeperProtectsEveryEncodingOfItsRecordingAndUndoRemovesIt() async throws {
      let batch = try await engine.setKeeper(true, for: token(flac))
      XCTAssertEqual(try protectedIDs(), [flac, mp3])
      try await engine.undoBatch(batch); XCTAssertEqual(try protectedIDs(), [])
  }
  func testClearingAKeeperRemovesEveryMarkOnTheRecordingAndUndoRestoresThem() async throws {
      // fixture starts with different MBIDs: setKeeper(true) on flac and on mp3, then give both tracks the same MBID in fixture SQL
      let batch = try await engine.setKeeper(false, for: token(mp3))
      XCTAssertEqual(try marks(), []); try await engine.undoBatch(batch); XCTAssertEqual(try marks().map(\.fileId).sorted(), [flac, mp3])
  }
  func testKeeperIsRefusedWhenTheFileChangedSinceItWasShown() async throws {
      await XCTAssertThrowsErrorAsync(try await engine.setKeeper(true, for: staleToken(z))) { error in XCTAssertEqual(error as? KeeperError, .superseded) }
  }
  func testReplacedContentDropsKeeperProtectionAndMarkingAgainReplacesTheStaleRow() async throws {
      // mark z, then apply observeFileIdentity with replaced content (bumps last_projection_invalidation_revision)
      XCTAssertEqual(try protectedIDs(), [])
      _ = try await engine.setKeeper(true, for: token(z)); XCTAssertEqual(try protectedIDs(), [z])
  }
  func testSeparatingAKeptRecordingLeavesProtectionOnTheMarkedFileOnly() async throws {
      // mark flac; then mp3's track loses the shared MBID (undo of its MusicBrainz match), so the keys differ
      XCTAssertEqual(try protectedIDs(), [flac])
  }
  ```
  `XCTAssertEqual(error as? KeeperError, …)` is a checked conditional cast, not an `as` assertion.

- [ ] **Step 2: Run the tests to verify they fail.** Run `-only-testing:CrateAgentTests/KeeperMutationTests`. Expected: FAIL, because `setKeeper` is not defined.

- [ ] **Step 3: Implement the migration, `KeeperMutation.apply(_:batchId:timestamp:in:)` (modelled on `DuplicateLabelReviewMutation`), the engine dispatch and inverse decoding, the History text ("Marked as keeper", "Keeper cleared") in `HistoryMessages`, and the conflict-target case.** The compiler lists every exhaustive `EventType` switch that needs a case.

- [ ] **Step 4: Run the tests to verify they pass**, plus `UndoableRemovalTests`, `SongFamilyTests`, `RecordingIdentityTests` and `MusicBrainzMutationTests`. Expected: PASS.

- [ ] **Step 5: Commit.**
  ```bash
  git add CrateAgent CrateAgentTests
  git commit -m "Add an undoable recording-level keeper mark"
  ```

### Task 5: Checklist query contract (items, chips, sort columns, counts)

**Files:**
- Create: `CrateAgent/Services/LibraryPaging/LibraryChecklist.swift` (types, constants and SQL)
- Modify: `CrateAgent/Services/LibraryPaging/LibraryBrowseQuery.swift`, `CrateAgent/Services/LibraryPaging/LibraryPagedSnapshot.swift`, `CrateAgent/Services/LibraryPaging/LibraryBrowseObservation.swift`, `CrateAgent/Models/BrowserRow.swift`, `CrateAgent/Models/LibraryFamilyState.swift` and `CrateAgent/Constants/LibraryFamilyMessages.swift` (the `isFiltering` rename and copy), `CrateAgent/Models/LibraryBrowserModel.swift` (`setChip`, plus `@Published chipCounts` loaded after the page)
- Test: `CrateAgentTests/LibraryChecklistTests.swift`, `CrateAgentTests/LibraryPagingTests.swift`, `CrateAgentTests/Support/PagedLibraryFixture.swift`

**Interfaces:**
- Consumes: the tables from Tasks 2–4, `serato_play_counts`, `KeeperMarks.recordingKeySQL`, `protectedFilesSQL` and `ownMarkFilesSQL`, `SeratoAnalysisStore.freshJoinSQL`, `SongFamilyMutation.versionKeySQL`, and `DateAddedSource`.
- Produces:
  ```swift
  enum ChecklistItem: Int, CaseIterable, Hashable, Sendable { case inCrate, cuePoints, beatgridChecked, metadata, quality, versions, duplicate }  // bit = 1 << rawValue
  enum MetadataField: Int, CaseIterable, Hashable, Sendable { case artist, title, genre, bpm, key }                                        // bit = 1 << rawValue
  enum ChecklistMask {   // throws ChecklistError.unexpectedBits on any bit no case names
      static func decode<Item: CaseIterable & Hashable & RawRepresentable>(_ mask: Int, as type: Item.Type) throws -> Set<Item> where Item.RawValue == Int }
  struct FileChecklist: Hashable, Sendable { let failing: Set<ChecklistItem>; let unknown: Set<ChecklistItem>
      let missingMetadata: Set<MetadataField>; let isProtected: Bool; let isFinished: Bool; let stillNeedsCount: Int }   // all read from SQL columns
  enum ChecklistChip: String, CaseIterable, Identifiable, Sendable { case needsWork, notInCrate, noCues, gridUnchecked, lowQuality, neverPlayed, tooManyVersions, finished }
  enum LibraryChecklist {
      static let minimumLossyBitrateKbps = 256
      static let losslessExtensions: Set<String> = ["flac", "wav", "aif", "aiff"]
      static let maximumFamilyVersions = 4
      static let refreshThrottle: Duration = .seconds(2)
      static let observedTables: [String]   // facts, memberships, stamps, analysis, duplicates, keeper_marks, serato_play_counts
  }
  // LibraryBrowseSort.Column += stillNeeds, dateAdded, myPlays   (nullable: sort.sql prefixes `placed.group_key IS NULL ASC`, so nulls are last both ways)
  // LibraryBrowseQuery += var chip: ChecklistChip? = nil; var isFiltering: Bool { isSearching || chip != nil }   (Task 6 adds facets)
  // BrowserRow += genre: String?, checklistFailingMask: Int?, checklistUnknownMask: Int?, missingMetadataMask: Int?, isProtected: Bool?,
  //               isFinished: Bool?, stillNeedsCount: Int?, beatgridMarkerCount: Int?, dateAdded: Int64?, dateAddedSource: DateAddedSource?,
  //               playCount: Int?, familyFilesNeedingWork: Int?, familyFileCount: Int?
  //               func checklist() throws -> FileChecklist?            // nil outside the Library projection; throws on unexpected bits
  //               var stillNeedsSortKey: Int, dateAddedSortKey: Int64, playCountSortKey: Int   // non-optional, for KeyPathComparator
  // LibraryBrowseSort.init(comparator:) maps those three key paths to .stillNeeds, .dateAdded and .myPlays
  // LibraryPagedSnapshot: func chipCounts() throws -> [ChecklistChip: Int]   // same DatabaseSnapshot; query without its chip
  ```
- SQL shape. The CTE order is what makes the versions chip computable; reviewers check it.
  1. `checklist_files AS MATERIALIZED` computes per file in the status scope, using primary-key joins only: the placement-independent bits (`failing`, `unknown`), `missing_metadata`, `is_protected` (from `protectedFilesSQL`), `has_own_mark` (from `ownMarkFilesSQL`), `recording_key` (`recordingKeySQL`), `beatgrid_marker_count`, `date_added`, `date_added_source` and `play_count`. The duplicate bit is set only when `NOT has_own_mark`.
  2. `family_base` is today's `family_files` without `matches`, joined to `checklist_files`, and selects `recording_key`.
  3. `heads` is built from `family_base` and also selects `head_recording_key` and the head's checklist sort keys.
  4. `family_files` comes after `heads`. It adds the versions bit (`families.versions > maximumFamilyVersions AND recording_key != head_recording_key AND NOT is_protected`) and then evaluates `matches` (search AND chip), which feeds `families.matched`.
  5. `placed` joins `checklist_files` by `files.id`, adds the same versions bit for family members, and projects `is_finished` (`is_protected OR (failing = 0 AND unknown = 0)`), `still_needs_count` (set bits in `failing | unknown`, 0 when protected) and the per-family file counts.
  - The new sort columns emit expressions over these aliases rather than `Column.sql("files")`. The head's Still needs key excludes `versions`, since the main is exempt.
  - SQL is the only source of Finished and the needs count. Swift reads `is_finished` and `still_needs_count`.

  Item truth:

  | Item | Fails when | Unknown when |
  | --- | --- | --- |
  | inCrate | subcrates stamp exists and no membership row | no subcrates stamp |
  | cuePoints | fresh analysis row with `cue_count = 0` | no fresh row, or `failure` set |
  | beatgridChecked | facts row with `beatgrid_locked = 0` | no facts row, or `beatgrid_locked` NULL |
  | metadata | any of artist, title, genre, bpm or key NULL or blank after trim | never |
  | quality | `bitrate_kbps < 256` | bitrate NULL and extension not lossless |
  | versions | (see above) | never |
  | duplicate | in `checklist_duplicate_members` and the file has no valid mark of its own | never |

- Chip predicates: `needsWork` is NOT `is_finished`, `finished` is `is_finished`, `neverPlayed` is no play-count row, and each other chip is its item's `failing` bit. A chip ANDs into the same `matches` expression as search (step 4 above).
- The observation adds a second `DatabaseRegionObservation` over `LibraryChecklist.observedTables`, throttled to `refreshThrottle`. The existing projection region also gains `files.genre` and `files.bitrate_kbps` (through `BrowserRow.browserColumnsSQL`), because the metadata and quality items read them.

- [ ] **Step 1: Write the failing tests.** In `LibraryChecklistTests`, set up a temporary WAL database with one file per case, seeding the fact tables directly in SQL.
  ```swift
  func testChecklistReportsEachItemFromStoredFacts() async throws {
      let rows = try await checklistsByTitle(LibraryBrowseQuery())   // title → try row.checklist()
      XCTAssertEqual(rows["Uncrated"]?.failing, [.inCrate])
      XCTAssertEqual(rows["Unread"]?.unknown, [.cuePoints, .beatgridChecked])
      XCTAssertEqual(rows["NoGenre"]?.missingMetadata, [.genre])
      XCTAssertEqual(rows["Lossy192"]?.failing, [.quality])
      XCTAssertEqual(rows["FlacNoBitrate"]?.failing, [])
      XCTAssertEqual(rows["Mp3NoBitrate"]?.unknown, [.quality])
      XCTAssertEqual(rows["Dupe"]?.failing, [.duplicate])
      XCTAssertEqual(rows["Complete"]?.isFinished, true); XCTAssertEqual(rows["Uncrated"]?.stillNeedsCount, 1)
  }
  func testKeeperIsFinishedButOnlyItsOwnMarkHidesDuplicate() async throws {
      // KeptLossyDupe (marked) and KeptSiblingDupe: separate tracks sharing one MBID, both confirmed duplicate members
      let rows = try await checklistsByTitle(.init())
      XCTAssertEqual(rows["KeptLossyDupe"]?.isFinished, true); XCTAssertEqual(rows["KeptLossyDupe"]?.failing, [.quality])
      XCTAssertEqual(rows["KeptSiblingDupe"]?.isFinished, true); XCTAssertEqual(rows["KeptSiblingDupe"]?.failing, [.duplicate])
  }
  func testTooManyVersionsFlagsOnlyNonMainVersionsOfFamiliesOverTheLimit() async throws {
      // family of 5 versions whose main version is an MP3 and a FLAC on separate tracks sharing an MBID; a family of 4
      XCTAssertEqual(try await titles(.init(chip: .tooManyVersions)), ["V2", "V3", "V4", "V5"])  // `titles` omits the main row shown as context
  }
  func testChipsCombineWithSearchAndCountFilesInScope() async throws {
      let snapshot = try await LibraryPagedSnapshot.open(pool: pool, query: .init(search: "Artist A", chip: .notInCrate))
      let counts = try await snapshot.chipCounts()
      XCTAssertEqual(counts[.notInCrate], 2); XCTAssertEqual(counts[.finished], 1)
      XCTAssertEqual(try await titles(.init(search: "Artist A", chip: .notInCrate)), ["A Uncrated 1", "A Uncrated 2"])
  }
  func testDateAddedFallsBackToFirstIndexedAndMissingValuesSortLast() async throws {
      XCTAssertEqual(try await ids(.init(sort: .init(column: .dateAdded, ascending: false))), [seratoNewest, indexedOlder, noFacts])
      XCTAssertEqual(try await ids(.init(sort: .init(column: .myPlays, ascending: false))).prefix(2), [played9, played2])
  }
  ```
  In `LibraryPagingTests`, add `testChecklistSortFilterAndCountsStayWithinBudgetsAtThirtyThousandFiles`. Seed facts for all 30,000 files, fresh analysis for 24,000, memberships for 20,000, play counts for 10,000, 300 duplicate members, 500 keeper marks and the 2,000 three-version families from the song-family test. For each of the sorts `.stillNeeds`, `.dateAdded` and `.myPlays`, each `ChecklistChip`, and `search + .needsWork`, measure `open + rows(0..<200)` and, separately, `chipCounts()`. `XCTAssertLessThan(elapsed, .milliseconds(500), label)` for each. Print `CHECKLIST_PAGING_METRICS …` and attach it.

- [ ] **Step 2: Run the tests to verify they fail.** Run with `-only-testing:CrateAgentTests/LibraryChecklistTests -only-testing:CrateAgentTests/LibraryPagingTests`. Expected: FAIL, because `checklist` and `chipCounts` are not defined.

- [ ] **Step 3: Implement `LibraryChecklist`, `ChecklistMask`, the split CTEs, the snapshot changes, the `BrowserRow` columns and sort keys, the rename to `isFiltering`, the observation changes, and `LibraryBrowserModel.setChip(_:)` plus `chipCounts`.** `chipCounts` loads in its own task after `results.open`, and a newer snapshot cancels it.

- [ ] **Step 4: Run the tests to verify they pass**, plus `LibraryFamilyProjectionTests` and `LibraryStatusBrowseTests`, using the optimized command for `LibraryPagingTests`. Expected: PASS, every `CHECKLIST_PAGING_METRICS` value under 500 ms, and the existing family metrics within 20% of the baseline. If a budget fails, apply Ruling 8's fallback before going on.

- [ ] **Step 5: Commit.**
  ```bash
  git add CrateAgent CrateAgentTests
  git commit -m "Compute each file's checklist in the Library query, with chips, counts and new sort columns"
  ```

### Task 6: Genre, BPM and compatible-key filters

**Files:**
- Create: `CrateAgent/Services/LibraryPaging/LibraryFacets.swift` (`LibraryFacets`, `LibraryFacetOptions`), `CrateAgent/Services/CamelotKey.swift`
- Modify: `CrateAgent/Services/LibraryPaging/LibraryBrowseQuery.swift`, `CrateAgent/Models/LibraryBrowserModel.swift` (`setFacets`, `facetOptions`)
- Test: `CrateAgentTests/LibraryFacetTests.swift`, `CrateAgentTests/LibraryPagingTests.swift`, `CrateAgentTests/Support/PagedLibraryFixture.swift`

**Interfaces:**
- Consumes: `LibraryBrowseQuery.isFiltering`, the `matches` expression (Task 5 CTE step 4), and `LibraryPagedSnapshot.chipCounts()`.
- Produces:
  ```swift
  struct CamelotKey: Hashable, Comparable, Sendable { let number: Int; let isMajor: Bool   // 1...12, B = major
      init?(parsing text: String)            // "Am", "A min", "A minor", "8A", "08a", "1m"/"1d" (Open Key), "F#", "Gb", "Abm"
      var compatibleKeys: Set<CamelotKey>    // self, number ±1 (wrapping 12↔1) same mode, same number other mode
      var label: String }                    // "8A"
  struct LibraryFacets: Hashable, Sendable { var genres: Set<String> = []; var bpmRange: ClosedRange<Double>? = nil
      var compatibleKey: CamelotKey? = nil; var keyValues: Set<String> = []   // stored strings resolved from compatibleKey
      var isEmpty: Bool }
  struct GenreOption: Hashable, Sendable { let value: String; let count: Int }
  struct LibraryFacetOptions: Equatable, Sendable { let genres: [GenreOption]; let keys: [CamelotKey: Set<String>]
      static func load(in database: GRDB.Database, filter: LibraryStatusFilter) throws -> LibraryFacetOptions   // distinct values, one pass each
      func keyValues(compatibleWith key: CamelotKey) -> Set<String> }
  // LibraryBrowseQuery += var facets = LibraryFacets(); isFiltering becomes isSearching || chip != nil || !facets.isEmpty
  ```
  Facet-only queries reveal matching alternates the way search does (Ruling 10). Update any `isHiddenBySearch` call site this touches.
- SQL, ANDed into `matches`: `files.genre IN (SELECT value FROM json_each(:genres))`, `CAST(files.bpm AS REAL) BETWEEN :bpm_min AND :bpm_max AND CAST(files.bpm AS REAL) > 0`, and `files.musical_key IN (SELECT value FROM json_each(:keys))`. An empty facet adds no predicate. `chipCounts` applies the facets.
- The Open Key number maps to Camelot as `((openKey + 6) % 12) + 1`, with `m` = A and `d` = B (1m = 8A = A minor). Camelot 8A is A minor and 8B is C major.

- [ ] **Step 1: Write the failing tests.** Expected values come from the Camelot wheel, not from the code.
  ```swift
  func testCamelotParsingAndCompatibilityAcrossNotations() {
      XCTAssertEqual(CamelotKey(parsing: "Am"), CamelotKey(parsing: "8A")); XCTAssertEqual(CamelotKey(parsing: "1m"), CamelotKey(parsing: "8A"))
      XCTAssertEqual(CamelotKey(parsing: "C")?.label, "8B"); XCTAssertEqual(CamelotKey(parsing: "Abm")?.label, "1A")
      XCTAssertEqual(CamelotKey(parsing: "8A")?.compatibleKeys.map(\.label).sorted(), ["7A", "8A", "8B", "9A"])
      XCTAssertEqual(CamelotKey(parsing: "12B")?.compatibleKeys.map(\.label).sorted(), ["11B", "12A", "12B", "1B"])
      for garbage in ["", "Unknown", "o", "H#m", "13A"] { XCTAssertNil(CamelotKey(parsing: garbage), garbage) }
  }
  func testFacetsCombineWithChipAndSearch() async throws {
      // files: bpm "128.000", "128", "126.5", "", "0", "131"; keys "Am", "8A", "Em", "Unknown"; genres "House", "Techno"
      let options = try await pool.read { connection in try LibraryFacetOptions.load(in: connection, filter: .active) }
      var facets = LibraryFacets(genres: ["House"], bpmRange: 126 ... 128, compatibleKey: CamelotKey(parsing: "8A"))
      facets.keyValues = options.keyValues(compatibleWith: try XCTUnwrap(facets.compatibleKey))
      XCTAssertEqual(facets.keyValues, ["Am", "8A", "Em"])   // Em = 9A
      XCTAssertEqual(try await titles(.init(search: "Artist", chip: .needsWork, facets: facets)), ["House 128.000 Am", "House 126.5 Em"])
      // facet-only query on a family whose alternate is the only House file: the alternate is revealed beneath its main row
      XCTAssertEqual(try await visibleRoles(.init(facets: LibraryFacets(genres: ["House Alt"]))), [.main, .alternate])
  }
  ```
  Extend `testChecklistSortFilterAndCountsStayWithinBudgetsAtThirtyThousandFiles` with one interaction: search, genre, BPM range, compatible key and `.needsWork` together, sorted by `.stillNeeds`, plus its `chipCounts()`, each under 500 ms. The fixture's files gain a genre, BPM and key spread.

- [ ] **Step 2: Run the tests to verify they fail.** Run `-only-testing:CrateAgentTests/LibraryFacetTests`. Expected: FAIL, because `CamelotKey` is not defined.

- [ ] **Step 3: Implement `CamelotKey`, `LibraryFacets`, `LibraryFacetOptions` and the query predicates, plus `LibraryBrowserModel.setFacets(_:)`, which resolves `keyValues` from the loaded options.**

- [ ] **Step 4: Run the tests to verify they pass**, with the paging test on the optimized command. Expected: PASS, and the combined interaction under 500 ms.

- [ ] **Step 5: Commit.**
  ```bash
  git add CrateAgent CrateAgentTests
  git commit -m "Filter Library by genre, BPM range and compatible key"
  ```

### Task 7: Library and Workers UI, copy and docs

**Files:**
- Create: `CrateAgent/Constants/LibraryChecklistMessages.swift`, `CrateAgent/Views/LibraryChecklistChipBar.swift`, `CrateAgent/Views/LibraryFacetBar.swift`, `docs/library-checklist.md`
- Modify: `CrateAgent/Views/LibraryBrowserColumns.swift` (the Still needs, Date added and My plays columns), `CrateAgent/Views/LibraryBrowserView.swift`, `CrateAgent/Views/LibraryPagedContent.swift` (the `keeper(Bool)` row action and context menu), `CrateAgent/Services/WorkersModel.swift` (publish `SeratoAnalysisStore.coverage(in:)` and `failures(limit:in:)` with the existing coverage refresh), `CrateAgent/Views/WorkersView.swift` (a Serato analysis card with read, pending and failed counts, the failure list and the worker error from `AppServices.seratoAnalysisStatus` (`SeratoAnalysisWorker.Status.error`); a Serato facts card with the service status, modelled on `PlayCountCard`; and the duplicate checklist status from `ChecklistDuplicateRefresher.status`, showing `.failed(String)` visibly), `README.md`, `docs/list-controls.md`, `docs/song-families.md` (filters reveal alternates as search does)

**Interfaces:**
- Consumes: `LibraryBrowserModel.setChip`, `setFacets`, `chipCounts` and `facetOptions` (Tasks 5–6), `BrowserRow.checklist()`, `beatgridMarkerCount`, `dateAdded`, `dateAddedSource`, `playCount`, the three sort keys, `familyFilesNeedingWork` and `familyFileCount`, `OperationEngine.setKeeper(_:for:)` (Task 4), `SeratoAnalysisStore.coverage(in:)` and `failures(limit:in:)` (Task 3), `SeratoLibraryFactsService.status`, and `SeratoPlayCountService.status`.
- Produces:
  ```swift
  struct LibraryChecklistChipBar: View { @Binding var chip: ChecklistChip?; let counts: [ChecklistChip: Int]?; let neverPlayedAvailable: Bool }
  struct LibraryFacetBar: View { @Binding var facets: LibraryFacets; let options: LibraryFacetOptions? }
  ```
- Copy (`LibraryChecklistMessages`):
  - Chip titles, exactly as in the spec: "Needs work", "Not in a crate", "No cues", "Grid unchecked", "Low quality", "Never played", "Too many versions", "Finished".
  - Column titles: "Still needs", "Date added", "My plays".
  - Tags: "Crate", "Cues", "Grid", "Tags", "Quality", "Versions", "Duplicate", "Keeper" and "Finished". An unknown item renders as "\(tag) unknown" in secondary color.
  - A family main row adds "\(needing) of \(total) files need work". The checklist is per file, and the spec's copy is only "a count like".
  - The Still needs tooltip lists one sentence per item, naming the fix: artist or title through Auto-Tag, genre through the tag editor, BPM or key through "Analyze in Serato", and grid "Lock the beatgrid in Serato". For a row with `beatgridMarkerCount == 0` it says "No beatgrid".
  - Date added help: "From Serato" or "First indexed by crate-agent".
  - Never played disabled help: "Waiting for Serato History. Close Serato to read play counts."
  - Context menu: "Mark as Keeper" and "Clear Keeper".
- UI rules:
  - Chips are toggle buttons labelled "Title count" (counts use `formatted()`, and read "…" until loaded). The selected chip uses the prominent style and `.accessibilityAddTraits(.isSelected)`. Pressing it again clears it.
  - Facets use `Menu`s with `.menuIndicator(.hidden)` and state labels ("Genre: Any", "Genre: House +1", "Key: compatible with 8A"), plus two BPM fields with a text "Clear filters" button.
  - The keeper action writes no Serato file, so it is not `.seratoWriteGated`.
  - The README gains one paragraph, and `wc -c README.md` must stay under 16,000.

- [ ] **Step 1: Implement the views, columns, context action, Workers cards and messages.** The new columns bind `\BrowserRow.stillNeedsSortKey`, `\.dateAddedSortKey` and `\.playCountSortKey`, which Task 5 maps in `LibraryBrowseSort(comparator:)`. This task adds no tests: it is view wiring and copy over contracts Tasks 4–6 test (testing rules 1 and 8).

- [ ] **Step 2: Write `docs/library-checklist.md`** covering the item table, unknown versus failing, keeper semantics, chip counting, facet behavior and where each fact comes from. Link it from the README paragraph.

- [ ] **Step 3: Verify.** Run `make format` and check `git diff --stat` for drift, then `make lint`, `make test`, and `wc -c README.md`. Expected: all green and under 16,000.

- [ ] **Step 4: Commit.**
  ```bash
  git add CrateAgent docs README.md
  git commit -m "Show the still-needs checklist, chips, filters and keeper in Library and analysis status in Workers"
  ```

### Task 8: Invariant 8 evidence and on-screen smoke

**Files:**
- Modify: `docs/testing.md` (a new "Library checklist fixture" section after "Paged Library fixture")

- [ ] **Step 1: Rerun the baseline commands from Task 1 Step 1 with identical settings**, adding `LibraryChecklistTests` and the new paging test. Expected: PASS. Check every existing metric against `$SCRATCHPAD/library-checklist-baseline.txt`. If one regresses by more than 20%, stop and report it rather than documenting it.

- [ ] **Step 2: Document the results in `docs/testing.md`.** Include the fixtures used, a baseline-versus-final table (song-family interactions; startup ready, render, navigation and writer hold), the new `CHECKLIST_PAGING_METRICS`, `CHECKLIST_FACTS_WRITER_HOLD` and `CHECKLIST_BACKGROUND` values, the date, the commit hashes and the optimized command.

- [ ] **Step 3: Commit.**
  ```bash
  git add docs/testing.md
  git commit -m "Record Library checklist budgets against the 30,000-file fixtures"
  ```

- [ ] **Step 4: Hand the owner the smoke checklist for the running app.** Do not boot a dev server. Report each answer in the PR.
  1. Launch on the indexed library. Library browses at once, and checklist cells read "unknown" or update without beach-balling.
  2. Workers shows Serato analysis progress and the Serato facts status. Any failures list their reasons.
  3. In Serato, lock one track's beatgrid, add a hot cue to another, and add a third to a crate, then close Serato. After the sync, each row's Grid, Cues and Crate tags clear. (This verifies Ruling 2. If Grid doesn't clear, report it, so the `bbgl` fallback can be applied.)
  4. Choose each chip in turn. Counts look plausible, and choosing a chip and clearing it each feel immediate (under half a second).
  5. Search for an artist, choose genre, BPM 124–128 and a compatible key, and sort by Still needs, Date added and My plays. Each change feels immediate.
  6. Mark an Auto-Tagged track as a keeper. It moves to Finished, and another encoding with the same MusicBrainz recording does too, though that encoding keeps any Duplicate tag. Undo it from History and it reverts.
  7. A song family over 4 versions shows "Versions" on its non-main rows and "N of M files need work" on the main row.
  8. No control shows a chevron or triangle. Every chip and menu is reachable by keyboard.
